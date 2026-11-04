S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
W = '/home/user/miniature-pancake/.claude/worktrees/agent-ae7c95149abcea35f/dino8-kernel/tests/test_basic.cpp'
t = open(W).read()
inc = open(S + 'ccf_rr_tests.inc').read()
marker = '}  // namespace fillet_cap_rim_tests\n'
assert t.count(marker) == 1
t = t.replace(marker, marker + inc, 1)
reg_after = '''  RunTest("fillet_cap_rim_tests::TestChamferCapRimMatchesChamferCylinderRimOnDensePolygonCylinder",
          fillet_cap_rim_tests::TestChamferCapRimMatchesChamferCylinderRimOnDensePolygonCylinder);
'''
assert t.count(reg_after) == 1
names = ['TestFilletRevolveRimCountersinkMatchesGreenIntegralAndBallGeometry',
         'TestFilletRevolveRimPlateRimMatchesPappusAndConcaveCornerAddsMaterial',
         'TestChamferRevolveRimCountersinkBevelMatchesGreenIntegral',
         'TestRevolveRimRefusesWithReasons']
reg = ''.join('  RunTest("revolve_rim_tests::%s",\n          revolve_rim_tests::%s);\n' % (n, n) for n in names)
t = t.replace(reg_after, reg_after + reg, 1)
open(W, 'w').write(t)
