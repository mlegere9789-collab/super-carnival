import sys
root = sys.argv[1]
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = root + '/tests/test_basic.cpp'
s = open(p).read()
inc = open(S + 'xt_tests.inc').read()
for k, f in (('@BOX@', 'fixture_box.xt'), ('@CYL@', 'fixture_cylinder.xt'), ('@SPH@', 'fixture_sphere.xt')):
    inc = inc.replace(k, open(S + 'fix/' + f).read())
assert 'TestParasolidXtFixtureBox' not in s
s = s.replace('int main() {', inc + '\nint main() {', 1)
runs = '''  RunTest("TestParasolidXtFixtureBox", TestParasolidXtFixtureBox);
  RunTest("TestParasolidXtFixtureCylinder", TestParasolidXtFixtureCylinder);
  RunTest("TestParasolidXtFixtureSphere", TestParasolidXtFixtureSphere);
  RunTest("TestParasolidXtRoundTripSolids", TestParasolidXtRoundTripSolids);
  RunTest("TestParasolidXtRoundTripFilletedBoxAndFile", TestParasolidXtRoundTripFilletedBoxAndFile);
  RunTest("TestParasolidXtNegativeControls", TestParasolidXtNegativeControls);

'''
m = '  RunTest("ON::End", ON::End);'
assert m in s
s = s.replace(m, runs + m, 1)
s = s.replace('#include "dino8/kernel/mesh.h"\n', '#include "dino8/kernel/mesh.h"\n#include "dino8/kernel/parasolid_xt.h"\n', 1)
if '#include <filesystem>' not in s:
    s = s.replace('#include <fstream>\n', '#include <filesystem>\n#include <fstream>\n', 1)
open(p, 'w').write(s)
