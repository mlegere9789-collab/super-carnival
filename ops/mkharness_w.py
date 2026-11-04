#!/usr/bin/env python3
# usage: mkharness_w.py <out.sh> <start> <end> [<start> <end>]...  (1-based inclusive line ranges of smoke.sh, concatenated after the 128-line header)
import sys
tests = '/home/user/miniature-pancake/.claude/worktrees/agent-a0c10ee7b8bb9e4e5/dino8-app/tests'
L = open(tests + '/smoke.sh').read().split('\n')
out = L[:128]
for i, l in enumerate(out):
    if l.startswith('HERE='):
        out[i] = 'HERE=' + tests
        break
a = list(map(int, sys.argv[2:]))
for i in range(0, len(a), 2):
    out += L[a[i] - 1:a[i + 1]]
open(sys.argv[1], 'w').write('\n'.join(out) + '\nexit $fail\n')
