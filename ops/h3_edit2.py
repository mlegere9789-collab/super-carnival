D = '/home/user/miniature-pancake/.claude/worktrees/agent-a6793fdf3e148e078/dino8-app/src/commands/'
p = D + 'cmd_surface.cpp'
s = open(p).read()

# 1. locate the non-planar block
start_marker = "  const double patch_tol = ctx.Settings().absolute_tolerance > 0 ? ctx.Settings().absolute_tolerance : 0.001;\n  double flat_dev = 0.0;\n"
a = s.index(start_marker)
blk_start = s.index("    Row boundary_samples;", a)
end_marker = "    ctx.Print(\"Patch: non-planar data (best-fit plane misses it by \" + FormatDeviation(flat_dev) + \") but \" + planar_reason + \"; using the planar construction\");\n  }\n"
blk_end = s.index(end_marker, a)
body = s[blk_start:blk_end]  # the inside of `if (flat_dev > patch_tol) {` up to the final print

# transform the body for the helper
body2 = body
body2 = body2.replace("            ctx.Doc().Add(SceneObject::MakeBrep(std::move(face)));\n", "            SceneObject made = SceneObject::MakeBrep(std::move(face));\n")
body2 = body2.replace("                                           std::to_string(holes.size() + 1) + \" trimmed edges is within \" + FormatDeviation(edge_dev) + \" of its curve\"));\n            return;\n",
                      "                                           std::to_string(holes.size() + 1) + \" trimmed edges is within \" + FormatDeviation(edge_dev) + \" of its curve\"));\n            return made;\n")
body2 = body2.replace("      ctx.Doc().Add(SceneObject::MakeSurface(patch));\n", "      SceneObject made_srf = SceneObject::MakeSurface(patch);\n")
body2 = body2.replace("                \" point(s) (\" + net + \"); untrimmed, spanning the data's extent\");\n      return;\n",
                      "                \" point(s) (\" + net + \"); untrimmed, spanning the data's extent\");\n      return made_srf;\n")
assert "return made;" in body2 and "return made_srf;" in body2 and "ctx.Doc().Add" not in body2
# the trailing planar_reason computation sits at the end of body2 (before the final print). Keep it.
helper = '''// The non-planar Patch: the kernel's least-squares NurbsSurface::FitPatch through the boundary samples of every
// selected curve and the selected point objects, trimmed by the largest closed curve (others becoming holes) when
// there is one. Shared by Patch (live) and RebuildPatchFit (UpdateHistory). Returns the object (notes printed), or
// nullopt with `planar_reason` set when the data are not better served by the fitted surface than by the flat plane
// (the live command then runs its planar construction, the rebuild refuses). `pts` holds every curve sample (32 per
// curve) and point, `flat_dev` the worst distance of those from their own best-fit plane.
std::optional<SceneObject> FitNonPlanarPatch(CommandContext& ctx, const Row& pts, const std::vector<kernel::NurbsCurve>& all_curves,
                                              const Row& point_objects, double flat_dev, double patch_tol, int ncrv, int npts,
                                              std::string& planar_reason) {
  (void)pts;
  std::vector<kernel::NurbsCurve> closed;
  for (const kernel::NurbsCurve& c : all_curves) if (c.IsClosed()) closed.push_back(c);
  {
''' + body2 + '''  }
  return std::nullopt;
}

'''
# the body begins with 4-space indented code that lived inside `if (...) {`; wrap in a block (above) keeps indentation.

# 2. replace the block in Patch by a call
call = '''    std::optional<SceneObject> fitted = FitNonPlanarPatch(ctx, pts, all_curves, point_objects, flat_dev, patch_tol, ncrv, npts, planar_reason);
    if (fitted) {
      const ObjectId new_id = ctx.Doc().Add(std::move(*fitted));
      // History: {every selected curve and point, in selection order}; RebuildPatchFit re-runs the same fit.
      if (fit_ids.size() == static_cast<size_t>(ncrv + npts)) RecordHistoryIfEnabled(ctx, new_id, "Patch", fit_ids, {{"fit", 1.0}});
      return;
    }
'''
s = s[:blk_start] + call + s[blk_end:]

# 3. insert helper before Patch
pm = "void Patch(CommandContext& ctx, const std::vector<ObjectId>& ids) {\n"
i = s.index(pm)
s = s[:i] + helper + s[i:]

# 4. fit_ids collection in the Patch selection loop
s = s.replace("  std::vector<ObjectId> closed_ids;\n  int npts = 0, ncrv = 0;\n", "  std::vector<ObjectId> closed_ids;\n  std::vector<ObjectId> fit_ids;               // every curve and point, in selection order (the history sources)\n  int npts = 0, ncrv = 0;\n", 1)
s = s.replace("    if (o->kind == ObjectKind::Point) { pts.push_back(o->point); point_objects.push_back(o->point); ++npts; }\n",
              "    if (o->kind == ObjectKind::Point) { pts.push_back(o->point); point_objects.push_back(o->point); fit_ids.push_back(id); ++npts; }\n", 1)
s = s.replace("      all_curves.push_back(*o->curve);\n      Row s = SampleCurve(*o->curve, 32, o->curve->IsClosed());\n",
              "      all_curves.push_back(*o->curve);\n      fit_ids.push_back(id);\n      Row s = SampleCurve(*o->curve, 32, o->curve->IsClosed());\n", 1)
assert "fit_ids.push_back(id); ++npts" in s and "      fit_ids.push_back(id);\n      Row s" in s

# 5. RebuildPatchFit after RebuildPatch
rp_end = "  if (!b) return std::nullopt;\n  return SceneObject::MakeBrep(WrapBrep(b));\n}\n"
j = s.index(rp_end, s.index("std::optional<SceneObject> RebuildPatch(")) + len(rp_end)
fitfn = '''
// Patch, the non-planar fitted case (Patch above): sources are every selected curve and point in selection order. The
// fit is re-run on their current shape. Refuses (reason in `why`, the object kept) when a source is no longer a curve or
// point, or the data are now within tolerance of a plane (the live command would build a planar patch, a different
// construction), or the fit is no better than the flat plane or fails.
std::optional<SceneObject> RebuildPatchFit(CommandContext& ctx, const std::vector<const SceneObject*>& inputs, const HistoryRecord&, std::string& why) {
  Row pts, point_objects;
  std::vector<kernel::NurbsCurve> all_curves;
  int ncrv = 0, npts = 0;
  for (const SceneObject* o : inputs) {
    if (o->kind == ObjectKind::Point) { pts.push_back(o->point); point_objects.push_back(o->point); ++npts; }
    else if (o->kind == ObjectKind::Curve && o->curve) {
      all_curves.push_back(*o->curve);
      const Row smp = SampleCurve(*o->curve, 32, o->curve->IsClosed());
      pts.insert(pts.end(), smp.begin(), smp.end());
      ++ncrv;
    } else {
      why = "source object " + std::to_string(o->id) + " is " + HistoryKindName(o->kind) + ", not a curve or a point";
      return std::nullopt;
    }
  }
  if (pts.size() < 3) { why = "fewer than three points are left in the sources"; return std::nullopt; }
  const double tol = ctx.Settings().absolute_tolerance > 0 ? ctx.Settings().absolute_tolerance : 0.001;
  const ON_Plane fit = FitPlane(pts);
  double flat_dev = 0.0;
  for (const Point3d& p : pts) flat_dev = std::max(flat_dev, std::fabs(fit.DistanceTo(p)));
  if (flat_dev <= tol) {
    why = "the sources are now flat (within " + FormatNumber(tol) + " of their best-fit plane), so the fitted patch no longer applies";
    return std::nullopt;
  }
  std::string reason;
  std::optional<SceneObject> r = FitNonPlanarPatch(ctx, pts, all_curves, point_objects, flat_dev, tol, ncrv, npts, reason);
  if (!r) why = "the patch fit no longer works on the edited sources: " + reason;
  return r;
}
'''
s = s[:j] + fitfn + s[j:]
open(p, 'w').write(s)

h = open(D + 'history_rebuild.h').read()
decl = '''
// Patch, non-planar fitted case (cmd_surface.cpp): sources = every selected curve and point, in selection
// order; reads no num parameters. Re-runs the least-squares fit (and the trim by the largest closed curve) on
// their current shape. Refuses with `why` when the data became planar, the fit fails or is no better than the plane.
std::optional<SceneObject> RebuildPatchFit(CommandContext& ctx, const std::vector<const SceneObject*>& inputs, const HistoryRecord& rec, std::string& why);
'''
m = "\n// NetworkSrf (the free NetworkSrf function, cmd_surface.cpp), 2-curve case"
assert m in h
h = h.replace(m, decl + m, 1)
open(D + 'history_rebuild.h', 'w').write(h)

# registry: Patch accepts either the planar single curve or the fitted multi-source form
c = open(D + 'cmd_history.cpp').read()
old = '  RegisterHistoryRebuilder("Patch", "Patch (single closed planar curve)", OneCurve(RebuildPatch));\n'
new = '''  // Patch: one source that is a closed planar curve = the planar trim (RebuildPatch); anything else = the
  // non-planar least-squares fit through all the recorded curves and points (RebuildPatchFit).
  RegisterHistoryRebuilder("Patch", "Patch (planar trim of one closed curve, or the least-squares fit through curves and points)",
      [](CommandContext& ctx, const HistoryInputs& in, const HistoryRecord& rec, std::string& why) -> std::optional<SceneObject> {
        if (in.empty()) { why = "the record has no source object"; return std::nullopt; }
        if (in.size() == 1 && in[0]->kind == ObjectKind::Curve && in[0]->curve && rec.num.count("fit") == 0) {
          const kernel::NurbsCurve* c = HistoryRequireCurve(in[0], why);
          return c ? RebuildPatch(ctx, *c, rec) : std::nullopt;
        }
        return RebuildPatchFit(ctx, in, rec, why);
      });
'''
assert old in c
c = c.replace(old, new)
open(D + 'cmd_history.cpp', 'w').write(c)
print('ok')
