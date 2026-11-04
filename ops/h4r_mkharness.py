import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
WT = '/home/user/miniature-pancake/.claude/worktrees/agent-a92541384807f36f6/'
L = open(WT + 'dino8-app/tests/smoke.sh').read().split('\n')


def find(prefix, after=0):
    for i in range(after, len(L)):
        if L[i].startswith(prefix):
            return i
    raise SystemExit('missing ' + prefix)


head = L[:128]
for i, l in enumerate(head):
    if l.startswith('HERE='):
        head[i] = 'HERE="/home/user/miniature-pancake/dino8-app/tests"'
# 1-based line numbers from the section survey -> 0-based slices
parts = {
    'hist_a': (6423 - 1, 6617 - 1),
    'hist_b': (6866 - 1, 6911 - 1),
    'hist_c': (9420 - 1, 9559 - 1),
    'hps': (10064 - 1, 10186 - 1),
    'h2r': (10462 - 1, 10734 - 1),
    'h3r': (10734 - 1, 10879 - 1),
}
which = sys.argv[1].split(',')
out = list(head)
if 'h4r' in which and 'h2r' not in which:
    a = find('h2r_ok()'); b = find('h2r_countre()')
    out += L[a:b + 1]
for k in which:
    if k == 'h4r':
        a = find('H4R_DIR='); b = len(L) - 1
        while L[b] != 'exit $fail':
            b -= 1
        out += L[a:b]
    else:
        a, b = parts[k]
        out += L[a:b]
out.append('exit $fail')
open(S + 'h4r_harness_' + sys.argv[2] + '.sh', 'w').write('\n'.join(out) + '\n')
