import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad'
T = '/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e/dino8-app/tests'
lines = open(T + '/smoke.sh').read().split('\n')
out = []
for l in lines[:128]:
    if l.startswith('HERE='):
        l = 'HERE="%s"' % T
    out.append(l)
for rng in sys.argv[2:]:
    a, b = rng.split('-')
    out.extend(lines[int(a) - 1:int(b)])
open(S + '/' + sys.argv[1], 'w').write('\n'.join(out) + '\nexit $fail\n')
