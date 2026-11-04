import sys
p = sys.argv[1] + '/src/parasolid_xt.cpp'
s = open(p).read()

helpers = r'''
// Closest-point helpers (the public OpenNURBS build has no GetClosestPoint for curves/surfaces).
bool CurveClosestParam(const ON_Curve& c, const ON_3dPoint& P, double& t_out) {
  const ON_Interval d = c.Domain();
  const int N = 400;
  int best = 0;
  double bd = 1e300;
  for (int i = 0; i <= N; ++i) {
    const double dd = c.PointAt(d.ParameterAt(static_cast<double>(i) / N)).DistanceTo(P);
    if (dd < bd) {
      bd = dd;
      best = i;
    }
  }
  double a = d.ParameterAt(std::max(0, best - 1) / static_cast<double>(N));
  double b = d.ParameterAt(std::min(N, best + 1) / static_cast<double>(N));
  const double g = 0.6180339887498949;
  double x1 = b - g * (b - a), x2 = a + g * (b - a);
  double f1 = c.PointAt(x1).DistanceTo(P), f2 = c.PointAt(x2).DistanceTo(P);
  for (int it = 0; it < 80; ++it) {
    if (f1 < f2) {
      b = x2;
      x2 = x1;
      f2 = f1;
      x1 = b - g * (b - a);
      f1 = c.PointAt(x1).DistanceTo(P);
    } else {
      a = x1;
      x1 = x2;
      f1 = f2;
      x2 = a + g * (b - a);
      f2 = c.PointAt(x2).DistanceTo(P);
    }
  }
  t_out = 0.5 * (a + b);
  if (best == 0) t_out = std::min(t_out, d.ParameterAt(1.0 / N));
  if (c.PointAt(d.Min()).DistanceTo(P) <= c.PointAt(t_out).DistanceTo(P)) t_out = d.Min();
  if (c.PointAt(d.Max()).DistanceTo(P) <= c.PointAt(t_out).DistanceTo(P)) t_out = d.Max();
  return true;
}

bool SurfClosestUV(const ON_Surface& S, const ON_3dPoint& P, double& u, double& v) {
  const ON_Interval du = S.Domain(0), dv = S.Domain(1);
  const int N = 32;
  double bd = 1e300;
  for (int i = 0; i <= N; ++i)
    for (int j = 0; j <= N; ++j) {
      const double uu = du.ParameterAt(static_cast<double>(i) / N), vv = dv.ParameterAt(static_cast<double>(j) / N);
      const double dd = S.PointAt(uu, vv).DistanceTo(P);
      if (dd < bd) {
        bd = dd;
        u = uu;
        v = vv;
      }
    }
  for (int it = 0; it < 80; ++it) {
    ON_3dPoint p;
    ON_3dVector su, sv;
    if (!S.Ev1Der(u, v, p, su, sv)) break;
    const ON_3dVector r = p - P;
    const double a = su * su, b = su * sv, c = sv * sv;
    const double g1 = su * r, g2 = sv * r;
    const double det = a * c - b * b;
    double d1 = 0, d2 = 0;
    if (std::fabs(det) > 1e-30) {
      d1 = -(c * g1 - b * g2) / det;
      d2 = -(a * g2 - b * g1) / det;
    } else {
      break;
    }
    double step = 1.0;
    const double r0 = r.Length();
    bool improved = false;
    for (int k = 0; k < 20; ++k) {
      const double nu = std::min(std::max(u + step * d1, du.Min()), du.Max());
      const double nv = std::min(std::max(v + step * d2, dv.Min()), dv.Max());
      if (S.PointAt(nu, nv).DistanceTo(P) <= r0) {
        improved = std::fabs(nu - u) + std::fabs(nv - v) > 1e-15;
        u = nu;
        v = nv;
        break;
      }
      step *= 0.5;
    }
    if (!improved) break;
  }
  return true;
}
'''
marker = '// ---------------------------------------------------------------------------\n// WRITER'
assert marker in s
s = s.replace(marker, helpers + '\n' + marker, 1)
s = s.replace('static_cast<const ON_Surface*>(s.ns.get())->GetClosestPoint(p, &u, &v);', 'SurfClosestUV(*s.ns, p, u, v);')
s = s.replace('static_cast<const ON_Curve*>(full.get())->GetClosestPoint(', 'CurveClosestParam(*full, ')
s = s.replace('CurveClosestParam(*full, p0, &t)', 'CurveClosestParam(*full, p0, t)')
s = s.replace('CurveClosestParam(*full, p0, &t0)', 'CurveClosestParam(*full, p0, t0)')
s = s.replace('CurveClosestParam(*full, p1, &t1)', 'CurveClosestParam(*full, p1, t1)')
open(p, 'w').write(s)
