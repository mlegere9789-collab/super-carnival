import sys, re
# usage: hl_splice.py <test_basic.cpp> <tests.cpp> <namespace>
path, src, ns = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
t = open(src).read()
names = re.findall(r'^void (Test\w+)\(\)', t, re.M)
if ('namespace ' + ns + ' {') in s:
    # replace the existing block (re-splice)
    a = s.index('// HL-BEGIN ' + ns)
    b = s.index('// HL-END ' + ns)
    b = s.index('\n', b) + 1
    s = s[:a] + s[b:]
    s = re.sub(r'  // HL-REG-BEGIN ' + ns + r'.*?// HL-REG-END ' + ns + r'\n', '', s, flags=re.S)
block = '// HL-BEGIN ' + ns + '\n' + t + '\n// HL-END ' + ns + '\n'
i = s.index('int main() {')
s = s[:i] + block + '\n' + s[i:]
reg = '  // HL-REG-BEGIN ' + ns + '\n' + ''.join('  RunTest("%s::%s", %s::%s);\n' % (ns, n, ns, n) for n in names) + '  // HL-REG-END ' + ns + '\n'
j = s.index('  RunTest("ON::End", ON::End);')
s = s[:j] + reg + s[j:]
open(path, 'w').write(s)
print(names)
