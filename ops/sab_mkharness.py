S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad'
T = '/home/user/miniature-pancake/.claude/worktrees/agent-a6f744a12b0e7f9d5/dino8-app/tests'
lines = open(T + '/smoke.sh').read().split('\n')
out = []
for l in lines[:128]:
    if l.startswith('HERE='):
        l = 'HERE="%s"' % T
    out.append(l)
a = next(i for i, l in enumerate(lines) if l.startswith('# SATF: ACIS SAT (.sat text)'))
b = next(i for i, l in enumerate(lines) if l.startswith('# SABF: ACIS SAB'))
c = max(i for i, l in enumerate(lines) if l.strip() == 'exit $fail')
e = next(i for i in range(a + 1, len(lines)) if lines[i].startswith('# ------'))
out.extend(lines[a:e])
out.extend(lines[b:c])
open(S + '/sab_harness.sh', 'w').write('\n'.join(out) + '\nexit $fail\n')
print(a + 1, b + 1, c + 1)
