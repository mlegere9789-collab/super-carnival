S='/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
W='/home/user/miniature-pancake/.claude/worktrees/agent-ad9fdba50f11440b3/dino8-kernel/'
b=open(S+'builder.txt').read()
b=b.replace('''    std::string txt = ON_String(log_text).Array() ? std::string(ON_String(log_text).Array()) : std::string();''','''    const ON_String log_utf8(log_text);
    std::string txt = log_utf8.Array() ? std::string(log_utf8.Array()) : std::string();''')
p=W+'src/fillet.cpp'
s=open(p).read()
tail='\n}  // namespace dino8::kernel\n'
assert s.endswith(tail)
s=s[:-len(tail)]+b+tail
open(p,'w').write(s)

h=W+'include/dino8/kernel/fillet.h'
t=open(h).read()
add='''
// --- FilletBossOnSlab ----------------------------------------------------------
//
// A CLOSED solid: a rectangular slab (x0..x1 x y0..y1, top face at z = floor_z, `depth` thick) carrying a freeform boss,
// the concave edge where the two meet rounded by FilletSurfaces()'s constant-radius rolling-ball blend. `boss` is a
// NURBS patch that is a graph-like island: it rises above the floor plane in its interior and lies BELOW it all along its
// parameter boundary (so its intersection with the floor is one closed rim inside its domain), and its footprint plus
// four ball radii lies inside the slab rectangle. A downward-pointing boss normal is reversed on a copy.
//
// Faces (7 + 1): the four slab sides and the bottom (planar, straight edges); the top face with a REAL INNER LOOP -
// the floor contact curve (its 3D edge is the blend's own periodic contact curve, its 2D trim the same curve in the
// floor's (x, y) chart); the blend face (periodic in u: bottom = floor contact, top = boss contact, a seam arc used
// twice); the boss face TRIMMED back to the boss contact curve (one outer loop, the contact curve in the boss's own (u, v)).
// Every edge tolerance is the MEASURED worst gap between the edge curve and the image of each of its trims on the face's
// surface (65 samples per trim), reported in `edge_gap`. The result is returned only when ON_Brep::IsValid() and
// IsSolid() both hold; otherwise status = Failed with the reason (and the validity log) and an empty solid.
// NOT done: several bosses, a convex boss edge, a non-planar floor, a boss that crosses its own periodic seam.
struct BossOnSlabFillet {
  Result status = Result::Failed;
  std::string reason;
  Brep solid;
  SurfaceFillet fillet;  // the blend patch, contact curves, deviation and (u, v) trims the faces are built from
  int floor_face = -1, blend_face = -1, boss_face = -1;
  double edge_gap = 0;
  double radius = 0;
};
BossOnSlabFillet FilletBossOnSlab(const NurbsSurface& boss, double floor_z, double x0, double x1, double y0, double y1, double depth, double radius,
                                  double tolerance);
'''
marker='\n}  // namespace dino8::kernel'
i=t.rfind(marker)
t=t[:i]+add+t[i:]
t=t.replace("blends, a closed B-rep result.","blends, a closed B-rep result of two freeform parents (FilletBossOnSlab below does the planar floor + freeform boss case).")
open(h,'w').write(t)
print('ok')
