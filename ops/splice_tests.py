S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
W = '/home/user/miniature-pancake/.claude/worktrees/agent-a27b1177de4ec1f50/dino8-kernel/tests/test_basic.cpp'
s = open(W).read()
add = open(S + 'sealed_tests.txt').read()
i = s.index('\nint main() {')
s = s[:i + 1] + add + s[i + 1:]
names = [
    'TestSealedBoxCylinderThroughHoleHasRealInnerLoopsAndExactVolume',
    'TestSealedVolumesObeyInclusionExclusionExactly',
    'TestSealedSteinmetzIsValidSolidWithClosedFormVolume',
    'TestSealedUnequalRadiusCylindersMatchQuadrature',
    'TestSealedRefusesWithReasonInsteadOfReturningADegradedBody',
    'TestVolumeOfSealedSolidPreconditionsAndGenuineSeamsSurvive',
]
runs = ''.join('  RunTest("sealed_boolean_tests::%s",\n          sealed_boolean_tests::%s);\n' % (n, n) for n in names)
j = s.index('  RunTest("ON::End", ON::End);')
s = s[:j] + runs + s[j:]
open(W, 'w').write(s)
