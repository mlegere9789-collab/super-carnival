import sys
src = open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/pe_viewer_patch.py').read()
lines = src.split('\n')
body = '\n'.join(lines[3:])           # drop path/open lines
body = body.replace("open(p, 'w').write(s)", "pass").replace("print('patched')", "pass")
html = open(sys.argv[1]).read()
# the C++ comment replacement (first rep) is not in the HTML: make rep tolerant for that one only
ns = {'s': html}
code = body.replace("def rep(old, new):\n    global s\n    assert s.count(old) == 1, old\n    s = s.replace(old, new)",
                    "def rep(old, new):\n    global s\n    if old.startswith('// Mouse-drag'):\n        return\n    assert s.count(old) == 1, old\n    s = s.replace(old, new)")
exec(code, ns)
open(sys.argv[2], 'w').write(ns['s'])
print('fixture patched')
