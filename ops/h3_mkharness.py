T = '/home/user/miniature-pancake/.claude/worktrees/agent-a6793fdf3e148e078/dino8-app/tests'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
lines = open(T + '/smoke.sh').read().split('\n')
head = lines[:128]
head = [("HERE=\"" + T + "\"") if l.startswith('HERE=') else l for l in head]
head.insert(1, "trap '' PIPE")


def rng(a, b):
    return lines[a - 1:b]


mine_start = next(i for i, l in enumerate(lines) if l.startswith('# H3R_: construction history'))
mine = lines[mine_start - 1:len(lines)]
open(S + 'h3_harness_new.sh', 'w').write('\n'.join(head + mine) + '\n')
old = rng(6423, 6614) + ['']
old += rng(9418, 9708) + ['']
old += rng(10063, mine_start - 1) + ['', 'exit $fail', '']
# old 'exit' guard: the sections above may `exit 1` on failure of their own; fine.
open(S + 'h3_harness_old.sh', 'w').write('\n'.join(head + old) + '\n')
print(len(head), mine_start, len(lines))
