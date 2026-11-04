import sys
p = sys.argv[1]
s = open(p).read()
a = 'RoundTripBoolean("L-shaped union", uni, 12.0 + 4.0, 0.0 + 0.0 + 0.0);'
assert a in s
s = s.replace(a, '// Volume 16 + 16 - 8 = 24; area 2 * 12 (L footprint) + 16 * 2 (perimeter x height) = 56.\n  RoundTripBoolean("L-shaped union", uni, 24.0, 56.0);')
b = "// Blind pocket 2x2x3 from the top face: volume 64 - 12, area 96 + 4 * 3 * 2 (walls) .. top face loses 4, floor adds 4,\n  // walls add 4 * (2 * 3) = 24, so area = 96 - 4 + 4 + 24 = 120."
assert b in s
s = s.replace(b, "// Blind pocket 2x2x3 from the top face: volume 64 - 12 = 52; the top loses 4, the floor adds 4 and the four walls add\n  // 4 * (2 * 3) = 24, so area = 96 + 24 = 120.")
open(p, 'w').write(s)
