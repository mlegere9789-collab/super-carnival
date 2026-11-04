root = '/home/user/miniature-pancake/.claude/worktrees/agent-a34f41bb080e3eecc/dino8-app/tests/'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
L = open(root + 'smoke.sh').read().split('\n')
head = L[:128]
head = ['HERE="%s"' % root.rstrip('/') if h.startswith('HERE=') else h for h in head]
head.insert(1, "trap '' PIPE")
a = next(i for i, l in enumerate(L) if l.startswith('# Kernel primitives reached from the app commands'))
b = next(i for i, l in enumerate(L) if l.startswith('# SubD parity (app_subd_mesh)'))
open(S + 'harness_wiring.sh', 'w').write('\n'.join(head) + '\n' + '\n'.join(L[a:b]) + '\nexit $fail\n')
print(b - a)
