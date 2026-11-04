#include <chrono>
#include <cstdio>
#include <sstream>
#include "dino8/kernel/acis_sat.h"
#include "dino8/kernel/brep.h"
#include "opennurbs.h"
using namespace dino8::kernel;
using Sched = std::vector<std::pair<double, double>>;

static NurbsCurve CircleIn(const ON_3dPoint& center, const ON_3dVector& normal, const ON_3dVector& xdir, double radius) {
  ON_3dVector n = normal;
  n.Unitize();
  ON_3dVector x = xdir - n * ON_DotProduct(xdir, n);
  x.Unitize();
  ON_NurbsCurve nurbs;
  ON_Circle(ON_Plane(center, x, ON_CrossProduct(n, x)), radius).GetNurbForm(nurbs);
  NurbsCurve k;
  k.raw() = nurbs;
  return k;
}

int main(int argc, char** argv) {
  ON::Begin();
  const bool sat = argc > 1;
  if (!sat) {
    const double R = 10.0, rr = 1.0;
    ON_NurbsCurve rn;
    ON_Circle(ON_Plane(ON_3dPoint(0, 0, 0), ON_3dVector(1, 0, 0), ON_3dVector(0, 1, 0)), R).GetNurbForm(rn);
    NurbsCurve rail;
    rail.raw() = rn;
    const NurbsCurve section = CircleIn(ON_3dPoint(R, 0, 0), ON_3dVector(0, 1, 0), ON_3dVector(0, 0, 1), rr);
    const Sched sx = {{0.0, 1.0}, {0.95, 5.0}, {1.0, 1.0}};
    try {
      Brep b = Brep::Sweep1(section, rail, 32, false, 0.0, 1.0, nullptr, nullptr, nullptr, &sx, nullptr);
      std::printf("sweep1 closed: BUILT faces=%d valid=%d\n", b.FaceCount(), (int)b.raw().IsValid());
    } catch (const std::exception& e) {
      std::printf("sweep1 closed: refused: %s\n", e.what());
    }
    return 0;
  }
  std::string t = "700 0 1 0\n1 a 1 b 1 c\n1 1e-6 1e-10\n";
  t += std::string(100, ' ');
  t += "@18446744073709551594 ";
  t += std::string(100, ' ');
  std::istringstream is(t);
  auto t0 = std::chrono::steady_clock::now();
  AcisSatReadResult r = ReadAcisSat(is);
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("ok=%d err=%s  %.2fs\n", r.ok, r.error.c_str(), s);
}
