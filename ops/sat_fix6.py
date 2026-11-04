p = 'dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
a = '''  RoundTrip("app-style sphere (ON_BrepSphere, UNVERIFIED layout)", WrapOn(ON_BrepSphere(ON_Sphere(ON_3dPoint(1, 2, 3), 4.0))), 2e-3, true, true);
  g_mesh_measure = false;
'''
assert a in s
b = '''  g_mesh_measure = false;
  RoundTrip("app-style sphere (ON_BrepSphere, UNVERIFIED layout)", WrapOn(ON_BrepSphere(ON_Sphere(ON_3dPoint(1, 2, 3), 4.0))), 2e-3, true, true);
'''
s = s.replace(a, b)
open(p, 'w').write(s)
