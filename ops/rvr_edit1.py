import re
p='/home/user/miniature-pancake/.claude/worktrees/agent-a00162c747ab8322b/dino8-app/src/commands/cmd_fillet.cpp'
s=open(p).read()

# 1. wrappers
anchor="// True when `p` lies on an edge of `b` (within tol).\nbool PointOnAnyEdge"
assert s.count(anchor)==1
wr='''// ---------------------------------------------------------------------------
// Kernel revolve-rim wrappers (kernel::FilletRevolveRim / ChamferRevolveRim, fillet.h): exact blends on ONE rim of a
// polygonal solid of revolution - a plate with a countersunk / counterbored / plain hole, a stepped shaft (the rim may
// be an INSIDE corner, which adds material), a flanged ring, a cone-capped rim. They are tried only AFTER the capped
// cylinder / frustum wrappers above (and the app's own cylinder / hole classifiers) declined, so every solid those
// accept is built exactly as before. The kernel refuses everything it cannot read back (non-coaxial or non-analytic
// face, void, second shell, an already-blended solid, a point on no rim, tangent faces, a setback consuming a face, a
// chamfer without exactly one planar face) with a stated reason, handed back in `err` with `out` untouched.
// ---------------------------------------------------------------------------
bool TryRevolveRimFillet(const ON_Brep& solid, Point3d point_on_rim, double radius, ON_Brep& out, std::string& err) {
  try {
    kernel::Brep kb;
    kb.raw() = solid;
    return AcceptCapRimResult(kernel::FilletRevolveRim(kb, point_on_rim, radius), out, err);
  } catch (const std::exception& ex) {
    err = ex.what();
    return false;
  }
}

bool TryRevolveRimChamfer(const ON_Brep& solid, Point3d point_on_rim, double distance_wall, double distance_cap, ON_Brep& out, std::string& err) {
  try {
    kernel::Brep kb;
    kb.raw() = solid;
    return AcceptCapRimResult(kernel::ChamferRevolveRim(kb, point_on_rim, distance_wall, distance_cap), out, err);
  } catch (const std::exception& ex) {
    err = ex.what();
    return false;
  }
}

'''
s=s.replace(anchor,wr+anchor)

# 2. PendingRim
old="bool corner = false; bool cap = false; };"
assert s.count(old)==1
s=s.replace(old,"bool corner = false; bool cap = false; bool rev = false; };")

# 3. Run staging: after cap block
old='''        ctx.Print(label + ": exact kernel cap-rim fillet not used (" + cap_why + ")");
      }
'''
assert s.count(old)==1
new='''        ctx.Print(label + ": exact kernel cap-rim fillet not used (" + cap_why + ")");
        // Last exact resort, only after every path above declined: the kernel's FilletRevolveRim - ONE rim of a polygonal
        // solid of revolution (a countersunk / counterbored hole plate, a stepped shaft's inside corner, a cone-capped
        // rim). Dry run now so a refusal is known (and printed with the kernel's reason) before anything is staged; the
        // kernel blends one rim per solid per run (the result carries a torus, which it does not re-read), so a second
        // revolve rim in the same run is refused here with that explanation instead of being silently approximated.
        ON_Brep rev_probe;
        std::string rev_why;
        if (TryRevolveRimFillet(*b, edge.PointAtStart(), radius_, rev_probe, rev_why)) {
          if ((!pending_fillet_.empty() && pending_fillet_id_ != pick.id) || (!pending_rims_.empty() && pending_rim_id_ != pick.id)) {
            ctx.Warn(label + ": an edge on a different object is already staged in this FilletEdge run; press Enter to apply it first, then run FilletEdge again for this object");
            return;
          }
          if (!pending_rims_.empty()) {
            ctx.Warn(label + ": a rim of this solid of revolution is already staged in this FilletEdge run; the exact kernel revolve-rim fillet blends one rim per run - press Enter to apply it, then run FilletEdge again for the next rim");
            return;
          }
          pending_rim_id_ = pick.id;
          PendingRim pr{edge.PointAtStart(), false, radius_};
          pr.rev = true;
          pending_rims_.push_back(pr);
          ctx.Print(label + ": rim of solid-of-revolution object " + std::to_string(pick.id) + " staged for an exact kernel revolve-rim fillet (radius " +
                     FormatNumber(radius_) + ") - " + std::to_string(pending_rims_.size()) + " staged, Enter to apply");
          return;
        }
        ctx.Print(label + ": exact kernel revolve-rim fillet not used (" + rev_why + ")");
      }
'''
s=s.replace(old,new)

# 4. Flush branch
old='''    } else if (b && rims.front().cap) {'''
assert s.count(old)==1
new='''    } else if (b && rims.front().rev) {
      // One rim of a polygonal solid of revolution through the kernel (FilletRevolveRim); see Run().
      ON_Brep out;
      if (TryRevolveRimFillet(*b, rims.front().start, rims.front().radius, out, why)) {
        ctx.Doc().BeginChange(label);
        if (SceneObject* orig = ctx.Doc().Find(id)) {
          orig->kind = ObjectKind::Brep;
          if (!orig->brep) orig->brep = std::make_unique<kernel::Brep>();
          orig->brep->raw() = out;
          orig->surface.reset();
          orig->InvalidateDisplay();
        }
        ctx.Print(label + ": rim of solid-of-revolution object " + std::to_string(id) + " replaced with an exact fillet (radius " + FormatNumber(rims.front().radius) +
                   "; exact kernel torus patch tangent to both faces at the rim, " + std::to_string(out.m_F.Count()) + " faces, closed solid)");
        return;
      }
    } else if (b && rims.front().cap) {'''
s=s.replace(old,new)

# 5. chamfer sixth attempt
old='''    detail = "convex attempt: " + convex_err + "; concave attempt: " + concave_err + "; cylinder-rim attempt: " + rim_err + "; cone-rim attempt: " + cone_err +
             "; kernel cap-rim attempt: " + cap_err + "; hole-rim attempt: " + hole_err;'''
assert s.count(old)==1
new='''    // Sixth attempt, only when everything above declined: one rim of a polygonal solid of revolution (countersunk /
    // counterbored hole plate, stepped shaft, flanged ring, cone-capped rim) through kernel::ChamferRevolveRim -
    // distance1 along the cone / cylinder wall, distance2 across the planar face at the rim.
    std::string rev_err = "Distance/Angle mode has no revolve-rim construction";
    if (!use_angle && edge_is_closed && TryRevolveRimChamfer(solid, p0, d_i, d_j, out, rev_err)) {
      if (rim_chamfer) *rim_chamfer = true;
      rim_note_ = "; exact kernel revolve-rim bevel (cone / plane), distance1 along the wall and distance2 across the planar face";
      return true;
    }
    detail = "convex attempt: " + convex_err + "; concave attempt: " + concave_err + "; cylinder-rim attempt: " + rim_err + "; cone-rim attempt: " + cone_err +
             "; kernel cap-rim attempt: " + cap_err + "; hole-rim attempt: " + hole_err + "; kernel revolve-rim attempt: " + rev_err;'''
s=s.replace(old,new)
open(p,'w').write(s)
