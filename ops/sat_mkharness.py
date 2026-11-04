import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad'
T = '/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e/dino8-app/tests'
lines = open(T + '/smoke.sh').read().split('\n')
head = lines[:128]
out = []
for l in head:
    if l.startswith('HERE='):
        l = 'HERE="%s"' % T
    out.append(l)
sec = open(S + '/satf_section.txt').read()
open(S + '/satf_harness.sh', 'w').write('\n'.join(out) + '\n' + sec + '\nexit $fail\n')
