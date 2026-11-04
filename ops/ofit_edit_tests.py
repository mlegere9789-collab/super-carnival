p = '/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'

a = s.index("namespace offset_fit_cost_tests {")
b = s.index("}  // namespace offset_fit_cost_tests") + len("}  // namespace offset_fit_cost_tests\n")
new = open(S + 'ofit_tests_final.inc').read()
s = s[:a] + new + s[b:]

old_reg = '  RunTest("offset_fit_cost_tests::TestOffsetFitCostReportAndAccuracyAtFourTolerances",\n          offset_fit_cost_tests::TestOffsetFitCostReportAndAccuracyAtFourTolerances);\n'
assert old_reg in s
s = s.replace(old_reg, old_reg +
    '  RunTest("offset_fit_cost_tests::TestOffsetFitTornOffsetIsRefusedWithItsGapAndSucceedsAboveIt",\n          offset_fit_cost_tests::TestOffsetFitTornOffsetIsRefusedWithItsGapAndSucceedsAboveIt);\n'
    '  RunTest("offset_fit_cost_tests::TestOffsetApproximateContractAgainstUnifiedOffset",\n          offset_fit_cost_tests::TestOffsetApproximateContractAgainstUnifiedOffset);\n')
open(p, 'w').write(s)
print('ok')
