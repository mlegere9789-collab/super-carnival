p = '/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/tests/smoke.sh'
L = open(p).read().split('\n')
assert L[8898].startswith('sparcheck "512 feature edge(s) creased"')
assert L[8899].startswith('sparcheck "11894 faces')
assert L[8900].startswith('sparcheck "ToSubD: created 1 object(s) (0 of 1')
L[8898] = 'sparcheck "64 feature edge(s) creased" "ToSubD on a cylinder creases its 64 rim edges (two 32-segment circles) instead of rounding them off (before: 512 rim edges of the 256-segment mesher cage)"'
L[8899] = 'sparcheck "352 faces, 704 edges, 354 vertices, 64 creases" "the cylinder SubD is the analytic 352-face cage (32 x 5 wall + two 64-face O-grid caps, Euler 354 - 704 + 352 = 2) with the 64 rim creases (before: 11894 faces, 512 creases)"'
L[8900] = 'sparcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\\.000[0-9]*); analytic revolved-solid cage (32 segments around x 5 along the wall" "the cylinder (trimmed planar caps the grid tessellation cannot weld) is now built as an analytic wall + cap cage and VERIFIED, deviation measured against the exact surface (before: 0 of 1 verified, 0.02x)"'
open(p, 'w').write('\n'.join(L))
print('ok')
