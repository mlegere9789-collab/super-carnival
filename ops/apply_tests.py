S = "/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/"
p = "/home/user/miniature-pancake/.claude/worktrees/agent-affecf0689743ce29/dino8-kernel/tests/test_basic.cpp"
s = open(p).read()
assert 'surfops_tolerance_tests' not in s
a = s.index("int main() {")
s = s[:a] + open(S + 'surfops_tests.txt').read() + s[a:]
reg = '''  RunTest("surfops_tolerance_tests::TestCurveRemoveMultiKnotsErrorBoundAndBudget", surfops_tolerance_tests::TestCurveRemoveMultiKnotsErrorBoundAndBudget);
  RunTest("surfops_tolerance_tests::TestSurfaceRemoveMultiKnotsBothDirections", surfops_tolerance_tests::TestSurfaceRemoveMultiKnotsBothDirections);
  RunTest("surfops_tolerance_tests::TestSurfaceFitToToleranceMeetsToleranceOnIndependentGrid", surfops_tolerance_tests::TestSurfaceFitToToleranceMeetsToleranceOnIndependentGrid);
  RunTest("surfops_tolerance_tests::TestBrepShrinkSurfacesTolerance", surfops_tolerance_tests::TestBrepShrinkSurfacesTolerance);
'''
anchor = '  RunTest("ON::End", ON::End);'
assert s.count(anchor) == 1
s = s.replace(anchor, reg + anchor)
open(p, 'w').write(s)
print("ok")
