sp = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
wt = '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/tests'
lines = open(wt + '/smoke.sh').read().split('\n')
out = []
for i, l in enumerate(lines[:128]):
    if i == 0:
        out.append(l)
        out.append("trap '' PIPE")
        continue
    if l.startswith('HERE='):
        l = 'HERE="%s"' % wt
    out.append(l)
for a, b in [(1528, 1663), (8879, 8936), (10021, 10061)]:
    out.extend(lines[a - 1:b])
    out.append('')
out.append('exit $fail')
open(sp + 'ts2_harness_existing.sh', 'w').write('\n'.join(out) + '\n')
print('written')
