import sys
p = sys.argv[1]
inc = open(sys.argv[2]).read()
s = open(p).read()
marker = "}  // namespace surface_fillet_tests\n\nint main() {"
assert s.count(marker) == 1
s = s.replace(marker, "}  // namespace surface_fillet_tests\n\n" + inc + "\nint main() {", 1)
open(p, "w").write(s)
