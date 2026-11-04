import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel/src/surface_edit.cpp'
s = open(p).read()
helpers = open(S + 'refit_helpers.inc').read()
tail = open(S + 'refit_tail.inc').read()
deg = sys.argv[1] if len(sys.argv) > 1 else '3'
helpers = helpers.replace('namespace {\n\n// ---', 'namespace {\n\n// Output degree floor of OffsetRefit().\nconstexpr int kRefitMinDegree = %s;\n\n// ---' % deg, 1)
head = 'Result NurbsSurface::OffsetRefit(double distance, NurbsSurface& out, double tolerance, double* achieved_deviation,'
assert s.count(head) == 1
s = s.replace(head, helpers + head)
a = s.index('  const int u_degree = DegreeU();\n  const int v_degree = DegreeV();\n  const int u_order = u_degree + 1;')
b = s.index('\nnamespace {\n\n// Brings `cand`')
s = s[:a] + tail + s[b:]
open(p, 'w').write(s)
