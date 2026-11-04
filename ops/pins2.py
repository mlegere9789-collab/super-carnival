p='/home/user/miniature-pancake/.claude/worktrees/agent-a9cb50949c933224e/dino8-app/tests/smoke.sh'
L=open(p).read().split('\n')
for n in (8977, 8979, 8981):
    assert 'sewn into a closed solid"' in L[n-1], n
    L[n-1] = L[n-1].replace('sewn into a closed solid"', 'sealed: valid B-rep with real inner loops"', 1)
open(p,'w').write('\n'.join(L))
