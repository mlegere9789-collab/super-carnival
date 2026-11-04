p='/home/user/miniature-pancake/.claude/worktrees/agent-a9cb50949c933224e/dino8-app/tests/smoke.sh'
L=open(p).read().split('\n')
def rep(n, old, new):
    assert old in L[n-1], (n, old)
    L[n-1] = L[n-1].replace(old, new, 1)
rep(3898, ', sewn into a closed solid (tolerance 0.02449), volume 1125 (mesh cross-check 1125)',
    ', sealed: valid B-rep with real inner loops, exact volume 1125 (kernel divergence theorem), 2 keyhole(s) opened (sewn at tolerance 0.02449), volume 1125 (mesh cross-check 1125)')
rep(3899, ', sewn into a closed solid (tolerance 0.01855), volume 874.8 (mesh cross-check 874.9)',
    ', sealed: valid B-rep with real inner loops, exact volume 874.5 (kernel divergence theorem), 2 keyhole(s) opened (sewn at tolerance 0.01855), volume 874.8 (mesh cross-check 874.9)')
for n in (8967, 8973, 8975, 8983, 8988, 8995, 10446, 10461, 10469):
    rep(n, 'sewn into a closed solid"', 'sealed: valid B-rep with real inner loops"')
open(p,'w').write('\n'.join(L))
