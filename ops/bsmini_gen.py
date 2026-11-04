import os
wt = "/home/user/miniature-pancake/.claude/worktrees/agent-a666ec8f2a94100e8/dino8-kernel/tests/test_basic.cpp"
D = "/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/bsmini"
os.makedirs(D, exist_ok=True)
lines = open(wt).read().split("\n")
a = next(i for i, l in enumerate(lines) if l.startswith("namespace body_section_tests"))
b = next(i for i, l in enumerate(lines) if l.startswith("}  // namespace body_section_tests"))
head = '''#include <algorithm>
#include <cmath>
#include <cstdio>
#include <set>
#include <string>
#include <vector>
#include "dino8/kernel/brep.h"
#include "dino8/kernel/curve.h"
#include "dino8/kernel/surface_intersect.h"
static int g_failures = 0;
static void Check(bool c, const char* w) { if (!c) { std::fprintf(stderr, "FAILED: %s\\n", w); ++g_failures; } else std::printf("ok: %s\\n", w); }
'''
tests = ["TestBodySectionCylinderIsOneClosedExactCircle", "TestBodySectionSphereMatchesCapRadiusFormula",
         "TestBodySectionBoxStitchesFourWallsIntoOnePerimeter", "TestBodySectionObliquePlaneThroughCylinderIsEllipse",
         "TestBodySectionRefusesMissesAndInvalidPlanes"]
tail = "int main() {\n  ON::Begin();\n  using namespace body_section_tests;\n"
for t in tests:
    tail += '  try { %s(); } catch (const std::exception& e) { std::fprintf(stderr, "FAILED: %s threw %%s\\n", e.what()); ++g_failures; }\n' % (t, t)
tail += '  ON::End();\n  std::printf("failures=%d\\n", g_failures);\n  return g_failures ? 1 : 0;\n}\n'
open(D + "/bsmini.cpp", "w").write(head + "\n".join(lines[a:b + 1]) + "\n" + tail)
