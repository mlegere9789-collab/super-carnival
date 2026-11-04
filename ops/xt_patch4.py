import sys
p = sys.argv[1] + '/src/parasolid_xt.cpp'
s = open(p).read()

a = 'std::string BuildBody(const Model& m, const Node& body, ON_Brep& out_brep, bool& approx, bool& loopless, bool& is_solid) {'
b = 'std::string BuildBody(const Model& m, const Node& body, Brep& out_brep, bool& approx, bool& loopless, bool& is_solid) {'
assert a in s
s = s.replace(a, b)

a = '''  BodyCtx cx;
  cx.m = &m;
  for (const FaceIn& fi : faces) {'''
b = '''  // A single loop-free closed face (sphere / torus): built through the kernel's own factories, because a loop-free
  // face needs the Brep class's private per-face side tables, which only its factories populate.
  if (faces.size() == 1 && faces[0].loops.empty()) {
    const FaceIn& fi = faces[0];
    const std::string fd = "face " + std::to_string(fi.fn->index) + ": ";
    SurfModel sm;
    const std::string e = ReadSurfModel(m, *fi.sn, sm);
    if (!e.empty()) return fd + e;
    if (!is_solid) return fd + "a loop-free sphere/torus sheet body is not supported";
    if (!fi.sense) return fd + "inside-out (reversed-sense) loop-free face";
    if (sm.type == kSphere) {
      out_brep = Brep::Sphere(sm.O, sm.r);
    } else if (sm.type == kTorus) {
      out_brep = Brep::Torus(sm.O, sm.Z, sm.r, sm.R2);
    } else {
      return fd + "a face without loops must be a sphere or torus";
    }
    approx = false;
    loopless = true;
    return "";
  }
  BodyCtx cx;
  cx.m = &m;
  for (const FaceIn& fi : faces) {'''
assert a in s
s = s.replace(a, b)

# loopless faces in multi-face bodies: refuse
a = '''  if (loops.empty()) {
    if (sm.type != kSphere && sm.type != kTorus) return fd + "face has no loops and is not a sphere/torus";'''
b = '''  if (loops.empty()) {
    return fd + "a loop-free face inside a multi-face body is not supported yet";
  }
  if (false) {
    if (sm.type != kSphere && sm.type != kTorus) return fd + "face has no loops and is not a sphere/torus";'''
assert a in s
s = s.replace(a, b)

a = '''  approx = cx.approximated_trims;
  loopless = cx.loopless_face;
  out_brep = std::move(cx.brep);
  return "";'''
b = '''  approx = cx.approximated_trims;
  loopless = cx.loopless_face;
  out_brep.raw() = std::move(cx.brep);
  return "";'''
assert a in s
s = s.replace(a, b)

a = '''      ON_Brep brep;
      bool approx = false, loopless = false, solid = false;
      const std::string e = BuildBody(m, kv.second, brep, approx, loopless, solid);'''
b = '''      Brep out;
      bool approx = false, loopless = false, solid = false;
      const std::string e = BuildBody(m, kv.second, out, approx, loopless, solid);'''
assert a in s
s = s.replace(a, b)
s = s.replace('if (!brep.IsValid(&log)) {', 'if (!out.raw().IsValid(&log)) {')
a = '''      Brep out;
      out.raw() = std::move(brep);
      if (solid) {'''
b = '''      if (solid) {'''
assert a in s
s = s.replace(a, b)
open(p, 'w').write(s)
