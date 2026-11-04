p = 'dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
anchor = "// Every proper prefix of a valid file must be refused (never crash, never\n// yield a body): the End-of-ACIS-data trailer is mandatory.\nvoid TestAcisSatTruncationSweepRefusesEveryPrefix() {"
assert s.count(anchor) == 1
new = '''// The primitives the application's Box/Sphere/Cylinder commands build are raw
// OpenNURBS breps (ON_BrepBox / ON_BrepSphere / ON_BrepCylinder wrapped in a
// Brep), not the kernel's own Brep::BoxWelded / Brep::Sphere factories used by
// the round trips above; the Import/Export/Open/SaveAs .sat paths see exactly
// these, so they get their own round trips (box with documented layouts only,
// the others with the UNVERIFIED opt-in the app applies and discloses).
Brep WrapOn(ON_Brep* b) {
  Brep k;
  k.raw() = *b;
  delete b;
  return k;
}

void TestAcisSatRoundTripAppStylePrimitives() {
  ON_3dPoint corners[8];
  for (int k = 0; k < 2; ++k)
    for (int j = 0; j < 2; ++j)
      for (int i = 0; i < 2; ++i) corners[k * 4 + j * 2 + i] = ON_3dPoint(i ? 20.0 : 0.0, j ? 20.0 : 0.0, k ? 10.0 : 0.0);
  // ON_BrepBox's corner order is bottom (counter-clockwise) then top.
  ON_3dPoint box_corners[8] = {corners[0], corners[1], corners[3], corners[2], corners[4], corners[5], corners[7], corners[6]};
  RoundTrip("app-style box (ON_BrepBox)", WrapOn(ON_BrepBox(box_corners)), 1e-9, false, false);
  g_mesh_measure = true;
  ON_Cylinder cyl(ON_Circle(ON_Plane(ON_3dPoint(0, 0, 0), ON_3dVector(0, 0, 1)), 5.0), 10.0);
  RoundTrip("app-style cylinder (ON_BrepCylinder, UNVERIFIED layout)", WrapOn(ON_BrepCylinder(cyl, true, true)), 2e-3, true, true);
  RoundTrip("app-style sphere (ON_BrepSphere, UNVERIFIED layout)", WrapOn(ON_BrepSphere(ON_Sphere(ON_3dPoint(1, 2, 3), 4.0))), 2e-3, true, true);
  g_mesh_measure = false;
}

'''
s = s.replace(anchor, new + anchor)
s = s.replace('  RunTest("acis_sat_tests::TestAcisSatRoundTripBooleanPocketAndHole", acis_sat_tests::TestAcisSatRoundTripBooleanPocketAndHole);\n', '  RunTest("acis_sat_tests::TestAcisSatRoundTripBooleanPocketAndHole", acis_sat_tests::TestAcisSatRoundTripBooleanPocketAndHole);\n  RunTest("acis_sat_tests::TestAcisSatRoundTripAppStylePrimitives", acis_sat_tests::TestAcisSatRoundTripAppStylePrimitives);\n')
open(p, 'w').write(s)
