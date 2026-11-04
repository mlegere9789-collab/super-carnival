p = '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/tests/smoke.sh'
s = open(p).read()
sec = open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/ts2_section.sh').read()
assert s.rstrip().endswith('exit $fail')
idx = s.rstrip().rfind('exit $fail')
s = s[:idx].rstrip('\n') + '\n' + sec + '\nexit $fail\n'
open(p, 'w').write(s)
print('ok')
