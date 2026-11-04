files = ['/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/ts2_section.sh',
         '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/tests/smoke.sh']
reps = [
 ('[ "${#TS2_TOSUBD[@]}" -eq 5 ] && [ "${#TS2_LIST[@]}" -eq 4 ]', '[ "${#TS2_TOSUBD[@]}" -eq 6 ] && [ "${#TS2_LIST[@]}" -eq 5 ]'),
 ('printed 5 ToSubD lines, 4 SubD List lines and 4 volumes', 'printed 6 ToSubD lines, 5 SubD List lines and 4 volumes'),
 ('# worst measured deviation per ToSubD line, in script order: cylinder, cone, TCone, big cylinder, torus',
  '# worst measured deviation per ToSubD line, in script order: cylinder, cone, TCone, big cylinder, torus, extruded circle'),
 ('ts2name=(cylinder cone TCone "big cylinder (radius 40)" torus)', 'ts2name=(cylinder cone TCone "big cylinder (radius 40)" torus "extruded circle solid")'),
 ('  for i in 0 1 2 3 4; do\n    if grep -q "(1 of 1', '  for i in 0 1 2 3 4 5; do\n    if grep -q "(1 of 1'),
 ('  for i in 0 1 2 3; do\n    if grep -q "analytic revolved-solid cage (', '  for i in 0 1 2 3 5; do\n    if grep -q "analytic revolved-solid cage ('),
 ('  for i in 0 1 2 3; do\n    read -r F E V C', '  for i in 0 1 2 3 4; do\n    read -r F E V C'),
 ('(expected 5 / 4 / 4)', '(expected 6 / 5 / 4)'),
]
for f in files:
    s = open(f).read()
    for a, b in reps:
        assert s.count(a) == 1, (f, a)
        s = s.replace(a, b)
    open(f, 'w').write(s)
print('ok')
