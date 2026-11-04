S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests/smoke.sh'
s = open(p).read()
sec = open(S + 'h2r_section.sh').read()
assert s.rstrip().endswith("exit $fail")
idx = s.rindex("exit $fail")
s = s[:idx] + sec.rstrip("\n") + "\n\n" + s[idx:]
old = 'hcheck "History recording: on - new results of 23 construction commands (Boolean2Objects/BooleanDifference/BooleanIntersection/BooleanUnion/Extrude/"'
assert old in s
new = 'hcheck "History recording: on - new results of 29 construction commands (BlendSrf/Boolean2Objects/BooleanDifference/BooleanIntersection/BooleanUnion/Cap/ChamferEdge/Extrude/"'
s = s.replace(old, new, 1)
old2 = "the registry has 23 names, e.g. Shell,"
if old2 in s:
    s = s.replace(old2, "the registry now has 29 names - 23 before the H2R_ additions BlendSrf, Cap, ChamferEdge, FilletEdge, Project and Pull - e.g. Shell,", 1)
open(p, 'w').write(s)
print('ok', old2 in open(p).read())
