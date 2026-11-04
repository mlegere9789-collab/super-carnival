S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
sec = open(S + 'h2r_section.sh').read()

def rep(old, new):
    global sec
    assert sec.count(old) == 1, (sec.count(old), old[:70])
    sec = sec.replace(old, new)

# control renumbering (17,18,19 -> 18,19,20)
rep('h2r_sh "$H2R_E" 17 "$(h2r_vol "$H2R_E" 3)" 3 ', 'h2r_sh "$H2R_E" 18 "$(h2r_vol "$H2R_E" 3)" 3 ')
rep('h2r_sh "$H2R_E" 17 7983 3 ', 'h2r_sh "$H2R_E" 18 7983 3 ')
rep('h2r_sh "$H2R_E" 18 7820 3 "H2R_chamfer control', 'h2r_sh "$H2R_E" 19 7820 3 "H2R_chamfer control')
rep('h2r_sh "$H2R_E" 19 "$(h2r_vol "$H2R_E" 6)" 0.3 ', 'h2r_sh "$H2R_E" 20 "$(h2r_vol "$H2R_E" 6)" 0.3 ')
rep('#   13 EditHistory distance2=1 (990) 14 History Off fillet 15 ...after Move 16 rotated source: old result kept 17-19 fresh controls (7983, 7820, 980.6)\n# Bounding boxes: 1 fillet 2 moved +5 X 3 reopened source moved +5 X then +5 Y 4 chamfered box moved +7 X 5 result kept after the refused rotation',
    '#   13 EditHistory distance2=1 (990) 14 History Off fillet 15 ...after Move 16 source rotated 30 degrees: followed 17 source chamfered on the recorded edge: old result kept\n#   18-21 fresh controls (7983, 7820, 980.6, rotated 991.4)\n# Bounding boxes: 1 fillet 2 moved +5 X 3 reopened source moved +5 X then +5 Y 4 chamfered box moved +7 X 5 rotated source 6 fresh rotated control')

a = sec.index('h2r_has "$H2R_E" "no longer exists on the edited source')
b = sec.index('h2r_has "$H2R_E" "staged for an exact conic fillet')
new = '''h2r_has "$H2R_E" "FilletEdge: edge 1 re-found as edge 10 of the source (the solid was re-oriented: same position in its edge list, same dihedral angle and relative length)" "H2R_rotate: a source rotated 30 degrees about Z has no edge with the recorded direction/normals; the solid kept its topology, so the edge is re-found by its position in the edge list, dihedral angle and relative length, and the rebuild says so"
h2r_sh "$H2R_E" 16 991.4 0.3 "H2R_rotate: the rebuilt fillet on the rotated source has the same volume"
h2r_sb "$H2R_E" 5 "-1.83,-1.83,0,11.83,11.1,10" 0.05 "H2R_rotate: ...and the bounding box of a rotated, filleted box"
h2r_sb "$H2R_E" 6 "-1.83,-1.83,0,11.83,11.1,10" 0.05 "H2R_rotate control: the same fillet performed fresh on the rotated box has the same bounding box"
h2r_sh "$H2R_E" 21 991.4 0.3 "H2R_rotate control: ...and the same volume"
h2r_has "$H2R_E" "no longer exists on the edited source: no edge has that direction between faces with those normals, and the solid's own edge 10 no longer has the recorded dihedral angle and length" "H2R_refuse: the source was chamfered in place on the very edge the fillet was recorded on; the edge vanished and the reason is printed"
h2r_has "$H2R_E" "UpdateHistory: object 2 (FilletEdge) kept as it was: edge 1 of 1:" "H2R_refuse: UpdateHistory keeps the old result and names the edge"
h2r_sh "$H2R_E" 17 991.4 0.3 "H2R_refuse: the old result keeps its volume (not the chamfered source's 955)"
'''
sec = sec[:a] + new + sec[b:]
open(S + 'h2r_section.sh', 'w').write(sec)

# splice into smoke.sh
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests/smoke.sh'
s = open(p).read()
m = s.index('# ---------------------------------------------------------------------------\n# History / associative re-execution, round 2 (H2R_)')
e = s.rindex('exit $fail')
s = s[:m] + sec.rstrip('\n') + '\n\n' + s[e:]
open(p, 'w').write(s)
print('spliced')
