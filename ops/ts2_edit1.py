p = '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/src/commands/cmd_solids.cpp'
s = open(p).read()
def rep(a, b):
    global s
    assert s.count(a) == 1, a
    s = s.replace(a, b)
rep("  int caps = 0;\n};\n\nstd::optional<RevolvedCage> BuildRevolvedCage",
    "  int caps = 0;\n  std::vector<std::pair<ON_3dPoint, ON_3dPoint>> apex_spokes;  // edges into a collapsed end row's apex (float-rounded positions)\n};\n\nstd::optional<RevolvedCage> BuildRevolvedCage")
rep("  const bool flip = sv < 0.0;\n  ON_Mesh& raw = rc.mesh.raw();",
    "  for (int e : {0, M}) {\n    if (!degenerate[static_cast<size_t>(e)]) continue;\n    const int nj = (e == 0) ? 1 : M - 1;\n    const ON_3fPoint apex(pos[static_cast<size_t>(at(e, 0))]);\n    for (int i = 0; i < N; ++i) rc.apex_spokes.emplace_back(ON_3dPoint(apex), ON_3dPoint(ON_3fPoint(pos[static_cast<size_t>(at(nj, i))])));\n  }\n  const bool flip = sv < 0.0;\n  ON_Mesh& raw = rc.mesh.raw();")
rep("      cur.crease_edges = sd.SetCreasesByDihedral(kFidelityCreaseAngleDeg);\n      kernel::SubDInterpolationReport frep;\n      const kernel::BoundingBox cbb = cage->mesh",
    "      cur.crease_edges = sd.SetCreasesByDihedral(kFidelityCreaseAngleDeg);\n      // A cone's apex is a sharp point: crease its spokes so Catmull-Clark does not round the tip off.\n      for (const auto& sp : cage->apex_spokes) if (sd.SetCrease(sp.first, sp.second, true, 1e-5 * diag)) ++cur.crease_edges;\n      kernel::SubDInterpolationReport frep;\n      const kernel::BoundingBox cbb = cage->mesh")
open(p, 'w').write(s)
print('ok')
