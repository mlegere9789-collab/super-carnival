import os
os.chdir('/home/user/miniature-pancake/.claude/worktrees/agent-ab6dd2aa413bb4a90/dino8-app')
S='/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
s=open('tests/smoke.sh').read()
body=open(S+'mkr_section.sh').read()
i=s.rstrip().rfind("exit $fail")
assert s[i:].strip()=="exit $fail"
s=s[:i].rstrip('\n')+"\n"+body
open('tests/smoke.sh','w').write(s)
