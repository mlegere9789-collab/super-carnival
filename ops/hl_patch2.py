import sys
root = sys.argv[1]
p = root + '/include/dino8/kernel/brep.h'
s = open(p).read()
anchor = '''  int RemoveSliverFaces(double max_width = tolerance::kEdgeJoin);
'''
assert anchor in s
decl = anchor + '''
  // ---------------------------------------------------------------------
  // Gated, reported healing: HealChecked().
  // ---------------------------------------------------------------------
  struct HealOptions {
    // Gap / overlap distance: naked edges whose end points lie within this
    // distance (either side of the other edge - a gap or an overlap) are
    // joined, and T-junctions within it are split and sewn.
    double gap_tolerance = tolerance::kEdgeJoin;
    // Faces whose boundary is within this distance of one line are
    // removed (degenerate and sliver faces) and their exposed neighbour
    // edges tolerantly re-joined.
    double sliver_width = tolerance::kEdgeJoin;
    // A heal is refused if the closed-shell volume (measured on the
    // tolerant tessellation before and after) changes by more than this
    // fraction of the original volume.
    double max_relative_volume_change = 1e-3;
    // Also run UnifyNormals() (consistent, outward orientation).
    bool unify_normals = true;
  };
  struct HealReport {
    // True iff the healed result was kept. When false this Brep is
    // bit-for-bit what it was before the call and `reason` says why.
    bool accepted = false;
    // True iff accepted AND the Brep actually changed.
    bool changed = false;
    std::string reason;
    // What the (kept or discarded) trial did.
    int joined_edges = 0;
    int split_t_junctions = 0;
    int degenerate_faces_removed = 0;
    int sliver_faces_removed = 0;
    int faces_flipped = 0;
    // Check() before and after the trial (the "after" report is of the
    // trial even when it was discarded, so the cause is visible).
    CheckReport before;
    CheckReport after;
    bool valid_before = false;  // raw().IsValid()
    bool valid_after = false;
    bool volume_measured_before = false;  // tolerant tessellation closed -> Volume() measured
    bool volume_measured_after = false;
    double volume_before = 0.0;
    double volume_after = 0.0;
  };

  // Heals gaps, overlaps, T-junctions, degenerate/sliver faces and
  // inconsistent orientation in ONE trial on a private copy, then keeps
  // the copy only if it passes a validity gate; otherwise this Brep is
  // left exactly as it was and the report says which gate refused it.
  // Steps (in order): JoinNakedEdges(gap_tolerance), SewTJunctions,
  // RemoveDegenerateFaces, RemoveSliverFaces(sliver_width), JoinNakedEdges
  // again (the removals expose new naked edges), UnifyNormals().
  // Gate (ALL must hold): (1) no CheckIssue kind has MORE instances after
  // than before; (2) strictly fewer issues in total after than before
  // (otherwise "no improvement"); (3) raw().IsValid() did not go from true
  // to false and topology_valid did not regress; (4) if the closed-shell
  // volume could be measured both before and after
  // (TessellateToClosedMeshTolerant closed manifold), it moved by at most
  // max_relative_volume_change of the original; (5) a face count that did
  // not drop below half (a heal that would delete most of the body is
  // refused). A Brep that is already clean is reported accepted=true,
  // changed=false, and not touched. HONEST LIMITS: sliver/degenerate
  // removal is still delete-and-tolerant-join (the neighbour surfaces are
  // not moved to meet geometrically - the joined edges carry the removed
  // width as their recorded tolerance); the gate measures Check() kinds,
  // validity and volume, not an exact geometric deviation. Never throws on
  // a Brep it cannot heal (it reports instead).
  HealReport HealChecked(const HealOptions& options = HealOptions()) ;
'''
s = s.replace(anchor, decl, 1)
open(p, 'w').write(s)

p = root + '/src/brep.cpp'
s = open(p).read()
anchor = 'void Brep::DeleteFace(int face_index, bool heal, double join_tolerance) {'
assert anchor in s
impl = '''Brep::HealReport Brep::HealChecked(const HealOptions& options) {
  HealReport rep;
  const double gap = std::max(options.gap_tolerance, 0.0);
  const double width = std::max(options.sliver_width, 0.0);
  const auto measure = [](const Brep& b, bool* ok, double* volume) {
    *ok = false;
    *volume = 0.0;
    try {
      const Mesh m = b.TessellateToClosedMeshTolerant(8, 8);
      if (m.IsClosedManifold()) {
        *volume = m.Volume();
        *ok = true;
      }
    } catch (const std::exception&) {
    }
  };
  rep.before = Check(std::min(tolerance::kDistance, std::max(gap, width)), width);
  rep.valid_before = brep_.IsValid();
  measure(*this, &rep.volume_measured_before, &rep.volume_before);
  if (rep.before.IsClean() && rep.before.topology_valid) {
    rep.after = rep.before;
    rep.valid_after = rep.valid_before;
    rep.volume_measured_after = rep.volume_measured_before;
    rep.volume_after = rep.volume_before;
    rep.accepted = true;
    rep.changed = false;
    rep.reason = "already clean: Check() reports no issue, nothing was done";
    return rep;
  }

  Brep trial = *this;
  rep.joined_edges = trial.JoinNakedEdges(gap);
  rep.split_t_junctions = trial.SewTJunctions(gap);
  rep.degenerate_faces_removed = trial.RemoveDegenerateFaces(std::min(tolerance::kDistance, std::max(gap, width)));
  rep.sliver_faces_removed = trial.RemoveSliverFaces(width);
  rep.joined_edges += trial.JoinNakedEdges(gap);
  if (options.unify_normals) rep.faces_flipped = trial.UnifyNormals();
  rep.after = trial.Check(std::min(tolerance::kDistance, std::max(gap, width)), width);
  rep.valid_after = trial.brep_.IsValid();
  measure(trial, &rep.volume_measured_after, &rep.volume_after);

  // Gate.
  const auto kind_count = [](const CheckReport& r, CheckIssue::Kind k) { return r.Count(k); };
  for (int k = 0; k <= static_cast<int>(CheckIssue::Kind::InsideOutShell); ++k) {
    const CheckIssue::Kind kind = static_cast<CheckIssue::Kind>(k);
    if (kind_count(rep.after, kind) > kind_count(rep.before, kind)) {
      rep.reason = "refused: the heal would increase the number of issues of kind #" + std::to_string(k) + " from " +
                   std::to_string(kind_count(rep.before, kind)) + " to " + std::to_string(kind_count(rep.after, kind)) +
                   "; the Brep is unchanged";
      return rep;
    }
  }
  if (rep.valid_before && !rep.valid_after) {
    rep.reason = "refused: raw().IsValid() would go from true to false; the Brep is unchanged";
    return rep;
  }
  if (rep.before.topology_valid && !rep.after.topology_valid) {
    rep.reason = "refused: topology_valid would go from true to false; the Brep is unchanged";
    return rep;
  }
  if (rep.volume_measured_before && rep.volume_measured_after) {
    const double dv = std::fabs(rep.volume_after - rep.volume_before);
    if (dv > options.max_relative_volume_change * std::fabs(rep.volume_before)) {
      rep.reason = "refused: the closed-shell volume would change by " + std::to_string(dv) + " (" +
                   std::to_string(rep.volume_before) + " -> " + std::to_string(rep.volume_after) +
                   "), above max_relative_volume_change; the Brep is unchanged";
      return rep;
    }
  } else if (rep.volume_measured_before && !rep.volume_measured_after) {
    rep.reason = "refused: the shell was closed before and is no longer a closed manifold after; the Brep is unchanged";
    return rep;
  }
  if (2 * trial.FaceCount() < FaceCount()) {
    rep.reason = "refused: the heal would delete more than half of the faces (" + std::to_string(FaceCount()) + " -> " +
                 std::to_string(trial.FaceCount()) + "); the Brep is unchanged";
    return rep;
  }
  if (rep.after.issues.size() >= rep.before.issues.size()) {
    rep.reason = "refused: no improvement (" + std::to_string(rep.before.issues.size()) + " issues before, " +
                 std::to_string(rep.after.issues.size()) + " after); the Brep is unchanged";
    return rep;
  }
  *this = std::move(trial);
  rep.accepted = true;
  rep.changed = true;
  rep.reason = "accepted: " + std::to_string(rep.before.issues.size()) + " issues before, " +
               std::to_string(rep.after.issues.size()) + " after";
  return rep;
}

'''
s = s.replace(anchor, impl + anchor, 1)
open(p, 'w').write(s)
