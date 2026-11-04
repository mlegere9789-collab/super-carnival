p = '/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e/dino8-app/tests/smoke.sh'
s = open(p).read()
sec = open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/satf_section.txt').read()
t = s.rstrip()
assert t.endswith("\nexit $fail")
i = t.rfind("\nexit $fail")
s = t[:i].rstrip("\n") + "\n" + sec + "\nexit $fail\n"
open(p, 'w').write(s)
