T = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests/smoke.sh'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
lines = open(T).read().split('\n')
def rng(a, b):  # 1-based inclusive
    return lines[a - 1:b]
out = []
out += rng(6423, 6887)
out += rng(9415, 9533)
out += rng(10060, 10181)
open(S + 'hist_section.sh', 'w').write('\n'.join(out) + '\n')
print(len(out))
