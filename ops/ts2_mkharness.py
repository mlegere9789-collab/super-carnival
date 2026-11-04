import sys
sp = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
wt = '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/tests'
lines = open(wt + '/smoke.sh').read().split('\n')
head = lines[:128]
out = []
for i, l in enumerate(head):
    if i == 0:
        out.append(l)
        out.append("trap '' PIPE")
        continue
    if l.startswith('HERE='):
        l = 'HERE="%s"' % wt
    out.append(l)
which = sys.argv[1]
sec = open(sp + which).read()
out.append(sec)
out.append('exit $fail')
open(sp + 'ts2_harness_%s.sh' % which.replace('.sh', ''), 'w').write('\n'.join(out) + '\n')
print('written')
