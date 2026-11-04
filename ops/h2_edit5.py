base = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/src/commands/'
p = base + 'cmd_fillet.cpp'
s = open(p).read()

# --- 1. the shared build, before the class
cls = "class BlendSrfCommand : public Command {"
assert s.count(cls) == 1
shared = r'''// The boundary isoparametric edge of `s` named by (dir, at_max) - the same pair
// NearestBoundaryIsoEdge reports for a pick. Caller owns the returned curve.
static ON_Curve* BoundaryIsoEdge(const ON_NurbsSurface& s, int dir, bool at_max) {
  const ON_Interval du = s.Domain(0), dv = s.Domain(1);
  return dir == 1 ? s.IsoCurve(1, at_max ? du.Max() : du.Min()) : s.IsoCurve(0, at_max ? dv.Max() : dv.Min());
}

// BlendSrf's construction between two boundary edges (shared by BlendSrfCommand and the
// history rebuild RebuildBlendSrf): the exact kernel Hermite skin first, then (G1/G2 only)
// the app's generic Hermite build. `used_exact` says which one produced `built`.
static bool BuildBlendBetween(CommandContext& ctx, const ON_NurbsSurface& sa, int dir_a, bool at_max_a, const ON_NurbsSurface& sb,
                              int dir_b, bool at_max_b, int continuity, ON_NurbsSurface& built, bool& used_exact) {
  std::unique_ptr<ON_Curve> ea(BoundaryIsoEdge(sa, dir_a, at_max_a)), eb(BoundaryIsoEdge(sb, dir_b, at_max_b));
  if (!ea || !eb) return false;
  const double tol = std::max(ctx.Settings().absolute_tolerance, 1e-5);
  const double max_gap = std::max(std::max(SurfaceScale(sa), SurfaceScale(sb)) * 1e-3, tol * 10);
  double achieved_gap = std::numeric_limits<double>::infinity();
  // Try the exact kernel::NurbsSurface::BlendSurfaces() Hermite-skin
  // construction FIRST - reachable here because both rails are genuine
  // isoparametric boundaries (surface.h's own documented scope) - ahead
  // of the app's own generic BuildBlendSurfaceG1/G2Adaptive fallback,
  // the same "exact kernel construction first, fail open" structure
  // TryExactFillet/TryExactChamfer already establish elsewhere in this
  // file. This is also the only path that reaches Continuity=G3 at all.
  kernel::NurbsSurface ksa, ksb;
  ksa.raw() = sa;
  ksb.raw() = sb;
  const bool reverse1 = BlendRailsNeedReversal(*ea, *eb);
  const bool exact_ok = BuildBlendSurfaceKernelAdaptive(dir_a, at_max_a, ksa, dir_b, at_max_b, ksb, reverse1,
                                                         continuity, max_gap, 8, 256, built, &achieved_gap);
  bool ok = exact_ok && std::isfinite(achieved_gap);
  used_exact = ok;
  if (!ok && continuity < 3) {
    // G1/G2 can still fall back to the app's own generic Hermite build
    // (e.g. the exact construction's own degenerate-rail rejection); a
    // caller-requested G3 or G4 has no approximate equivalent to fall
    // back to at all, so it is reported as a failure instead of silently
    // dropping to a G1/G2 result the caller never asked for.
    auto uv_on = [&](const ON_NurbsSurface& s, const ON_Curve& c, double t01) {
      const ON_Interval d = c.Domain();
      const Point3d p3 = c.PointAt(d.ParameterAt(t01));
      double u, v;
      SurfaceClosestPoint(s, p3, u, v);
      return ON_2dPoint(u, v);
    };
    auto uv_a_fn = [&](double t) { return uv_on(sa, *ea, t); };
    auto uv_b_fn = [&](double t) { return uv_on(sb, *eb, t); };
    achieved_gap = std::numeric_limits<double>::infinity();
    continuity == 2 ? BuildBlendSurfaceG2Adaptive(*ea, sa, uv_a_fn, *eb, sb, uv_b_fn, max_gap, 24, 384, built, &achieved_gap)
                    : BuildBlendSurfaceG1Adaptive(*ea, sa, uv_a_fn, *eb, sb, uv_b_fn, false, max_gap, 24, 384, built, &achieved_gap);
    ok = std::isfinite(achieved_gap);
  }
  return ok;
}

'''
s = s.replace(cls, shared + cls)

# --- 2. Run(): use the shared build and record
a0 = s.index("    const double tol = std::max(ctx.Settings().absolute_tolerance, 1e-5);\n    const double max_gap = std::max(std::max(SurfaceScale(*sa), SurfaceScale(*sb)) * 1e-3, tol * 10);\n    ON_NurbsSurface built;")
a1 = s.index('    if (!ok) { ctx.Warn("BlendSrf: could not build the blend"); return; }')
new_mid = '''    delete ea;
    delete eb;
    ON_NurbsSurface built;
    bool used_exact = false;
    const bool ok = BuildBlendBetween(ctx, *sa, dir_a, at_max_a, *sb, dir_b, at_max_b, continuity_, built, used_exact);
'''
s = s[:a0] + new_mid + s[a1:]

old = '''    ObjectId nid = AddSurfaceFrom(ctx, built, like);
    ctx.Doc().Select(nid, true);
    const char* cname'''
assert old in s
s = s.replace(old, '''    ObjectId nid = AddSurfaceFrom(ctx, built, like);
    ctx.Doc().Select(nid, true);
    // History On: the blend is recorded as {surface A, surface B} with the boundary edges as (iso direction, at max)
    // and the face indices - intrinsic to each surface, so they survive Move/Rotate/Scale and control-point edits.
    RecordHistoryIfEnabled(ctx, nid, "BlendSrf", {fa.id, fb.id},
                           {{"dir_a", static_cast<double>(dir_a)}, {"max_a", at_max_a ? 1.0 : 0.0}, {"face_a", static_cast<double>(fa.face)},
                            {"dir_b", static_cast<double>(dir_b)}, {"max_b", at_max_b ? 1.0 : 0.0}, {"face_b", static_cast<double>(fb.face)},
                            {"cont", static_cast<double>(continuity_)}});
    const char* cname''', 1)
open(p, 'w').write(s)

# --- 3. rebuild function before RegisterFilletCommands
s = open(p).read()
marker = "void RegisterFilletCommands(CommandEngine& e) {"
rb = r'''// BlendSrf re-execution (history_rebuild.h): the same boundary edges (iso direction,
// min/max, face index) of the sources' CURRENT surfaces, the same continuity.
std::optional<SceneObject> RebuildBlendSrf(CommandContext& ctx, const HistoryInputs& in, const HistoryRecord& rec, std::string& why) {
  if (in.size() != 2) { why = "expected 2 source objects, the record has " + std::to_string(in.size()); return std::nullopt; }
  auto num = [&](const char* k) { const auto it = rec.num.find(k); return it == rec.num.end() ? 0.0 : it->second; };
  std::optional<ON_NurbsSurface> sa, sb;
  for (int k = 0; k < 2; ++k) {
    const SceneObject& o = *in[k];
    const int face = static_cast<int>(num(k == 0 ? "face_a" : "face_b"));
    if (o.kind != ObjectKind::Surface && o.kind != ObjectKind::Brep) {
      why = "source object " + std::to_string(o.id) + " is " + HistoryKindName(o.kind) + ", not a surface or polysurface";
      return std::nullopt;
    }
    std::optional<ON_NurbsSurface> s = SurfaceOfObject(o, face);
    if (!s) { why = "source object " + std::to_string(o.id) + " has no face " + std::to_string(face) + " any more"; return std::nullopt; }
    (k == 0 ? sa : sb) = s;
  }
  ON_NurbsSurface built;
  bool used_exact = false;
  if (!BuildBlendBetween(ctx, *sa, static_cast<int>(num("dir_a")), num("max_a") != 0.0, *sb, static_cast<int>(num("dir_b")), num("max_b") != 0.0,
                         static_cast<int>(num("cont")), built, used_exact)) {
    why = "the blend could not be built between the sources' current boundary edges";
    return std::nullopt;
  }
  kernel::NurbsSurface k;
  k.raw() = built;
  return SceneObject::MakeSurface(k);
}

'''
s = s.replace(marker, rb + marker, 1)
open(p, 'w').write(s)

p = base + 'history_rebuild.h'
h = open(p).read()
anchor = "// Offset (cmd_edit.cpp), curves:"
h = h.replace(anchor, '''// BlendSrf (cmd_fillet.cpp): sources {surface or polysurface A, B} (not consumed); num:
// dir_a/max_a/face_a and dir_b/max_b/face_b (each boundary edge as the isoparametric
// direction, whether the fixed parameter sits at its maximum, and the polysurface face
// index) and cont (1 Tangency, 2 Curvature, 3 G3, 4 G4). Refuses, with the reason, when a
// source is no longer a surface/polysurface with that face or the blend cannot be built.
std::optional<SceneObject> RebuildBlendSrf(CommandContext& ctx, const HistoryInputs& inputs, const HistoryRecord& rec, std::string& why);

''' + anchor, 1)
open(p, 'w').write(h)

p = base + 'cmd_history.cpp'
t = open(p).read()
old = '''  RegisterHistoryRebuilder("FilletEdge", '''
t = t.replace(old, '''  RegisterHistoryRebuilder("BlendSrf", "BlendSrf between two surface edges (Tangency/Curvature/G3/G4)", RebuildBlendSrf);
''' + old, 1)
old = '''  SetParams("FilletEdge", {'''
t = t.replace(old, '''  SetParams("BlendSrf", {
      ChoiceParam("continuity", "continuity of the blend with both surfaces", {"tangency", "curvature", "g3", "g4"},
                  [](const HistoryRecord& r) {
                    const int c = static_cast<int>(NumOf(r, "cont", 1.0));
                    return std::string(c == 4 ? "g4" : c == 3 ? "g3" : c == 2 ? "curvature" : "tangency");
                  },
                  [](HistoryRecord& r, const std::string& l) { r.num["cont"] = l == "g4" ? 4 : l == "g3" ? 3 : l == "curvature" ? 2 : 1; return std::string(); })});
''' + old, 1)
a = "Cap, Project/Pull (a source that maps to one piece), and the exact"
assert a in t
t = t.replace(a, "Cap, BlendSrf, Project/Pull (a source that maps to one piece), and the exact", 1)
open(p, 'w').write(t)
print('ok')
