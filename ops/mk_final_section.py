S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests/smoke.sh'
s = open(p).read()
m = s.index('# ---------------------------------------------------------------------------\n# History / associative re-execution, round 2 (H2R_)')
e = s.rindex('exit $fail')
open(S + 'final_section.sh', 'w').write(s[m:e])
print(len(s[m:e].split('\n')), 'lines; tail:', s[e - 60:].replace('\n', '|'))
