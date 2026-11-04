import sys
p = sys.argv[1] + '/src/parasolid_xt.cpp'
s = open(p).read()

# 1. plane as bilinear NURBS
a = '''    auto ps = std::make_unique<ON_PlaneSurface>(ON_Plane(s.O, s.X, s.Y));
    if (!ps->SetExtents(0, ON_Interval(ulo, uhi), true) || !ps->SetExtents(1, ON_Interval(vlo, vhi), true)) return "could not set plane extents";
    out = std::move(ps);
    return "";'''
b = '''    auto ns = std::make_unique<ON_NurbsSurface>(3, false, 2, 2, 2, 2);
    const double us[2] = {ulo, uhi}, vs[2] = {vlo, vhi};
    for (int i = 0; i < 2; ++i)
      for (int j = 0; j < 2; ++j) ns->SetCV(i, j, s.O + s.X * us[i] + s.Y * vs[j]);
    ns->SetKnot(0, 0, ulo);
    ns->SetKnot(0, 1, uhi);
    ns->SetKnot(1, 0, vlo);
    ns->SetKnot(1, 1, vhi);
    if (!ns->IsValid()) return "could not build the planar NURBS patch";
    out = std::move(ns);
    return "";'''
assert a in s
s = s.replace(a, b)

# 2. try both transpositions
a = 'std::unique_ptr<ON_NurbsSurface> MakeRevNurbs(const SurfModel& s, ON_Curve* profile) {'
b = 'std::unique_ptr<ON_NurbsSurface> MakeRevNurbs(const SurfModel& s, ON_Curve* profile, bool transposed) {'
assert a in s
s = s.replace(a, b)
s = s.replace('  rs->m_bTransposed = false;\n  const ON_BoundingBox pb', '  rs->m_bTransposed = transposed;\n  const ON_BoundingBox pb')
a = '''  std::unique_ptr<ON_NurbsSurface> ns = MakeRevNurbs(t, profile);
  if (!ns) return "could not form the NURBS surface of revolution";
  // Self-check the parametrisation against the analytic one.
  const ON_Interval du = ns->Domain(0), dv = ns->Domain(1);
'''
b = '''  std::unique_ptr<ON_NurbsSurface> ns;
  std::string diag;
  for (int pass = 0; pass < 2 && !out; ++pass) {
  ns = MakeRevNurbs(t, profile->Duplicate(), pass == 1);
  if (!ns) return "could not form the NURBS surface of revolution";
  // Self-check the parametrisation against the analytic one.
  const ON_Interval du = ns->Domain(0), dv = ns->Domain(1);
'''
assert a in s
s = s.replace(a, b)
a = '''  if (!ok) return "internal: revolved NURBS parametrisation did not match the analytic one";
  out = std::move(ns);
  return "";
}'''
b = '''  if (!ok) {
    char buf[200];
    std::snprintf(buf, sizeof(buf), " [pass %d domain u[%g,%g] v[%g,%g]]", pass, du.Min(), du.Max(), dv.Min(), dv.Max());
    diag += buf;
    continue;
  }
  out = std::move(ns);
  }
  delete profile;
  if (!out) return "internal: revolved NURBS parametrisation did not match the analytic one" + diag;
  return "";
}'''
assert a in s
s = s.replace(a, b)
open(p, 'w').write(s)
