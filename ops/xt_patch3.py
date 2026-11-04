import sys
p = sys.argv[1] + '/src/parasolid_xt.cpp'
s = open(p).read()

# --- RevMap + mapping helpers inserted before BuildSurface
mark = '// Builds the ON surface for `s`, u-rotated by `u0`'
assert mark in s
revmap = r'''// Maps analytic coordinates (angle', b) of a revolved face to the parameters of its NURBS surface of revolution
// (a NURBS circle is not angle-parametrised, so the two differ). b is z (cylinder/cone), latitude (sphere) or the
// minor-circle angle measured from v0 (torus).
struct RevMap {
  bool valid = false;
  int type = 0;
  ON_3dPoint O;
  ON_3dVector X, Y, Z;
  double r = 0, R2 = 0, v0 = 0;
};

double RevAngle(const RevMap& M, const ON_3dPoint& p) {
  const ON_3dVector w = p - M.O;
  double a = std::atan2(w * M.Y, w * M.X);
  if (a < 0) a += kTwoPi;
  return a;
}

double RevB(const RevMap& M, const ON_3dPoint& p) {
  const ON_3dVector w = p - M.O;
  switch (M.type) {
    case kCylinder:
    case kCone:
      return w * M.Z;
    case kSphere:
      return std::atan2(w * M.Z, std::hypot(w * M.X, w * M.Y));
    default: {
      double a = std::atan2(w * M.Z, std::hypot(w * M.X, w * M.Y) - M.r) - M.v0;
      a = std::fmod(a, kTwoPi);
      if (a < 0) a += kTwoPi;
      return a;
    }
  }
}

ON_2dPoint RevToParam(const ON_NurbsSurface& S, const RevMap& M, double a, double b) {
  const ON_Interval du = S.Domain(0), dv = S.Domain(1);
  const double vref = dv.ParameterAt(0.5), uref = du.ParameterAt(0.5);
  double u;
  if (a >= kTwoPi - 1e-12) {
    u = du.Max();
  } else if (a <= 1e-12) {
    u = du.Min();
  } else {
    double lo = du.Min(), hi = du.Max();
    for (int i = 0; i < 70; ++i) {
      const double mid = 0.5 * (lo + hi);
      if (RevAngle(M, S.PointAt(mid, vref)) < a)
        lo = mid;
      else
        hi = mid;
    }
    u = 0.5 * (lo + hi);
  }
  double lo = dv.Min(), hi = dv.Max();
  const bool wraps = M.type == kTorus;
  if (wraps && b >= kTwoPi - 1e-12) {
    return ON_2dPoint(u, dv.Max());
  }
  if (wraps && b <= 1e-12) {
    return ON_2dPoint(u, dv.Min());
  }
  for (int i = 0; i < 70; ++i) {
    const double mid = 0.5 * (lo + hi);
    if (RevB(M, S.PointAt(uref, mid)) < b)
      lo = mid;
    else
      hi = mid;
  }
  return ON_2dPoint(u, 0.5 * (lo + hi));
}

'''
s = s.replace(mark, revmap + mark, 1)

# --- signature
a = 'std::string BuildSurface(SurfModel& s, double u0, double v0, double ulo, double uhi, double vlo, double vhi, std::unique_ptr<ON_Surface>& out) {'
b = 'std::string BuildSurface(SurfModel& s, double u0, double v0, double ulo, double uhi, double vlo, double vhi, std::unique_ptr<ON_Surface>& out, RevMap* rev = nullptr) {'
assert a in s
s = s.replace(a, b)

# --- tail
i0 = s.index('  std::unique_ptr<ON_NurbsSurface> ns;\n  std::string diag;')
i1 = s.index('struct Elem {')
tail = r'''  std::unique_ptr<ON_NurbsSurface> ns = MakeRevNurbs(t, profile, false);  // takes ownership of `profile`
  if (!ns) return "could not form the NURBS surface of revolution";
  RevMap M;
  M.valid = true;
  M.type = s.type;
  M.O = t.O;
  M.X = t.X;
  M.Y = t.Y;
  M.Z = t.Z;
  M.r = s.r;
  M.R2 = s.R2;
  M.v0 = v0;
  // Self-check: the mapped analytic coordinates must land on the analytic point.
  auto expect = [&](double a, double b) {
    if (s.type == kCylinder || s.type == kCone) {
      const double rr = s.r + b * (s.type == kCone ? s.sinh / s.cosh : 0.0);
      return t.O + (std::cos(a) * t.X + std::sin(a) * t.Y) * rr + t.Z * b;
    }
    if (s.type == kSphere) return t.O + (std::cos(a) * t.X + std::sin(a) * t.Y) * (s.r * std::cos(b)) + t.Z * (s.r * std::sin(b));
    const double bb = b + v0;
    return t.O + (std::cos(a) * t.X + std::sin(a) * t.Y) * (s.r + s.R2 * std::cos(bb)) + t.Z * (s.R2 * std::sin(bb));
  };
  const double bl = (s.type == kCylinder || s.type == kCone) ? vlo : (s.type == kSphere ? -0.5 * kPi : 0.0);
  const double bh = (s.type == kCylinder || s.type == kCone) ? vhi : (s.type == kSphere ? 0.5 * kPi : kTwoPi);
  for (double fa : {0.13, 0.5, 0.87})
    for (double fb : {0.21, 0.5, 0.77}) {
      const double a = fa * kTwoPi, b = bl + fb * (bh - bl);
      const ON_2dPoint q = RevToParam(*ns, M, a, b);
      if (ns->PointAt(q.x, q.y).DistanceTo(expect(a, b)) > 1e-7 * std::max(1.0, s.r))
        return "internal: revolved NURBS parametrisation could not be mapped to the analytic one";
    }
  if (rev) *rev = M;
  out = std::move(ns);
  return "";
}

'''
s = s[:i0] + tail + s[i1:]

# MakeRevNurbs signature: back to 2 args (transposed fixed false), taking ownership
s = s.replace('std::unique_ptr<ON_NurbsSurface> MakeRevNurbs(const SurfModel& s, ON_Curve* profile, bool transposed) {', 'std::unique_ptr<ON_NurbsSurface> MakeRevNurbs(const SurfModel& s, ON_Curve* profile, bool transposed) {')

# --- BuildFace: use RevMap
a = '''    const std::string e = BuildSurface(sm, u0, v0, ulo, uhi, vlo, vhi, srf);
    if (!e.empty()) return fd + e;
  }'''
b = '''    const std::string e = BuildSurface(sm, u0, v0, ulo, uhi, vlo, vhi, srf, &revmap);
    if (!e.empty()) return fd + e;
  }'''
assert a in s
s = s.replace(a, b)
a = '''  std::unique_ptr<ON_Surface> srf;
  {
    const double ulo = umin - um, uhi = umax + um;'''
b = '''  std::unique_ptr<ON_Surface> srf;
  RevMap revmap;
  {
    const double ulo = umin - um, uhi = umax + um;'''
assert a in s
s = s.replace(a, b)

# shift step: add mapping
a = '''        if (shiftu) q.x -= u0;
        if (shiftv) q.y -= v0;
      }'''
b = '''        if (shiftu) q.x -= u0;
        if (shiftv) q.y -= v0;
        if (revmap.valid) {
          const ON_2dPoint m2 = RevToParam(*ON_NurbsSurface::Cast(srf.get()), revmap, q.x, q.y);
          q = m2;
        }
      }'''
assert a in s
s = s.replace(a, b)
open(p, 'w').write(s)
