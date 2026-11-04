import sys
p = '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/src/commands/cmd_solids.cpp'
ins = open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/ts2_insert.cpp').read()
s = open(p).read()
marker = "// Joins coincident naked edges of `b` like JoinNakedEdges"
assert s.count(marker) == 1
s = s.replace(marker, ins + marker)
open(p, 'w').write(s)
print("ok")
