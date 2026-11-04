D = '/home/user/miniature-pancake/.claude/worktrees/agent-a6793fdf3e148e078/dino8-app/src/commands/'
p = D + 'cmd_fillet.cpp'
s = open(p).read()

# 1. cut the general tail out of Run
a = s.index("    FilletBuild fb2;\n    // Same exact plane+perpendicular-cylinder closed form FilletEdge uses")
b = s.index("    ctx.Doc().BeginChange(chamfer ? \"ChamferSrf\" : \"FilletSrf\");\n    ON_NurbsSurface result_surface = fb2.fillet;\n    if (chamfer) result_surface = RuledBetween(fb2.contact_curve_a, fb2.contact_curve_b);\n")
tail = s[a:b]
# tail = fb2 declaration, the plane+cylinder variable branch, the adaptive fallback, the error return
assert "BuildFilletAdaptive" in tail and "Warn(std::string(chamfer" in tail
new_call = '''    FilletBuild fb2;
    ON_NurbsSurface result_surface;
    if (!BuildSurfaceFilletBetween(*sa, *sb, r0, r1, variable, chamfer, tol, fb2, result_surface)) {
      ctx.Warn(std::string(chamfer ? "ChamferSrf" : "FilletSrf") + ": " + fb2.error);
      return;
    }
    ctx.Doc().BeginChange(chamfer ? "ChamferSrf" : "FilletSrf");
'''
old_after = "    ctx.Doc().BeginChange(chamfer ? \"ChamferSrf\" : \"FilletSrf\");\n    ON_NurbsSurface result_surface = fb2.fillet;\n    if (chamfer) result_surface = RuledBetween(fb2.contact_curve_a, fb2.contact_curve_b);\n"
s = s[:a] + new_call + s[b + len(old_after):]

# 2. helper before the class
helper_body_variable = tail[tail.index("    // Same exact plane+perpendicular-cylinder"):tail.index("    if (!fb2.ok) { ctx.Warn(std::string(chamfer")]
# adapt names: *sa -> sa, *sb -> sb, radius_at defined inside helper
helper_body = helper_body_variable.replace("*sa", "sa").replace("*sb", "sb")
helper_body = helper_body.replace("    FilletBuild fb2;\n", "")
helper = '''namespace {
// The general (approximate rolling-ball / ruled) construction of FilletSrf/ChamferSrf/VariableFilletSrf/VariableChamferSrf
// between two surfaces, shared by FilletTwoSurfacesCommand::Run and RebuildSurfaceFillet (UpdateHistory). Returns false with
// fb2.error set when no fillet can be built.
bool BuildSurfaceFilletBetween(const ON_NurbsSurface& sa, const ON_NurbsSurface& sb, double r0, double r1, bool variable, bool chamfer,
                               double tol, FilletBuild& fb2, ON_NurbsSurface& result_surface) {
  auto radius_at = [&](double t) { return r0 + (r1 - r0) * t; };
''' + helper_body + '''  if (!fb2.ok) return false;
  result_surface = chamfer ? RuledBetween(fb2.contact_curve_a, fb2.contact_curve_b) : fb2.fillet;
  return true;
}
}  // namespace

'''
cm = "// FilletSrf / ChamferSrf: pick two faces/surfaces directly.\n"
i = s.index(cm)
# insert before the comment-block's leading separator line: find the start of the previous line "// ----"
i = s.rindex("// ----", 0, i)
s = s[:i] + helper + s[i:]

# 3. record after the general build (Trim=No only)
anchor = "    ctx.Doc().Select(fillet_id, true);\n    ctx.Print(std::string(chamfer ? \"ChamferSrf\" : \"FilletSrf\") + \": built between object \""
assert anchor in s
rec = '''    // History On, Trim=No: the fillet is a standalone surface between two UNTOUCHED sources, so it can be re-run when either
    // moves. With Trim=Yes the sources themselves are cut by the fillet's contact curves, which a re-run could not undo: not recorded.
    if (!trim_) {
      RecordHistoryIfEnabled(ctx, fillet_id, chamfer ? "ChamferSrf" : "FilletSrf", {fa.id, fb.id},
                             {{"face_a", static_cast<double>(fa.face)}, {"face_b", static_cast<double>(fb.face)}, {"r0", r0}, {"r1", r1},
                              {"variable", variable ? 1.0 : 0.0}});
    } else if (ctx.App().State().history_recording) {
      ctx.Print(std::string(chamfer ? "ChamferSrf" : "FilletSrf") + ": no history recorded - Trim=Yes cuts the two source surfaces, which a rebuild could not undo (use Trim=No to keep it associative)");
    }
'''
s = s.replace(anchor, rec + anchor, 1)

# 4. RebuildSurfaceFillet next to RebuildBlendSrf
rb = "void RegisterFilletCommands(CommandEngine& e) {\n"
fn = '''// FilletSrf / ChamferSrf / VariableFilletSrf / VariableChamferSrf, general untrimmed case (Trim=No): sources {A, B}; num: face_a, face_b
// (polysurface face indices), r0, r1 (radius at the start/end of the spine; equal unless variable), variable (1/0). Re-runs the
// same BuildSurfaceFilletBetween the live command builds with, so the result follows either source. Chamfer or fillet is the
// record's command name. Refuses with the reason when a source has no such face any more or no fillet can be built.
std::optional<SceneObject> RebuildSurfaceFillet(CommandContext& ctx, const HistoryInputs& in, const HistoryRecord& rec, std::string& why) {
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
  const double tol = std::max(ctx.Settings().absolute_tolerance, 1e-5);
  FilletBuild fb2;
  ON_NurbsSurface built;
  if (!BuildSurfaceFilletBetween(*sa, *sb, num("r0"), num("r1"), num("variable") != 0.0, rec.command == "ChamferSrf", tol, fb2, built)) {
    why = "the fillet could not be built between the sources' current shapes: " + fb2.error;
    return std::nullopt;
  }
  kernel::NurbsSurface k;
  k.raw() = built;
  return SceneObject::MakeSurface(k);
}

'''
s = s.replace(rb, fn + rb, 1)
open(p, 'w').write(s)

h = open(D + 'history_rebuild.h').read()
decl = '''
// FilletSrf / ChamferSrf (and the Variable forms), Trim=No only (cmd_fillet.cpp): sources {A, B} (not consumed); num:
// face_a, face_b, r0, r1, variable. The record's command name selects fillet (FilletSrf) or ruled chamfer (ChamferSrf).
// Refuses, with the reason, when a source has no such face any more or no fillet can be built.
std::optional<SceneObject> RebuildSurfaceFillet(CommandContext& ctx, const HistoryInputs& inputs, const HistoryRecord& rec, std::string& why);
'''
m = "\n// Offset (cmd_edit.cpp), curves:"
assert m in h
h = h.replace(m, decl + m, 1)
open(D + 'history_rebuild.h', 'w').write(h)

c = open(D + 'cmd_history.cpp').read()
old = '  RegisterHistoryRebuilder("FilletEdge",'
new = '''  RegisterHistoryRebuilder("FilletSrf", "FilletSrf/VariableFilletSrf between two surfaces (Trim=No, general rolling-ball construction)", RebuildSurfaceFillet);
  RegisterHistoryRebuilder("ChamferSrf", "ChamferSrf/VariableChamferSrf between two surfaces (Trim=No, ruled between the contact curves)", RebuildSurfaceFillet);
'''
assert old in c
c = c.replace(old, new + old, 1)
# params
old2 = '  for (const char* name : {"BooleanUnion", "BooleanDifference", "BooleanIntersection", "Boolean2Objects"}) SetParams(name, BooleanParams());\n'
assert old2 in c
newp = '''  for (const char* name : {"FilletSrf", "ChamferSrf"}) {
    SetParams(name, {
        NumberParam("radius", "radius (distance) at the start of the spine; a constant-radius result keeps its end radius equal", "> 0",
                    [](const HistoryRecord& r) { return NumOf(r, "r0"); },
                    [](HistoryRecord& r, double d) -> std::string {
                      if (!(d > 0.0)) return "radius must be positive";
                      const bool follows = NumOf(r, "r1") == NumOf(r, "r0");
                      r.num["r0"] = d;
                      if (follows) r.num["r1"] = d;
                      return "";
                    }),
        NumberParam("endradius", "radius at the end of the spine (setting it makes the result variable)", "> 0",
                    [](const HistoryRecord& r) { return NumOf(r, "r1"); },
                    [](HistoryRecord& r, double d) -> std::string {
                      if (!(d > 0.0)) return "endradius must be positive";
                      r.num["r1"] = d;
                      r.num["variable"] = 1.0;
                      return "";
                    })});
  }
'''
c = c.replace(old2, newp + old2, 1)
open(D + 'cmd_history.cpp', 'w').write(c)
print('ok')
