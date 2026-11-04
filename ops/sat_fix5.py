p = 'dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
a = s.index("  ON_3dPoint corners[8];\n  for (int k = 0; k < 2; ++k)")
b = s.index('  RoundTrip("app-style box (ON_BrepBox)"')
s = s[:a] + '''  // Same corner order as the app's Box command: bottom face counter-clockwise, then the top face above it.
  ON_3dPoint box_corners[8] = {ON_3dPoint(0, 0, 0),  ON_3dPoint(20, 0, 0),  ON_3dPoint(20, 20, 0),  ON_3dPoint(0, 20, 0),
                               ON_3dPoint(0, 0, 10), ON_3dPoint(20, 0, 10), ON_3dPoint(20, 20, 10), ON_3dPoint(0, 20, 10)};
''' + s[b:]
open(p, 'w').write(s)
