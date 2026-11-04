// local probe (not committed)
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <functional>
#include <string>
#include "dino8/kernel/boolean_general.h"
#include "dino8/kernel/brep.h"
#include "opennurbs.h"
using namespace dino8::kernel;

static ON_Plane Frame(const ON_3dPoint& o, ON_3dVector axis, double rot = 0) {
  axis.Unitize();
  ON_3dVector seed = std::fabs(axis.z) < 0.9 ? ON_3dVector(0, 0, 1) : ON_3dVector(1, 0, 0);
  ON_3dVector x = ON_CrossProduct(seed, axis); x.Unitize();
  ON_3dVector y = ON_CrossProduct(axis, x); y.Unitize();
  if (rot != 0) { ON_3dVector x2 = std::cos(rot) * x + std::sin(rot) * y; ON_3dVector y2 = ON_CrossProduct(axis, x2); x = x2; y = y2; }
  ON_Plane f; f.origin = o; f.xaxis = x; f.yaxis = y; f.zaxis = axis; f.UpdateEquation(); return f;
}
static Brep::PlanarFace Cap(const ON_Plane& fr, double h, double r, bool flip, int n = 128) {
  Brep::PlanarFace pf; const ON_3dPoint c = fr.origin + fr.zaxis * h;
  pf.plane = ON_Plane(c, flip ? -fr.zaxis : fr.zaxis);
  for (int i = 0; i < n; ++i) { double a = flip ? -2.0 * ON_PI * i / n : 2.0 * ON_PI * i / n;
    pf.loop.push_back(c + fr.xaxis * (r * std::cos(a)) + fr.yaxis * (r * std::sin(a))); }
  pf.notch_begin = 0; pf.notch_count = (int)pf.loop.size(); return pf;
}
static Brep Cyl(const ON_3dPoint& base, const ON_3dVector& axis, double r, double len, double rot = 0) {
  Brep::CylindricalFace cf; cf.frame = Frame(base, axis, rot); cf.radius = r; cf.angle = 2 * ON_PI; cf.length = len;
  return Brep::FromMixedFaces({Cap(cf.frame, 0, r, true), Cap(cf.frame, len, r, false)}, {cf});
}
static void Naked(const Brep& c, double tol) {
  const ON_Brep& b = c.raw(); int n = 0;
  for (int e = 0; e < b.m_E.Count(); ++e) {
    if (b.m_E[e].m_ti.Count() != 2) {
      if (n < 12) { const ON_BrepEdge& E = b.m_E[e]; ON_3dPoint p = E.PointAtStart(), q = E.PointAtEnd();
        std::printf("      naked e%d trims=%d len=%.4g (%.4f %.4f %.4f)->(%.4f %.4f %.4f) face=%d\n", e, E.m_ti.Count(), p.DistanceTo(q), p.x,p.y,p.z,q.x,q.y,q.z,
          E.m_ti.Count() ? b.m_T[E.m_ti[0]].Face()->m_face_index : -1); }
      ++n; }
  }
  std::printf("      naked edges after sew(tol=%g): %d of %d\n", tol, n, b.m_E.Count());
}
static void Run(const char* name, const Brep& a, const Brep& b, BooleanOp op, double expect, bool diag = false) {
  const char* ops[] = {"U", "I", "D"}; int oi = op == BooleanOp::Union ? 0 : op == BooleanOp::Intersection ? 1 : 2;
  try {
    SealedGeneralBoolean s = BooleanCombineGeneralSealed(a, b, op);
    std::printf("%-44s %s SEALED vol=%.5f expect=%.5f rel=%.2e tol=%.2e kh=%d\n", name, ops[oi], s.volume, expect, (s.volume - expect) / expect, s.sew_tolerance, s.keyholes_opened);
  } catch (const std::exception& e) {
    std::printf("%-44s %s REFUSED %s\n", name, ops[oi], e.what());
    if (diag) {
      try { Brep r = BooleanCombineGeneral(a, b, op);
        ON_BoundingBox bb; r.raw().GetBoundingBox(bb); double diag_ = bb.Diagonal().Length();
        std::printf("      raw faces=%d valid=%d solid=%d\n", r.FaceCount(), (int)r.raw().IsValid(), (int)r.raw().IsSolid());
        Brep c = r; double tol = 0.01 * diag_;
        for (int p = 0; p < 3 && !c.raw().IsSolid(); ++p) { c.SewTJunctions(tol); c.JoinNakedEdges(tol); }
        Naked(c, tol);
      } catch (const std::exception& e2) { std::printf("      raw threw %s\n", e2.what()); }
    }
  }
}
int main(int argc, char** argv) {
  ON::Begin();
  const char* sel = argc > 1 ? argv[1] : "";
  const bool diag = std::getenv("PDIAG") != nullptr;
  auto want = [&](const char* n) { return std::string(n).find(sel) != std::string::npos; };
  // A. far hole: box [-2,2]x[-2,2]x[-1,1] pierced by r=1 cylinder, translated by T
  for (double T : {0.0, 1e3, 1e5}) {
    char nm[64]; std::snprintf(nm, sizeof nm, "A far hole T=%g", T);
    if (!want(nm)) continue;
    Brep box = Brep::Box(-2 + T, -2, -1, 2 + T, 2, 1); Brep cyl = Cyl(ON_3dPoint(T, 0, -2), ON_3dVector(0, 0, 1), 1, 4);
    Run(nm, box, cyl, BooleanOp::Difference, 32 - 2 * ON_PI, diag);
    Run(nm, box, cyl, BooleanOp::Union, 32 + 2 * ON_PI, diag);
  }
  // S: sweep refusals, built like the sweep harness
  if (want("S02")) {
    Brep box = Brep::Box(-2, -2, -1, 2, 2, 1); Brep cyl = Cyl(ON_3dPoint(0, 0, 0), ON_3dVector(0, 0, 1), 1, 3);
    Run("S02 cyl-box blind", cyl, box, BooleanOp::Difference, 3 * ON_PI - ON_PI, diag);
  }
  if (want("S01")) {
    Brep box = Brep::Box(-2, -2, -1, 2, 2, 1); Brep cyl = Cyl(ON_3dPoint(0, 0, -2), ON_3dVector(0, 0, 1), 1, 4);
    Run("S01 cyl-box through", cyl, box, BooleanOp::Difference, 2 * ON_PI, diag);
  }
  if (want("S05")) {
    Brep a = Cyl(ON_3dPoint(0, 0, 0), ON_3dVector(0, 0, 1), 1, 4), b = Cyl(ON_3dPoint(1, 0, 1), ON_3dVector(0, 0, 1), 1, 4);
    const double lens = 2 * std::acos(0.5) - 0.5 * std::sqrt(3.0);
    Run("S05 par cyl U", a, b, BooleanOp::Union, 8 * ON_PI - lens * 3, diag);
    Run("S05 par cyl I", a, b, BooleanOp::Intersection, lens * 3, diag);
    Run("S05 par cyl D", a, b, BooleanOp::Difference, 4 * ON_PI - lens * 3, diag);
  }
  if (want("B")) {  // off-axis hole
    for (double ox : {0.5, 1.0, 1.5}) {
      char nm[64]; std::snprintf(nm, sizeof nm, "B off-axis hole ox=%g", ox);
      Brep box = Brep::Box(-2, -2, -1, 2, 2, 1); Brep cyl = Cyl(ON_3dPoint(ox, 0.3, -2), ON_3dVector(0, 0, 1), 1, 4);
      Run(nm, box, cyl, BooleanOp::Difference, 32 - 2 * ON_PI, diag);
    }
  }
  if (want("C")) {  // tees: main R along z centred, branch along x from the axis
    struct T { double R, rb, H, L; } ts[] = {{1, 1, 6, 5}, {1, 2, 6, 5}, {2, 1, 6, 5}, {2, 1, 40, 40}, {2, 1.5, 6, 5}};
    for (const T& t : ts) {
      char nm[64]; std::snprintf(nm, sizeof nm, "C tee R=%g rb=%g H=%g L=%g", t.R, t.rb, t.H, t.L);
      Brep m = Cyl(ON_3dPoint(0, 0, -0.5 * t.H), ON_3dVector(0, 0, 1), t.R, t.H), b = Cyl(ON_3dPoint(0, 0, 0), ON_3dVector(1, 0, 0), t.rb, t.L);
      // closed form: V = pi R^2 H + pi rb^2 L - overlap, overlap = int 2 sqrt(rb^2-y^2) * 2 sqrt(R^2-y^2) /2.. (branch from axis: half)
      double ov = 0; int n = 200000; double ymax = std::min(t.R, t.rb);
      for (int i = 0; i < n; ++i) { double y = -ymax + 2 * ymax * (i + 0.5) / n; ov += std::sqrt(t.rb * t.rb - y * y) * 2 * std::sqrt(t.R * t.R - y * y) * (2 * ymax / n); }
      // branch x from 0 to L, main occupies |x|<sqrt(R^2-y^2); branch part inside main = int_y 2*sqrt(rb^2-y^2)(z-extent) * sqrt(R^2-y^2)  (x extent one sided)
      Run(nm, m, b, BooleanOp::Union, ON_PI * t.R * t.R * t.H + ON_PI * t.rb * t.rb * t.L - ov, diag);
    }
  }
  ON::End();
}
