import sys
root = sys.argv[1]
p = root + '/dino8-kernel/src/fillet.cpp'
s = open(p).read()

def rep(s, old, new):
    if old not in s:
        print("skip", old[:40]); return s
    return s.replace(old, new, 1)

s = rep(s, "enum class ProfKind { Plane, Cylinder, Cone, Axis };", "enum class ProfKind { Plane, Cylinder, Cone, Torus, Axis };")
s = rep(s, """  std::vector<ProfKind> kind;  // kind[i] = face type of segment i (Axis = the closing segment on the axis, no face)
  int faces = 0;""", """  std::vector<ProfKind> kind;  // kind[i] = face type of segment i (Axis = the closing segment on the axis, no face)
  std::vector<RevPt> mid;      // mid[i] = a point on the profile arc of a Torus segment (the minor-arc midpoint); unused otherwise
  int faces = 0;""")
s = rep(s, """  struct FaceInfo {
    ProfKind kind;
    ON_Plane plane;
    ON_Cylinder cyl;
    ON_Cone cone;
    std::vector<ON_3dPoint> pts;
  };""", """  struct FaceInfo {
    ProfKind kind;
    int face_index = -1;
    ON_Plane plane;
    ON_Cylinder cyl;
    ON_Cone cone;
    ON_Torus torus;
    std::vector<ON_3dPoint> pts;
  };""")
s = rep(s, """    FaceInfo fi;
    if (!s) { why = "a face has no surface"; return false; }""", """    FaceInfo fi;
    fi.face_index = f;
    if (!s) { why = "a face has no surface"; return false; }""")
s = rep(s, """    else if (s->IsCone(&fi.cone, tol)) fi.kind = ProfKind::Cone;
    else { why = "a face is not a plane, cylinder or cone - not a polygonal solid of revolution"; return false; }""", """    else if (s->IsCone(&fi.cone, tol)) fi.kind = ProfKind::Cone;
    else if (s->IsTorus(&fi.torus, tol)) fi.kind = ProfKind::Torus;  // the exact blend face of an earlier fillet
    else { why = "a face is not a plane, cylinder, cone or torus - not a solid of revolution of straight and circular-arc profile pieces"; return false; }""")
s = rep(s, """    prof.c0 = a.kind == ProfKind::Cylinder ? a.cyl.circle.plane.origin : a.cone.ApexPoint();
    prof.ax = a.kind == ProfKind::Cylinder ? a.cyl.Axis() : a.cone.Axis();""", """    prof.c0 = a.kind == ProfKind::Cylinder ? a.cyl.circle.plane.origin : a.kind == ProfKind::Torus ? a.torus.plane.origin : a.cone.ApexPoint();
    prof.ax = a.kind == ProfKind::Cylinder ? a.cyl.Axis() : a.kind == ProfKind::Torus ? a.torus.plane.zaxis : a.cone.Axis();""")
s = rep(s, """  struct Seg {
    RevPt a, b;
    ProfKind kind;
  };""", """  struct Seg {
    RevPt a, b, m;
    ProfKind kind;
  };""")
s = rep(s, """      const ON_3dVector fax = fi.kind == ProfKind::Cylinder ? fi.cyl.Axis() : fi.cone.Axis();
      const ON_3dPoint fpt = fi.kind == ProfKind::Cylinder ? fi.cyl.circle.plane.origin : fi.cone.ApexPoint();""", """      const ON_3dVector fax = fi.kind == ProfKind::Cylinder ? fi.cyl.Axis() : fi.kind == ProfKind::Torus ? fi.torus.plane.zaxis : fi.cone.Axis();
      const ON_3dPoint fpt = fi.kind == ProfKind::Cylinder ? fi.cyl.circle.plane.origin : fi.kind == ProfKind::Torus ? fi.torus.plane.origin : fi.cone.ApexPoint();""")
s = rep(s, """        for (const RevPt& q : d) if (std::fabs(q.rho - fi.cyl.circle.radius) > rtol) { why = "a cylinder face's circles are off its radius"; return false; }
      } else {""", """        for (const RevPt& q : d) if (std::fabs(q.rho - fi.cyl.circle.radius) > rtol) { why = "a cylinder face's circles are off its radius"; return false; }
      } else if (fi.kind == ProfKind::Torus) {
        // Profile arc: circle of radius minor about (major, z of the torus plane). Both bounding circles must lie on it and
        // the face must be the MINOR arc between them (a fillet / round blend turns by less than pi); anything else
        // (a trimmed or more-than-half torus) is refused rather than guessed.
        const RevPt cen{fi.torus.major_radius, to_prof(fi.torus.plane.origin).z};
        const double mr = fi.torus.minor_radius;
        for (const RevPt& q : d)
          if (std::fabs(std::hypot(q.rho - cen.rho, q.z - cen.z) - mr) > rtol) { why = "a torus face's bounding circles are off its surface"; return false; }
        double bx = (d[0].rho - cen.rho) + (d[1].rho - cen.rho), bz = (d[0].z - cen.z) + (d[1].z - cen.z);
        const double bl = std::hypot(bx, bz);
        if (!(bl > 1e-6 * mr)) { why = "a torus face spans half a turn or more of its tube - not supported"; return false; }
        bx /= bl;
        bz /= bl;
        sg.m = RevPt{cen.rho + mr * bx, cen.z + mr * bz};
        const double cos_half = ((d[0].rho - cen.rho) * bx + (d[0].z - cen.z) * bz) / mr;
        const ON_Surface* ts = b.m_F[fi.face_index].SurfaceOf();
        const ON_Interval du = ts->Domain(0), dv = ts->Domain(1);
        for (int iu = 0; iu <= 4; ++iu)
          for (int iv = 0; iv <= 4; ++iv) {
            const RevPt q = to_prof(ts->PointAt(du.ParameterAt(iu / 4.0), dv.ParameterAt(iv / 4.0)));
            if (std::fabs(std::hypot(q.rho - cen.rho, q.z - cen.z) - mr) > 10.0 * rtol ||
                ((q.rho - cen.rho) * bx + (q.z - cen.z) * bz) / mr < cos_half - 1e-6) {
              why = "a torus face is not the plain minor arc between its two bounding circles (trimmed or not a revolved blend)";
              return false;
            }
          }
      } else {""")
s = rep(s, """    prof.kind.push_back(segs[next_seg].kind);
    cur = fwd""", """    prof.kind.push_back(segs[next_seg].kind);
    prof.mid.push_back(segs[next_seg].m);
    cur = fwd""")

a = s.index("struct RevolveBlendSpec {")
b = s.index("// --- FilletPipeTee")
s = s[:a] + open(sys.argv[2]).read() + s[b:]
open(p, 'w').write(s)

h = root + '/dino8-kernel/include/dino8/kernel/fillet.h'
t = open(h).read()
t = rep(t, """Brep FilletRevolveRim(const Brep& solid, Point3d point_on_rim, double radius);
Brep ChamferRevolveRim(const Brep& solid, Point3d point_on_rim, double distance_wall, double distance_cap);
""", """Brep FilletRevolveRim(const Brep& solid, Point3d point_on_rim, double radius);
Brep ChamferRevolveRim(const Brep& solid, Point3d point_on_rim, double distance_wall, double distance_cap);

// Several rims of the same solid in one exact rebuild, each with its own radius / distances. The input solid may
// already carry the exact torus blend faces and bevel cones that earlier FilletRevolveRim / ChamferRevolveRim (or
// *Rims) calls produced: a face is read back as a plane, cylinder, cone or torus (ON_Surface::IsTorus; a torus must be
// the plain minor arc between its two bounding circles), so rims can be blended one call after another (stepped
// shaft: fillet each step; rounded flange: fillet both rims). Every rim's setbacks are taken from the ORIGINAL profile
// corner, so the result does not depend on the order the rims are listed in (same B-rep up to face order), and a
// profile segment shared by two blended corners must hold both setbacks with a positive length left over. Refusals
// (std::invalid_argument naming the offending rim index) add to the single-rim ones: an empty list, the same rim
// twice, overlapping setbacks on a shared face ("overlapping setbacks: rims i and j ..."), a rim that is the tangent
// seam of an earlier blend or borders a torus face (corner against a curved piece), and a blended profile that would
// run into itself (a blend colliding with a non-adjacent face; checked on the new profile polyline for ALL rim counts).
// The face count of the result is input + number of rims.
struct RevolveRimFillet {
  Point3d point_on_rim;
  double radius = 0;
};
struct RevolveRimChamfer {
  Point3d point_on_rim;
  double distance_wall = 0;
  double distance_cap = 0;
};
Brep FilletRevolveRims(const Brep& solid, const std::vector<RevolveRimFillet>& rims);
Brep ChamferRevolveRims(const Brep& solid, const std::vector<RevolveRimChamfer>& rims);
""")
t = rep(t, "a solid that is not such a solid of revolution (non-analytic face,", "a solid that is not such a solid of revolution (non-analytic face other than the exact torus blend faces,")
open(h, 'w').write(t)
print("ok")
