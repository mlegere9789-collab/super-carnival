sp = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a96d6a48886afe947/dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
body = open(sp + 's1s_tests.cpp').read()
m = "int main() {\n  std::setvbuf(stdout, nullptr, _IONBF, 0);"
assert s.count(m) == 1
s = s.replace(m, body + m)
e = '  RunTest("ON::End", ON::End);'
assert s.count(e) == 1
runs = '''  RunTest("sweep1_sections_tests::TestSweep1SectionsStraightRailTwoAndThreeSectionsPassThroughAndFrustumVolume",
          sweep1_sections_tests::TestSweep1SectionsStraightRailTwoAndThreeSectionsPassThroughAndFrustumVolume);
  RunTest("sweep1_sections_tests::TestSweep1SectionsCurvedRailPassesThroughEverySection",
          sweep1_sections_tests::TestSweep1SectionsCurvedRailPassesThroughEverySection);
  RunTest("sweep1_sections_tests::TestSweep1SectionsRefusalsLeaveInputsUntouched",
          sweep1_sections_tests::TestSweep1SectionsRefusalsLeaveInputsUntouched);

'''
s = s.replace(e, runs + e)
open(p, 'w').write(s)
print('ok')
