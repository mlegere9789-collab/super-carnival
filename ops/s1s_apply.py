import sys
sp = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
wt = '/home/user/miniature-pancake/.claude/worktrees/agent-a96d6a48886afe947/dino8-kernel/'
p = wt + 'src/sweep.cpp'
s = open(p).read()
impl = open(sp + 's1s_impl.cpp').read()
marker = "Brep Brep::Pipe(const NurbsCurve& rail, double radius"
assert s.count(marker) == 1
open(p, 'w').write(s.replace(marker, impl + marker))
h = wt + 'include/dino8/kernel/brep.h'
t = open(h).read()
m2 = "  // Pipe: an exact rational circle of `radius`, centered on the rail's\n"
assert t.count(m2) == 1
open(h, 'w').write(t.replace(m2, open(sp + 's1s_decl.h').read() + m2))
print("ok")
