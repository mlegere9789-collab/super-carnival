#!/usr/bin/env python3
# usage: mkharness.py <smoke.sh> <start-regex-prefix> <end-prefix> <out> [helpers-file]
import sys, os
smoke, start, end, out = sys.argv[1:5]
helpers = open(sys.argv[5]).read() if len(sys.argv) > 5 else ""
lines = open(smoke).read().split("\n")
a = next(i for i, l in enumerate(lines) if l.startswith(start))
b = next(i for i, l in enumerate(lines) if i > a and l.startswith(end))
here = os.path.dirname(os.path.abspath(smoke))
body = "\n".join(lines[a:b])
hdr = f'''set -euo pipefail
echo() {{ builtin echo "$@" 2>/dev/null || true; }}
HERE={here}
BIN="$1"; fail=0
TMP="$(mktemp -d)"; TMPW="$TMP"
trap 'rm -rf "$TMP"' EXIT
near() {{ echo "     expected: $2"; }}
{helpers}
'''
open(out, "w").write(hdr + body + "\nexit $fail\n")
print("harness lines", b - a)
