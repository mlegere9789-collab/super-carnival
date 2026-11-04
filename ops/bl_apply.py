import sys
p = sys.argv[1] + '/dino8-kernel/tests/test_basic.cpp'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad'
t = open(p).read()
assert t.count("\nint main() {\n") == 1
t = t.replace("\nint main() {\n", "\n" + open(S + '/bl_tests.inc').read() + "int main() {\n", 1)
names = ["TestLawSamplingMeetsToleranceAgainstDenseProbeAndLinearLawIsTwoStations",
         "TestConvexLawFilletRailsTangencyG1VolumeAndSolid",
         "TestConvexLawCreaseShrinksWithToleranceAndLinearLawMatchesTaper",
         "TestConcaveLawFilletTangencyAndAddedVolume",
         "TestLawRefusalsStateTheirReason"]
reg = "".join('  RunTest("blend_law_tests::%s", blend_law_tests::%s);\n' % (n, n) for n in names)
assert t.count('  RunTest("ON::End", ON::End);') == 1
t = t.replace('  RunTest("ON::End", ON::End);', reg + '  RunTest("ON::End", ON::End);', 1)
open(p, 'w').write(t)
