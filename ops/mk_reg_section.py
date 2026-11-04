T = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests/smoke.sh'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
lines = open(T).read().split('\n')
def rng(a, b):
    return lines[a - 1:b]
out = rng(1278, 1369) + rng(2231, 4247)
open(S + 'reg_section.sh', 'w').write('\n'.join(out) + '\n')
print(len(out))
