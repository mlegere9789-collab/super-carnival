import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
inc = open(S + 'fitcost_tests.inc').read()
table = open(S + 'before_table.txt').read().strip() if len(sys.argv) > 1 else \
    ",\n    ".join("{" + ",".join("{-1,-1,0}" for _ in range(4)) + "}" for _ in range(5))
inc = inc.replace("BEFORE_TABLE", table)
marker = "}  // namespace offset_parity_tests\n"
assert s.count(marker) == 1
s = s.replace(marker, marker + inc)
reg = '  RunTest("offset_parity_tests::TestPartialSphereCylinderConeSeamStraddlingAreExact",\n          offset_parity_tests::TestPartialSphereCylinderConeSeamStraddlingAreExact);\n'
assert reg in s
s = s.replace(reg, reg + '  RunTest("offset_fit_cost_tests::TestOffsetFitCostReportAndAccuracyAtFourTolerances",\n          offset_fit_cost_tests::TestOffsetFitCostReportAndAccuracyAtFourTolerances);\n')
open(p, 'w').write(s)
