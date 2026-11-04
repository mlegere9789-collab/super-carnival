import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = S + 'ccf_rr_tests.inc'
s = open(p).read()
s = s.replace("fillet_cap_rim_tests::FilletCapRim(cyl", "dino8::kernel::FilletCapRim(cyl")
s = s.replace('''  m = Reason([&] { FilletRevolveRim(plate, top_rim, 1.5); });''', '''  m = Reason([&] { FilletRevolveRim(plate, top_rim, 3.5); });''')
s = s.replace("radius too big: the setback t = r / tan(67.5 deg) must stay below the 3-long plate top and the sqrt(2)-long cone.", "radius too big: the setback t = r / tan(67.5 deg) = 0.4142 r must stay below the 3-long plate top and the sqrt(2)-long cone (r < 3.414).")
s = s.replace("// just inside the limit is accepted (the cone face is sqrt(2) = 1.4142 long, t = r * 0.41421 -> r < 3.414; the plate wall is 2 long -> r < 2)", "// just inside the limit is accepted (the 90-degree outer rim: t = r must stay below the 2-long plate wall)")
s = s.replace('''    const Brep u = dino8::kernel::BooleanCombineGeneral(a, b, dino8::kernel::BooleanOp::Union);
    m = Reason([&] { FilletRevolveRim(u, Point3d(2, 0, 4), 0.2); });''', '''    m = Reason([&] {
      const Brep u = dino8::kernel::BooleanCombineGeneral(a, b, dino8::kernel::BooleanOp::Union);
      FilletRevolveRim(u, Point3d(2, 0, 4), 0.2);
    });''')
open(p, 'w').write(s)
d = '''#include <cstdio>
#include <cstring>
#include <cmath>
#include <functional>
#include <string>
#include <vector>
#include <stdexcept>
#include "dino8/kernel/boolean_general.h"
#include "dino8/kernel/brep.h"
#include "dino8/kernel/fillet.h"
#include "dino8/kernel/mesh.h"
#include "opennurbs.h"
namespace {
int g_failures=0;
void Check(bool c,const char*w){ if(!c){std::fprintf(stderr,"FAILED: %s\\n",w);++g_failures;} else std::printf("ok: %s\\n",w);}
}
namespace fillet_cap_rim_tests {
using dino8::kernel::Brep; using dino8::kernel::Point3d; using dino8::kernel::Vector3d;
Brep MakeCappedCylinder(Point3d base, Vector3d axis, double R, double L){axis.Unitize();const ON_Cylinder cyl(ON_Circle(ON_Plane(base, axis), R), L);ON_Brep* b = ON_BrepCylinder(cyl, true, true);Brep k;k.raw()=*b;delete b;return k;}
void CheckClosedValidSolid(const Brep& res,int faces,const std::string& tag,bool g1=true){
  Check(res.raw().IsValid(),(tag+"valid").c_str());
  Check(res.raw().IsSolid(),(tag+"solid").c_str());
  Check(res.raw().m_F.Count()==faces,(tag+"faces "+std::to_string(res.raw().m_F.Count())).c_str());
  Check(res.TessellateToClosedMesh(48,12).IsClosedManifold(),(tag+"mesh closed").c_str());
}
}
'''
d += s + '''
int main(){ ON::Begin();
 revolve_rim_tests::TestFilletRevolveRimCountersinkMatchesGreenIntegralAndBallGeometry();
 revolve_rim_tests::TestFilletRevolveRimPlateRimMatchesPappusAndConcaveCornerAddsMaterial();
 revolve_rim_tests::TestChamferRevolveRimCountersinkBevelMatchesGreenIntegral();
 revolve_rim_tests::TestRevolveRimRefusesWithReasons();
 std::printf("failures=%d\\n",g_failures); return g_failures; }
'''
open('/home/user/miniature-pancake/.claude/worktrees/agent-ae7c95149abcea35f/dino8-kernel/tests/scratch_test.cpp', 'w').write(d)
