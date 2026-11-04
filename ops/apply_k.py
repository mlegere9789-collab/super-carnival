import sys
S = "/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/"
W = "/home/user/miniature-pancake/.claude/worktrees/agent-affecf0689743ce29/dino8-kernel/"

def ins_before(path, anchor, code):
    s = open(path).read()
    assert s.count(anchor) == 1, (path, anchor)
    s = s.replace(anchor, code + anchor)
    open(path, 'w').write(s)

p = W + 'include/dino8/kernel/brep.h'
s = open(p).read()
if '#include <string>' not in s:
    s = s.replace("#include <functional>\n#include <utility>", "#include <functional>\n#include <string>\n#include <utility>", 1)
    open(p, 'w').write(s)

p = W + 'src/brep.cpp'
s = open(p).read()
tail = "}  // namespace dino8::kernel\n"
i = s.rfind(tail)
s = s[:i] + open(S + 'k_brep.txt').read() + s[i:]
open(p, 'w').write(s)

ins_before(W + 'src/curve.cpp', "Result NurbsCurve::MakeRational() {", open(S + 'k_curve.txt').read())
ins_before(W + 'src/surface_edit.cpp', "Result NurbsSurface::MakeUniform(int direction, double tolerance, double* out_max_deviation) {", open(S + 'k_surf.txt').read())
