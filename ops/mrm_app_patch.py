import sys
p = sys.argv[1] + '/dino8-app/src/commands/cmd_fillet.cpp'
s = open(p).read()


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:50]
    s = s.replace(old, new, 1)


rep("""bool TryRevolveRimChamfer(const ON_Brep& solid, Point3d point_on_rim, double distance_wall""", """// SEVERAL rims of one solid of revolution in one exact rebuild (kernel::FilletRevolveRims): every rim keeps its own
// radius, the kernel takes each setback from the original profile corner (so the order of the picks does not matter),
// refuses overlapping setbacks naming both rims, and accepts a solid that already carries torus blend faces / bevel
// cones from earlier runs.
bool TryRevolveRimsFillet(const ON_Brep& solid, const std::vector<std::pair<Point3d, double>>& rims, ON_Brep& out, std::string& err) {
  try {
    kernel::Brep kb;
    kb.raw() = solid;
    std::vector<kernel::RevolveRimFillet> kr;
    for (const auto& r : rims) {
      kernel::RevolveRimFillet f;
      f.point_on_rim = r.first;
      f.radius = r.second;
      kr.push_back(f);
    }
    return AcceptCapRimResult(kernel::FilletRevolveRims(kb, kr), out, err);
  } catch (const std::exception& ex) {
    err = ex.what();
    return false;
  }
}

bool TryRevolveRimChamfer(const ON_Brep& solid, Point3d point_on_rim, double distance_wall""")

rep("""// face, void, second shell, an already-blended solid, a point on no rim, tangent faces, a setback consuming a face, a
// chamfer without exactly one planar face) with a stated reason, handed back in `err` with `out` untouched.""", """// face, void, second shell, a point on no rim, the tangent seam of an earlier blend, a setback consuming a face, a
// chamfer without exactly one planar face) with a stated reason, handed back in `err` with `out` untouched. A solid
// that already carries the kernel's torus blends / bevel cones from an earlier run is read back and blended again.""")

a = s.index("    } else if (b && rims.front().rev) {")
b = s.index("    } else if (b && rims.front().tee) {")
new_flush = '''    } else if (b && rims.front().rev) {
      // One or several rims of a polygonal solid of revolution through the kernel (FilletRevolveRim / FilletRevolveRims, one
      // exact rebuild, each rim with its own radius); see Run().
      ON_Brep out;
      bool built = false;
      if (rims.size() == 1) {
        built = TryRevolveRimFillet(*b, rims.front().start, rims.front().radius, out, why);
      } else {
        std::vector<std::pair<Point3d, double>> kr;
        for (const PendingRim& r : rims) kr.emplace_back(r.start, r.radius);
        built = TryRevolveRimsFillet(*b, kr, out, why);
      }
      if (built) {
        ctx.Doc().BeginChange(label);
        if (SceneObject* orig = ctx.Doc().Find(id)) {
          orig->kind = ObjectKind::Brep;
          if (!orig->brep) orig->brep = std::make_unique<kernel::Brep>();
          orig->brep->raw() = out;
          orig->surface.reset();
          orig->InvalidateDisplay();
        }
        if (rims.size() == 1) {
          ctx.Print(label + ": rim of solid-of-revolution object " + std::to_string(id) + " replaced with an exact fillet (radius " + FormatNumber(rims.front().radius) +
                     "; exact kernel torus patch tangent to both faces at the rim, " + std::to_string(out.m_F.Count()) + " faces, closed solid)");
        } else {
          std::string radii;
          for (size_t i = 0; i < rims.size(); ++i) radii += (i ? ", " : "") + FormatNumber(rims[i].radius);
          ctx.Print(label + ": " + std::to_string(rims.size()) + " rims of solid-of-revolution object " + std::to_string(id) + " replaced with an exact fillet (radii " + radii +
                     "; exact kernel torus patches tangent to both faces at each rim, " + std::to_string(out.m_F.Count()) + " faces, closed solid)");
        }
        return;
      }
'''
s = s[:a] + new_flush + s[b:]

a = s.index("      // Last exact resort, only after every path above declined: the kernel's FilletRevolveRim")
b = s.index("      // Last of all: the kernel's FilletPipeTee")
new_stage = '''      // Last exact resort, only after every path above declined: the kernel's FilletRevolveRim / FilletRevolveRims - rims
      // of a polygonal solid of revolution (a countersunk / counterbored hole plate, a stepped shaft's steps, a flanged
      // ring, a cone-capped rim), also on a solid that already carries torus blends / bevel cones from an earlier run.
      // Dry run now so a refusal is known before anything is staged. A rim built by a Boolean is a chain of polyline
      // edges rather than one closed circle, so the pick is not required to be a closed edge: the kernel decides from
      // the point (a refusal is printed with its reason for a closed rim circle, and stays silent for an ordinary open
      // edge, which the planar paths below then handle exactly as before). SEVERAL rims picked on the same solid in one
      // run are staged and applied together at Enter in ONE exact kernel rebuild, each with the radius current at its
      // pick; a pick that cannot be blended together with the rims already staged (overlapping setbacks, the same rim
      // twice...) is refused with the kernel's reason and the staged rims stay staged.
      {
        ON_Brep rev_probe;
        std::string rev_why;
        if (TryRevolveRimFillet(*b, edge.PointAtStart(), radius_, rev_probe, rev_why)) {
          if ((!pending_fillet_.empty() && pending_fillet_id_ != pick.id) || (!pending_rims_.empty() && pending_rim_id_ != pick.id)) {
            ctx.Warn(label + ": an edge on a different object is already staged in this FilletEdge run; press Enter to apply it first, then run FilletEdge again for this object");
            return;
          }
          if (!pending_rims_.empty() && !pending_rims_.front().rev) {
            ctx.Warn(label + ": a different kind of rim of this object is already staged in this FilletEdge run; press Enter to apply it first, then run FilletEdge again for this rim");
            return;
          }
          if (!pending_rims_.empty()) {
            std::vector<std::pair<Point3d, double>> trial;
            for (const PendingRim& pr : pending_rims_) trial.emplace_back(pr.start, pr.radius);
            trial.emplace_back(edge.PointAtStart(), radius_);
            ON_Brep together;
            std::string together_why;
            if (!TryRevolveRimsFillet(*b, trial, together, together_why)) {
              ctx.Warn(label + ": this rim cannot be blended together with the " + std::to_string(pending_rims_.size()) + " rim(s) of this solid of revolution already staged (" + together_why +
                        "); the staged rim(s) stay staged - press Enter to apply them, then run FilletEdge again for this rim");
              return;
            }
          }
          pending_rim_id_ = pick.id;
          PendingRim pr{edge.PointAtStart(), false, radius_};
          pr.rev = true;
          pending_rims_.push_back(pr);
          ctx.Print(label + ": rim of solid-of-revolution object " + std::to_string(pick.id) + " staged for an exact kernel revolve-rim fillet (radius " +
                     FormatNumber(radius_) + ") - " + std::to_string(pending_rims_.size()) + " staged, Enter to apply");
          return;
        }
        if (edge.IsClosed()) ctx.Print(label + ": exact kernel revolve-rim fillet not used (" + rev_why + ")");
      }
'''
s = s[:a] + new_stage + s[b:]
open(p, 'w').write(s)
print('ok')
