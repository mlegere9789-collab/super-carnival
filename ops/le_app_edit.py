p = '/home/user/miniature-pancake/.claude/worktrees/agent-af78da953e7552ee8/dino8-app/src/commands/cmd_fillet.cpp'
s = open(p).read()
a = s.index('class SplitEdgeCommand : public Command {')
b = s.index('class MergeEdgeCommand : public Command {')
new = '''class SplitEdgeCommand : public Command {
 public:
  void Begin(CommandContext&) override { WantPoint("Click the edge, near where you want to split it"); }
  // The split is the kernel's Brep::SplitNakedEdgeAt: the edge curve and EVERY trim's own 2D curve are cut exactly
  // (ON_Curve::Split) at the picked point's own projection on that trim's face - never at one shared normalized
  // parameter fraction, which is only right when a trim's parameterization is proportional to the edge's (it is not on
  // a fillet arc against a plane, a rational arc, or a non-uniformly parameterized trim). It handles a naked (1 trim),
  // a shared (2 trims) and a non-manifold (3+ trims) edge alike and keeps the kernel's own per-face side tables
  // consistent. Refused with the reason (nothing changed): a closed edge, a pick on an end vertex, a pick that is not
  // on the edge.
  void OnPoint(CommandContext& ctx, Point3d p) override {
    std::optional<EdgePick> pick = PickEdgeAny(ctx, p);
    if (!pick) { ctx.Warn("No edge near that point"); return; }
    const SceneObject* o = ctx.Doc().Find(pick->id);
    if (!o || o->kind != ObjectKind::Brep || !o->brep) { ctx.Warn("SplitEdge needs a polysurface edge"); Finish(); return; }
    kernel::Brep kb = *o->brep;
    const int old_ei = pick->edge;
    if (old_ei < 0 || old_ei >= kb.raw().m_E.Count()) { Finish(); return; }
    double t;
    if (!EdgeClosest(kb.raw().m_E[old_ei], p, t)) { Finish(); return; }
    const ON_BrepEdge& edge = kb.raw().m_E[old_ei];
    const int trims = edge.TrimCount();
    if (edge.IsClosed()) {
      ctx.Warn("SplitEdge: edge " + std::to_string(old_ei) + " is closed (both ends are one vertex); a closed edge is not split - nothing changed");
      Finish();
      return;
    }
    const Point3d at = edge.PointAt(t);
    const Point3d a0 = edge.PointAtStart(), a1 = edge.PointAtEnd();
    const double tol = std::max(ctx.Settings().absolute_tolerance, 1e-5);
    if (at.DistanceTo(a0) <= tol || at.DistanceTo(a1) <= tol) {
      ctx.Warn("SplitEdge: the picked point is on an end vertex of edge " + std::to_string(old_ei) + " (within " + FormatNumber(tol) + "); nothing to split - nothing changed");
      Finish();
      return;
    }
    if (kb.SplitNakedEdgeAt(old_ei, at, tol) != kernel::Result::Ok) {
      ctx.Warn("SplitEdge: the kernel refused to split edge " + std::to_string(old_ei) + " at that point - nothing changed");
      Finish();
      return;
    }
    ctx.Doc().BeginChange("SplitEdge");
    if (SceneObject* orig = ctx.Doc().Find(pick->id)) { *orig->brep = std::move(kb); orig->InvalidateDisplay(); }
    ctx.Print("SplitEdge: edge " + std::to_string(pick->edge) + " split at t=" + FormatNumber(t) + " (kernel exact split: " + std::to_string(trims) +
              " trim(s) cut on their own faces' surfaces, new vertex " + FormatPoint(at) + ")");
    Finish();
  }
};

'''
s = s[:a] + new + s[b:]
open(p, 'w').write(s)
print('ok')
