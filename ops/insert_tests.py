root = '/home/user/miniature-pancake/.claude/worktrees/agent-acf3fc4277e9dd195/dino8-kernel/tests/test_basic.cpp'
s = open(root).read()
new = open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/newtests.cpp').read()
new = new.replace("using dino8::kernel::Mesh;\n", "")
marker = "int main() {\n  std::setvbuf(stdout, nullptr, _IONBF, 0);"
assert s.count(marker) == 1
s = s.replace(marker, new + marker)
runs = ""
for n in ["TestSweep2CornerPolylineWallEdgesStayOnRails", "TestSweep2CornerArcThenLineAndTwoCornersWithMidSection",
          "TestSweep2CornerOnOneRailOnlyAndClosedRailRefusal", "TestSweep1SectionsClosedRailTorusAndVaryingRadii",
          "TestSweep1SectionsClosedRailEllipseTubeAndAnnulus", "TestSweep1SectionsClosedRailNonPlanarRingIsAValidSolid",
          "TestSweep1TwistOnAClosedRailIsAllowedForWholeTurns"]:
    runs += '  RunTest("sweep_closure_tests::%s",\n          sweep_closure_tests::%s);\n' % (n, n)
m2 = '  RunTest("ON::End", ON::End);'
assert s.count(m2) == 1
s = s.replace(m2, runs + m2)

# 1) change the pinned polyline-corner limit (documented known limit, now closed)
old = '''  // A polyline corner mid-way is NOT closed by more stations: the skin cannot follow a tangent jump between stations
  // (measured 0.252/0.366, 0.0886/0.223, 0.0823/0.0762, 0.0156/0.0228, 0.0108/0.00442 at 32..512 on rails 1/2).'''
new1 = '''  // A polyline corner mid-way used to be NOT closed by more stations: the skin cannot follow a tangent jump between
  // stations (it measured 0.252/0.366, 0.0886/0.223, 0.0823/0.0762, 0.0156/0.0228, 0.0108/0.00442 at 32..512 on rails 1/2).
  // CHANGED when the corner closure landed: a station pair now sits exactly at the paired corners and the skin is C0
  // there, so the wall edges stay on the rails (see sweep_closure_tests).'''
assert s.count(old) == 1
s = s.replace(old, new1)
old = '''  Check(std::max(rc.max_rail1_deviation, rc.max_rail2_deviation) > 2e-3,
        "sweep2 sections (polyline corner): known limit - even 512 stations leave the wall edges > 2e-3 from rails with a tangent jump (measured 0.0108)");'''
new2 = '''  Check(rc.corners == 1 && std::max(rc.max_rail1_deviation, rc.max_rail2_deviation) < 1e-9,
        "sweep2 sections (polyline corner): the former known limit is closed - the wall edges are within 1e-9 of the rails at 512 stations (was 0.0108; measured 1.1e-12)");'''
assert s.count(old) == 1
s = s.replace(old, new2)

# 2) the Sweep1Sections 'a closed rail' refusal pin documented a now-closed limit
old = '''  refuses("a closed rail", good, NurbsCurve::FromControlPoints({Point3d(0, 0, 0), Point3d(5, 0, 0), Point3d(5, 5, 0), Point3d(0, 0, 0)}, 1), "closed rail");'''
new3 = '''  // (a closed rail used to be refused outright here; it is a cyclic sweep now - see sweep_closure_tests. The same triangle rail still
  // refuses these sections, for the reason that applies: the plane z = 10 of the second circle never meets the rail in z = 0.)
  refuses("a closed rail the second section's plane never meets", good, NurbsCurve::FromControlPoints({Point3d(0, 0, 0), Point3d(5, 0, 0), Point3d(5, 5, 0), Point3d(0, 0, 0)}, 1), "never crosses");'''
assert s.count(old) == 1
s = s.replace(old, new3)
open(root, 'w').write(s)
print("done")
