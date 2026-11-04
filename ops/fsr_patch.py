import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a102f7e751a3e860d/dino8-app/tests/smoke.sh'
s = open(p).read()
assert s.rstrip().endswith('exit $fail')
sec = open(S + 'fsr_section.txt').read()
idx = s.rindex('exit $fail')
s = s[:idx] + sec + s[idx:]
a = 'new results of 38 construction commands (BlendSrf'
assert a in s
s = s.replace(a, 'new results of 39 construction commands (BlendSrf')
b = 'the registry now has 38 names - 23 before'
assert b in s
s = s.replace(b, 'the registry now has 39 names (the 38 listed plus FilletSurfaces, see FSR_) - 23 before')
open(p, 'w').write(s)
print('patched')
