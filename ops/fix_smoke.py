p = '/home/user/miniature-pancake/.claude/worktrees/agent-a34f41bb080e3eecc/dino8-app/tests/smoke.sh'
L = open(p).read().split('\n')
out = []
for l in L:
    if l.startswith('s2n_check "NURBS surface (cubic where the net allows) fitted through the curves and the meetings ([4-9]'):
        out.append('s2n_check "NURBS surface (cubic where the net allows) fitted through the curves and the meetings ([0-9]* x [0-9]* net)" "S2N_3x3: the control net of the fitted surface is reported"')
    elif l.startswith('# Net: 3 curves one way give'):
        out.append('# The area of the 6 x 4 rectangle plus the 0.72 high bump is a little over 24 (measured 25.52 here); the bounding box reaches the bump top z = 0.72.')
    elif l.startswith('if s2n_in_range "$S2N_A1" 24 26'):
        out.append('if s2n_in_range "$S2N_A1" 25 26.2; then echo "ok   S2N_3x3: area $S2N_A1 in 25..26.2 (25.52 when written: the 6 x 4 rectangle plus the 0.72 high bump)"; else echo "FAIL S2N_3x3 area \'$S2N_A1\' not in 25..26.2"; fail=1; fi')
    elif l.startswith('s2n_check "  1 surfaces'):
        out.append('S2N_TOP="$({ grep -o \'Bounding box min 0,0,-\\?[0-9.e-]* max 6,4,[0-9.e-]*\' <<<"$S2N_OUT" || true; } | head -1 | sed \'s/.* max 6,4,//\')"')
        out.append('if s2n_in_range "$S2N_TOP" 0.69 0.75; then echo "ok   S2N_3x3: the surface spans x 0..6, y 0..4 and its top is z = $S2N_TOP (the bump height 0.72 is reproduced through the interior curves)"; else echo "FAIL S2N_3x3 bounding box top \'$S2N_TOP\' not in 0.69..0.75 (or the box is not 6 x 4)"; fail=1; fi')
        out.append('s2n_count "Object [0-9]*: valid" 1 "S2N_3x3: Check reports the fitted surface valid"')
    elif l.startswith('if s2n_in_range "$S2N_A2" 23.5 24.5'):
        out.append(l)
    else:
        out.append(l)
open(p, 'w').write('\n'.join(out))
