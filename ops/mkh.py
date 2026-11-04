#!/usr/bin/env python3
# usage: mkh.py out.sh tests_dir a-b [c-d ...]   (line ranges of smoke.sh, 1-based inclusive; 'H' ranges of helper defs allowed)
import sys
out, tests = sys.argv[1], sys.argv[2]
L = open(tests + '/smoke.sh').read().split('\n')
head = '\n'.join(L[:128]).replace('HERE="$(cd "$(dirname "$0")" && pwd)"', 'HERE="%s"' % tests)
parts = [head]
for r in sys.argv[3:]:
    a, b = r.split('-')
    parts.append('\n'.join(L[int(a) - 1:int(b)]))
parts.append('exit $fail\n')
open(out, 'w').write('\n'.join(parts))
