exec(open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/ts2_edit4.py').read())
for f in files:
    s = open(f).read()
    assert s.count('the ${ts2name[$i]} cage') == 4, s.count('the ${ts2name[$i]} cage')
    s = s.replace('the ${ts2name[$i]} cage', 'the ${ts2lname[$i]} cage')
    a = '  ts2fe() {'
    assert s.count(a) == 1
    s = s.replace(a, '  ts2lname=(cylinder cone TCone "big cylinder (radius 40)" "extruded circle solid")\n' + a)
    open(f, 'w').write(s)
t = '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/tests/tosubd2_script.txt'
s = open(t).read()
s += """# An extruded circle (ExtrudeCrv, capped) is the same wall + two caps shape: same analytic cage.
SelAll
Hide
Circle 500,0,0 4
SelLast
ExtrudeCrv
10
SelLast
ToSubD
SelLast
List
"""
open(t, 'w').write(s)
print('ok2')
