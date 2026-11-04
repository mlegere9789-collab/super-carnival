#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include "dino8/kernel/brep.h"
#include "dino8/kernel/curve.h"
#include "dino8/kernel/surface.h"
#include "opennurbs.h"
namespace {
int g_failures = 0;
void Check(bool c, const char* w) { if (!c) { std::fprintf(stderr, "FAILED: %s\n", w); ++g_failures; } else std::printf("ok: %s\n", w); }
}
// ---------------------------------------------------------------------------
// surfops_tolerance_tests: RemoveMultiKnots (curve + surface), FitToTolerance
// (FitSrf) and Brep::ShrinkSurfaces (ShrinkTrimmedSrf) with tolerance
// contracts. Every deviation here is measured by this file's OWN dense
// sampling loops (not by the kernel's MaxSampledDeviationFrom / report
// fields) so the kernel's stated bound is checked by an independent oracle.
// ---------------------------------------------------------------------------
namespace surfops_tolerance_tests {

using dino8::kernel::Brep;
using dino8::kernel::NurbsCurve;
using dino8::kernel::NurbsSurface;
using dino8::kernel::Point2d;
using dino8::kernel::Point3d;
using dino8::kernel::Result;

NurbsCurve WavyCubic(int n) {
  std::vector<Point3d> pts;
  for (int i = 0; i < n; ++i) pts.push_back(Point3d(i * 1.0, std::sin(0.9 * i) * 1.3, std::cos(0.5 * i) * 0.7));
  return NurbsCurve::FromControlPoints(pts, 3);
}

double CurveDev(const NurbsCurve& a, const NurbsCurve& b, int samples = 4001) {
  const auto d = a.Domain();
  double worst = 0.0;
  for (int i = 0; i <= samples; ++i) {
    const double t = d.min + (d.max - d.min) * i / samples;
    worst = std::max(worst, a.PointAt(t).DistanceTo(b.PointAt(t)));
  }
  return worst;
}

// Number of distinct interior knot values whose multiplicity is >= 2.
int InteriorMultipleKnots(const NurbsCurve& c) {
  const auto d = c.Domain();
  int n = 0;
  for (int k = 0; k + 1 < c.KnotCount(); ++k) {
    const double u = c.KnotAt(k);
    if (u > d.min && u < d.max && c.KnotAt(k + 1) == u) {
      ++n;
      while (k + 1 < c.KnotCount() && c.KnotAt(k + 1) == u) ++k;
    }
  }
  return n;
}

bool CurvesBitIdentical(const NurbsCurve& a, const NurbsCurve& b) {
  if (a.ControlPointCount() != b.ControlPointCount() || a.KnotCount() != b.KnotCount()) return false;
  for (int i = 0; i < a.ControlPointCount(); ++i)
    if (a.ControlPointAt(i).DistanceTo(b.ControlPointAt(i)) != 0.0) return false;
  for (int k = 0; k < a.KnotCount(); ++k)
    if (a.KnotAt(k) != b.KnotAt(k)) return false;
  return true;
}

// Moves the control point that interpolates the curve at knot value `u`
// (a multiplicity == degree knot) by `shift`, turning the knot into a
// genuine C0 kink.
void KinkAt(NurbsCurve& c, double u, Point3d shift) {
  const Point3d at = c.PointAt(u);
  int best = 0;
  double bd = 1e300;
  for (int i = 0; i < c.ControlPointCount(); ++i) {
    const double d = c.ControlPointAt(i).DistanceTo(at);
    if (d < bd) { bd = d; best = i; }
  }
  Point3d p = c.ControlPointAt(best);
  p += shift;
  c.SetControlPointAt(best, p);
}

void TestCurveRemoveMultiKnotsErrorBoundAndBudget() {
  const NurbsCurve base = WavyCubic(9);
  const auto dom = base.Domain();
  const double u1 = dom.min + 0.31 * (dom.max - dom.min);
  const double u2 = dom.min + 0.68 * (dom.max - dom.min);

  // (1) Exactness: a knot inserted twice and not touched is removable with
  // ~zero deviation and the curve is reproduced.
  {
    NurbsCurve c = base;
    Check(c.InsertKnotAt(u1, 2) == Result::Ok, "RMK setup: inserted a double knot");
    Check(InteriorMultipleKnots(c) == 1, "RMK setup: exactly one interior multiple knot before");
    double dev = -1.0;
    Check(c.RemoveMultiKnots(1e-9, &dev) == Result::Ok, "RemoveMultiKnots removes a doubly-inserted knot");
    Check(dev >= 0.0 && dev <= 1e-9, "...reported bound <= tolerance");
    Check(InteriorMultipleKnots(c) == 0, "...no interior multiple knot survives");
    Check(c.ControlPointCount() == base.ControlPointCount() + 1, "...control net is the original plus the one single knot's point");
    Check(CurveDev(base, c) <= 1e-9, "...independent 4001-sample deviation from the original <= 1e-9");
  }

  // (2) Kink within / beyond tolerance: a mult-3 (=degree) knot with a 0.3
  // jump in a control point.
  NurbsCurve kinked = base;
  Check(kinked.InsertKnotAt(u1, 3) == Result::Ok, "RMK setup: inserted a degree-multiplicity knot");
  KinkAt(kinked, u1, Point3d(0, 0.3, 0));
  Check(InteriorMultipleKnots(kinked) == 1, "RMK setup: kink fixture has one multiple knot");
  {
    NurbsCurve c = kinked;
    double dev = -1.0;
    Check(c.RemoveMultiKnots(1e-6, &dev) == Result::Failed, "negative control: a 0.3 kink is NOT removed at tolerance 1e-6");
    Check(CurvesBitIdentical(c, kinked), "...the refused curve is bit-identical to the input");
    Check(dev == 0.0, "...and nothing was removed so the spent bound is 0");
  }
  {
    NurbsCurve c = kinked;
    double dev = -1.0;
    Check(c.RemoveMultiKnots(5.0, &dev) == Result::Ok, "a 0.3 kink IS removed at tolerance 5");
    Check(InteriorMultipleKnots(c) == 0, "...the knot is single afterwards");
    const double actual = CurveDev(kinked, c);
    Check(actual > 1e-3, "...the removal measurably changed the curve (independent oracle: real kink smoothing)");
    Check(actual <= dev + 1e-12, "...independent dense deviation <= the reported rigorous bound");
    Check(dev <= 5.0, "...reported bound <= tolerance");
  }

  // (3) Shared budget: two kinks of very different size; a tolerance big
  // enough for the small one and too small for the big one removes only
  // the small one, and the reported bound never exceeds the tolerance.
  NurbsCurve two = base;
  Check(two.InsertKnotAt(u1, 3) == Result::Ok && two.InsertKnotAt(u2, 3) == Result::Ok, "RMK setup: two degree-multiplicity knots");
  KinkAt(two, u1, Point3d(0, 0.02, 0));
  KinkAt(two, u2, Point3d(0, 1.2, 0));
  Check(InteriorMultipleKnots(two) == 2, "RMK setup: two multiple knots");
  double total = 0.0;
  {
    NurbsCurve c = two;
    Check(c.RemoveMultiKnots(100.0, &total) == Result::Ok && InteriorMultipleKnots(c) == 0, "unlimited budget removes both kinks");
    Check(CurveDev(two, c) <= total + 1e-12, "...dense deviation <= reported bound (both removed)");
  }
  {
    NurbsCurve c = two;
    double dev = -1.0;
    const double tol = total * 0.2;
    Check(c.RemoveMultiKnots(tol, &dev) == Result::Ok, "a budget of 20% of the full cost still removes the small kink");
    Check(InteriorMultipleKnots(c) == 1, "...but the big kink stays (exactly one multiple knot left)");
    Check(dev <= tol, "...reported bound <= tolerance");
    Check(CurveDev(two, c) <= dev + 1e-12, "...dense deviation <= reported bound (partial removal)");
  }

  // (4) NoOp and argument contracts.
  {
    NurbsCurve c = base;
    double dev = -1.0;
    Check(c.RemoveMultiKnots(1.0, &dev) == Result::NoOpAlreadySatisfied && dev == 0.0, "a curve with no interior multiple knot is a NoOp with deviation 0");
    bool threw = false;
    try { c.RemoveMultiKnots(0.0); } catch (const std::invalid_argument&) { threw = true; }
    Check(threw, "tolerance 0 throws std::invalid_argument");
    threw = false;
    try { c.RemoveMultiKnots(std::numeric_limits<double>::quiet_NaN()); } catch (const std::invalid_argument&) { threw = true; }
    Check(threw, "NaN tolerance throws std::invalid_argument");
  }
}

NurbsSurface WavySurface(int nu, int nv) {
  std::vector<Point3d> g;
  for (int i = 0; i < nu; ++i)
    for (int j = 0; j < nv; ++j)
      g.push_back(Point3d(i * 1.0, j * 1.0, 0.8 * std::sin(0.8 * i) * std::cos(0.6 * j)));
  return NurbsSurface::FromControlGrid(g, nu, nv, 3, 3);
}

double SurfDev(const NurbsSurface& a, const NurbsSurface& b, int n = 121) {
  const auto du = a.Domain(0), dv = a.Domain(1);
  double worst = 0.0;
  for (int i = 0; i <= n; ++i)
    for (int j = 0; j <= n; ++j) {
      const double u = du.min + (du.max - du.min) * i / n, v = dv.min + (dv.max - dv.min) * j / n;
      worst = std::max(worst, a.PointAt(u, v).DistanceTo(b.PointAt(u, v)));
    }
  return worst;
}

int SurfMultiple(const NurbsSurface& s, int dir) {
  const auto d = s.Domain(dir);
  int n = 0;
  for (int k = 0; k + 1 < s.KnotCount(dir); ++k) {
    const double u = s.raw().Knot(dir, k);
    if (u > d.min && u < d.max && s.raw().Knot(dir, k + 1) == u) {
      ++n;
      while (k + 1 < s.KnotCount(dir) && s.raw().Knot(dir, k + 1) == u) ++k;
    }
  }
  return n;
}

bool SurfBitIdentical(const NurbsSurface& a, const NurbsSurface& b) {
  const int cu = a.CVCountU(), cv = a.CVCountV();
  if (cu != b.CVCountU() || cv != b.CVCountV() || a.KnotCount(0) != b.KnotCount(0) || a.KnotCount(1) != b.KnotCount(1)) return false;
  for (int i = 0; i < cu; ++i)
    for (int j = 0; j < cv; ++j)
      if (a.ControlPointAt(i, j).DistanceTo(b.ControlPointAt(i, j)) != 0.0) return false;
  for (int d = 0; d < 2; ++d)
    for (int k = 0; k < a.KnotCount(d); ++k)
      if (a.raw().Knot(d, k) != b.raw().Knot(d, k)) return false;
  return true;
}

void TestSurfaceRemoveMultiKnotsBothDirections() {
  const NurbsSurface base = WavySurface(7, 6);
  for (int dir = 0; dir < 2; ++dir) {
    const auto dom = base.Domain(dir);
    const double u1 = dom.min + 0.43 * (dom.max - dom.min);
    const std::string tag = dir == 0 ? "U: " : "V: ";
    // Exact: a doubly-inserted knot goes away with ~0 deviation.
    {
      NurbsSurface s = base;
      Check(s.InsertKnotAt(dir, u1, 2) == Result::Ok && SurfMultiple(s, dir) == 1, (tag + "RMK setup: double knot inserted").c_str());
      double dev = -1.0;
      Check(s.RemoveMultiKnots(dir, 1e-9, &dev) == Result::Ok, (tag + "RemoveMultiKnots removes a doubly-inserted knot").c_str());
      Check(SurfMultiple(s, dir) == 0 && dev <= 1e-9, (tag + "...single knot afterwards, bound <= tolerance").c_str());
      Check(SurfDev(base, s) <= 1e-9, (tag + "...independent 122x122 deviation from the original <= 1e-9").c_str());
      Check(SurfMultiple(s, 1 - dir) == 0, (tag + "...the other direction is untouched (still no multiple knots)").c_str());
    }
    // Kink: a whole control row/column displaced at a degree-multiplicity knot.
    NurbsSurface kinked = base;
    Check(kinked.InsertKnotAt(dir, u1, 3) == Result::Ok, (tag + "RMK setup: degree-multiplicity knot inserted").c_str());
    {
      const Point3d at = dir == 0 ? kinked.PointAt(u1, kinked.Domain(1).min) : kinked.PointAt(kinked.Domain(0).min, u1);
      int best = 0;
      double bd = 1e300;
      const int n = dir == 0 ? kinked.CVCountU() : kinked.CVCountV();
      for (int i = 0; i < n; ++i) {
        const Point3d p = dir == 0 ? kinked.ControlPointAt(i, 0) : kinked.ControlPointAt(0, i);
        if (p.DistanceTo(at) < bd) { bd = p.DistanceTo(at); best = i; }
      }
      const int m = dir == 0 ? kinked.CVCountV() : kinked.CVCountU();
      for (int j = 0; j < m; ++j) {
        const int ci = dir == 0 ? best : j, cj = dir == 0 ? j : best;
        Point3d p = kinked.ControlPointAt(ci, cj);
        p += Point3d(0, 0, 0.35);
        kinked.SetControlPointAt(ci, cj, p);
      }
    }
    {
      NurbsSurface s = kinked;
      double dev = -1.0;
      Check(s.RemoveMultiKnots(dir, 1e-6, &dev) == Result::Failed, (tag + "negative control: the 0.35 kink is refused at tolerance 1e-6").c_str());
      Check(SurfBitIdentical(s, kinked), (tag + "...refused surface is bit-identical to the input").c_str());
    }
    {
      NurbsSurface s = kinked;
      double dev = -1.0;
      Check(s.RemoveMultiKnots(dir, 5.0, &dev) == Result::Ok && SurfMultiple(s, dir) == 0, (tag + "the kink is removed at tolerance 5").c_str());
      const double actual = SurfDev(kinked, s);
      Check(actual > 1e-3, (tag + "...and that removal measurably changed the surface (oracle: real smoothing)").c_str());
      Check(actual <= dev + 1e-12 && dev <= 5.0, (tag + "...independent dense deviation <= reported rigorous bound <= tolerance").c_str());
    }
  }
  // Contracts.
  NurbsSurface s = base;
  double dev = -1.0;
  Check(s.RemoveMultiKnots(0, 1.0, &dev) == Result::NoOpAlreadySatisfied && dev == 0.0, "a surface with no interior multiple knot is a NoOp with deviation 0");
  bool threw = false;
  try { s.RemoveMultiKnots(2, 1.0); } catch (const std::invalid_argument&) { threw = true; }
  Check(threw, "direction 2 throws std::invalid_argument");
  threw = false;
  try { s.RemoveMultiKnots(0, -1.0); } catch (const std::invalid_argument&) { threw = true; }
  Check(threw, "negative tolerance throws std::invalid_argument");
}

void TestSurfaceFitToToleranceMeetsToleranceOnIndependentGrid() {
  // Source: an exact interpolant through a 14x14 sample of an analytic
  // function (many control points, genuinely curved).
  std::vector<Point3d> g;
  const int n = 14;
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < n; ++j) {
      const double x = 4.0 * i / (n - 1), y = 4.0 * j / (n - 1);
      g.push_back(Point3d(x, y, 0.5 * std::sin(1.7 * x) * std::cos(1.3 * y) + 0.1 * x));
    }
  NurbsSurface src;
  Check(NurbsSurface::InterpolateThroughGrid(g, n, n, src) == Result::Ok, "FitSrf setup: source interpolant built");

  int last_total = 0;
  for (double tol : {5e-2, 5e-3, 5e-4}) {
    NurbsSurface out;
    double dev = -1.0;
    int uc = 0, vc = 0;
    const Result r = src.FitToTolerance(tol, 3, 3, 40, out, &dev, &uc, &vc);
    Check(r == Result::Ok, "FitToTolerance succeeds");
    if (r != Result::Ok) continue;
    // Independent oracle: dense grid offset by an irrational fraction so it
    // never coincides with the kernel's own sample grids.
    const auto du = src.Domain(0), dv = src.Domain(1);
    double worst = 0.0;
    for (int i = 0; i < 300; ++i)
      for (int j = 0; j < 300; ++j) {
        const double u = du.min + (du.max - du.min) * (i + 0.3819660) / 300.0;
        const double v = dv.min + (dv.max - dv.min) * (j + 0.6180339) / 300.0;
        worst = std::max(worst, src.PointAt(u, v).DistanceTo(out.PointAt(u, v)));
      }
    std::printf("  FitSrf tol %.0e -> %dx%d net, reported dev %.3e, independent dev %.3e\n", tol, uc, vc, dev, worst);
    Check(worst <= tol, "...independent 300x300 offset-grid deviation <= the stated tolerance");
    Check(dev <= tol, "...reported deviation <= the stated tolerance");
    Check(out.CVCountU() == uc && out.CVCountV() == vc, "...reported net size is the real net size");
    Check(out.DegreeU() == 3 && out.DegreeV() == 3, "...degree is the requested 3x3");
    Check(uc + vc >= last_total, "...a tighter tolerance never yields a smaller net");
    last_total = uc + vc;
    // Minimality at the last step: the net one point smaller in at least
    // one direction really does miss the tolerance (greedy, not global).
    NurbsSurface smaller;
    double d1 = 0.0, d2 = 0.0;
    bool miss1 = uc <= 4 || src.Rebuild(uc - 1, vc, 3, 3, smaller, &d1, 64, 64) != Result::Ok || d1 > tol;
    bool miss2 = vc <= 4 || src.Rebuild(uc, vc - 1, 3, 3, smaller, &d2, 64, 64) != Result::Ok || d2 > tol;
    Check(miss1 || miss2, "...a net one control point smaller in U or V misses the tolerance (not over-built)");
  }

  // Exactly representable source: a 5x4 bicubic is recovered at 5x4.
  {
    NurbsSurface exact = WavySurface(5, 4);
    NurbsSurface out;
    double dev = -1.0;
    int uc = 0, vc = 0;
    Check(exact.FitToTolerance(1e-9, 3, 3, 12, out, &dev, &uc, &vc) == Result::Ok, "an exactly representable 5x4 bicubic fits at 1e-9");
    Check(uc == 5 && vc == 4, "...with exactly the 5x4 net (nothing smaller can represent it)");
    Check(SurfDev(exact, out) <= 1e-9, "...independent deviation <= 1e-9");
  }

  // Negative controls: unreachable tolerance at a tiny ceiling.
  {
    NurbsSurface out = WavySurface(3, 3);
    const NurbsSurface sentinel = out;
    double dev = -1.0;
    int uc = 0, vc = 0;
    Check(src.FitToTolerance(1e-7, 3, 3, 6, out, &dev, &uc, &vc) == Result::Failed, "negative control: 1e-7 with at most 6 points per direction is refused");
    Check(SurfBitIdentical(out, sentinel), "...`out` is left untouched on refusal");
    Check(dev > 1e-7 && std::isfinite(dev), "...the best achieved deviation is reported and exceeds the tolerance");
    bool t1 = false, t2 = false, t3 = false;
    NurbsSurface o;
    try { src.FitToTolerance(0.0, 3, 3, 10, o); } catch (const std::invalid_argument&) { t1 = true; }
    try { src.FitToTolerance(1e-3, 0, 3, 10, o); } catch (const std::invalid_argument&) { t2 = true; }
    try { src.FitToTolerance(1e-3, 3, 3, 3, o); } catch (const std::invalid_argument&) { t3 = true; }
    Check(t1 && t2 && t3, "tolerance 0, degree 0 and max_control_points <= degree all throw std::invalid_argument");
  }
}

void TestBrepShrinkSurfacesTolerance() {
  // A 10x10 plane (domain [0,1]^2 after FromControlGrid), trimmed to an
  // octagon of circumradius 0.2 (in uv) around (0.5, 0.5) with a 0.1 x 0.1
  // square hole: exact 3D area = 100 * (2*sqrt(2)*0.04 - 0.01).
  std::vector<Point3d> grid = {Point3d(0, 0, 0), Point3d(0, 10, 0), Point3d(10, 0, 0), Point3d(10, 10, 0)};
  NurbsSurface plane = NurbsSurface::FromControlGrid(grid, 2, 2, 1, 1);
  std::vector<Point2d> octagon;
  for (int k = 0; k < 8; ++k) octagon.push_back(Point2d(0.5 + 0.2 * std::cos(k * ON_PI / 4.0), 0.5 + 0.2 * std::sin(k * ON_PI / 4.0)));
  std::vector<Point2d> hole = {Point2d(0.55, 0.45), Point2d(0.55, 0.55), Point2d(0.45, 0.55), Point2d(0.45, 0.45)};
  Brep brep = Brep::TrimmedPlanarFaceWelded(plane, octagon, {hole});
  const double exact_area = 100.0 * (2.0 * std::sqrt(2.0) * 0.04 - 0.01);
  Check(brep.raw().IsValid(), "ShrinkSurfaces setup: the trimmed face is a valid Brep");
  Check(std::fabs(brep.Area() - exact_area) < 1e-6, "ShrinkSurfaces setup: trimmed area matches the closed form");

  const Brep before = brep;
  const auto du0 = before.raw().m_F[0].SurfaceOf()->Domain(0);
  const auto dv0 = before.raw().m_F[0].SurfaceOf()->Domain(1);
  Check(du0.Length() > 0.99 && dv0.Length() > 0.99, "ShrinkSurfaces setup: the surface domain starts as the whole plane");

  // (1) Tiny nonzero tolerance: the face boundary does not move at all.
  Brep::ShrinkSurfacesReport rep;
  const Result r = brep.ShrinkSurfaces(1e-9, &rep);
  Check(r == Result::Ok, "ShrinkSurfaces shrinks the over-sized plane under a 1e-9 tolerance");
  const ON_Surface* sa = brep.raw().m_F[0].SurfaceOf();
  const ON_Interval ua = sa->Domain(0), va = sa->Domain(1);
  std::printf("  Shrink: domain u[%.4f,%.4f] v[%.4f,%.4f] area ratio %.4f slack %.3e shift %.3e\n", ua.Min(), ua.Max(), va.Min(), va.Max(),
              rep.min_domain_area_ratio, rep.max_slack_fraction, rep.max_trim_shift);
  Check(rep.faces_shrunk == 1 && rep.faces_total == 1, "...one face reported shrunk");
  Check(ua.Length() < 0.5 && va.Length() < 0.5, "...independent: the new domain is under half the original width in both directions");
  Check(ua.Min() <= 0.3 + 1e-9 && ua.Max() >= 0.7 - 1e-9 && va.Min() <= 0.3 + 1e-9 && va.Max() >= 0.7 - 1e-9,
        "...independent: the new domain still contains the whole octagon's bounding box [0.3,0.7]^2");
  Check(rep.max_slack_fraction < 0.1, "...the shrink is reasonably tight (slack < 10% of the original width)");
  Check(rep.max_trim_shift <= 1e-9 && rep.max_containment_violation <= 1e-9, "...reported boundary shift and containment violation within tolerance");
  Check(std::fabs(brep.Area() - exact_area) < 1e-6, "...independent: trimmed area still matches the closed form");
  Check(std::fabs(rep.area_before - rep.area_after) < 1e-9, "...reported area before/after agree");
  Check(brep.raw().IsValid(), "...the shrunk Brep is still valid");
  // Independent oracle: the surface point at 400 (u, v) inside the new
  // domain is unchanged by the shrink.
  const ON_Surface* sb = before.raw().m_F[0].SurfaceOf();
  double worst = 0.0;
  for (int i = 0; i < 20; ++i)
    for (int j = 0; j < 20; ++j) {
      const double u = ua.ParameterAt((i + 0.5) / 20.0), v = va.ParameterAt((j + 0.5) / 20.0);
      worst = std::max(worst, sb->PointAt(u, v).DistanceTo(sa->PointAt(u, v)));
    }
  Check(worst <= 1e-9, "...independent: surface points inside the new domain are unchanged (<= 1e-9)");
  // Independent oracle: every trim's start vertex is still where the shrunk
  // surface says its (u, v) is.
  double vworst = 0.0;
  for (int ti = 0; ti < brep.raw().m_T.Count(); ++ti) {
    const ON_BrepTrim& tr = brep.raw().m_T[ti];
    if (tr.m_vi[0] < 0) continue;
    const ON_3dPoint uv = tr.PointAtStart();
    vworst = std::max(vworst, brep.raw().m_V[tr.m_vi[0]].point.DistanceTo(sa->PointAt(uv.x, uv.y)));
  }
  Check(vworst <= 1e-9, "...independent: every trim start vertex still equals the shrunk surface evaluated at its (u, v)");

  // (2) A second shrink finds nothing more to do.
  {
    Brep again = brep;
    Brep::ShrinkSurfacesReport rep2;
    const Result r2 = again.ShrinkSurfaces(1e-9, &rep2);
    Check(r2 == Result::NoOpAlreadySatisfied || rep2.min_domain_area_ratio > 0.99, "shrinking an already shrunk face is a NoOp (or a <1% change)");
  }

  // (3) Untrimmed single-surface face: nothing to shrink, Brep untouched.
  {
    Brep whole = Brep::FromSurface(plane);
    const Brep keep = whole;
    Brep::ShrinkSurfacesReport rep3;
    Check(whole.ShrinkSurfaces(1e-9, &rep3) == Result::NoOpAlreadySatisfied, "an untrimmed face is a NoOp");
    Check(!rep3.reason.empty(), "...and the report carries the reason");
    Check(whole.raw().m_F[0].SurfaceOf()->Domain(0).Length() == keep.raw().m_F[0].SurfaceOf()->Domain(0).Length(), "...domain unchanged");
  }

  // (4) Argument contract.
  {
    Brep copy = before;
    bool threw = false;
    try { copy.ShrinkSurfaces(0.0); } catch (const std::invalid_argument&) { threw = true; }
    Check(threw, "tolerance 0 throws std::invalid_argument");
    threw = false;
    try { copy.ShrinkSurfaces(-1.0); } catch (const std::invalid_argument&) { threw = true; }
    Check(threw, "negative tolerance throws std::invalid_argument");
    Check(copy.raw().m_F[0].SurfaceOf()->Domain(0).Length() == du0.Length(), "...a rejected call leaves the Brep untouched");
  }
}

}  // namespace surfops_tolerance_tests


int main() {
  ON::Begin();
  surfops_tolerance_tests::TestCurveRemoveMultiKnotsErrorBoundAndBudget();
  surfops_tolerance_tests::TestSurfaceRemoveMultiKnotsBothDirections();
  surfops_tolerance_tests::TestSurfaceFitToToleranceMeetsToleranceOnIndependentGrid();
  surfops_tolerance_tests::TestBrepShrinkSurfacesTolerance();
  ON::End();
  std::printf("failures=%d\n", g_failures);
  return g_failures ? 1 : 0;
}
