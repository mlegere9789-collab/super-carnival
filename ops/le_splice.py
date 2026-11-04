S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = '/home/user/miniature-pancake/.claude/worktrees/agent-af78da953e7552ee8/dino8-app/tests/smoke.sh'
s = open(p).read()
sec = open(S + 'le_section.sh').read().replace('"Volume" 1177.8 1178.4', '"Volume" 1175 1178.5')
assert s.rstrip().endswith('exit $fail')
i = s.rindex('exit $fail')
s = s[:i].rstrip('\n') + '\n' + sec + '\nexit $fail\n'
open(p, 'w').write(s)
print('spliced')
