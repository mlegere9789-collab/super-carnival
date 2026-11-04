T = '/home/user/miniature-pancake/.claude/worktrees/agent-adf410ea55c17e4d8/dino8-app/tests'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
lines = open(T + '/smoke.sh').read().split('\n')
head = lines[:128]
head = [("HERE=\"" + T + "\"") if l.startswith('HERE=') else l for l in head]
head.insert(1, "trap '' PIPE")

def start_of(prefix):
    i = next(i for i, l in enumerate(lines) if l.startswith(prefix))
    # include the dashed line above the heading, if any
    return i - 1 if lines[i - 1].startswith('# ----') else i

def section(prefix, next_prefix):
    a = start_of(prefix)
    b = start_of(next_prefix)
    return lines[a:b]

reg = []
a = next(i for i, l in enumerate(lines) if l.startswith('H2R_DIR='))
b = next(i for i, l in enumerate(lines) if l.startswith('h2r_count()'))
reg += lines[a:b + 1] + ['']
reg += section('# S1S_:', '# B2S_:')
h3 = start_of('# H3R_:')
reg += lines[h3:10898]
s2 = start_of('# S2C_:')
reg += lines[s2:11062]
sc = start_of('# SCP_:')
reg += lines[sc:11561]
sps = lines[start_of('# SPS_:'):]
sps = [l for l in sps]
while sps and sps[-1] == '':
    sps.pop()
# the file's last line is `exit $fail`; the sections above are cut before it
assert sps[-1] == 'exit $fail', sps[-1]
open(S + 'sps_harness_reg.sh', 'w').write('\n'.join(head + reg + ['', 'exit $fail', '']) + '\n')
open(S + 'sps_harness_sps.sh', 'w').write('\n'.join(head + sps) + '\n')
print(len(head), len(reg), len(sps))
