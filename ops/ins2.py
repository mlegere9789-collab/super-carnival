root = '/home/user/miniature-pancake/.claude/worktrees/agent-a34f41bb080e3eecc/'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = root + 'dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
# the test namespace goes just before main
marker = 'int main() {'
assert s.count(marker) == 1
s = s.replace(marker, open(S + 'net_tests.txt').read() + marker, 1)
extra = open(S + 'net_runs.txt').read()
m2 = '  RunTest("ON::End", ON::End);'
assert s.count(m2) == 1
s = s.replace(m2, extra + m2, 1)
open(p, 'w').write(s)
q = root + 'dino8-kernel/src/surface_edit.cpp'
t = open(q).read()
if '#include <string>' not in t:
    t = t.replace('#include <stdexcept>\n', '#include <stdexcept>\n#include <string>\n', 1)
open(q, 'w').write(t)
print('ok')
