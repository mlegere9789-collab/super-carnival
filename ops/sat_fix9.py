p = '/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e/dino8-app/src/io/FileSat.cpp'
s = open(p).read()
a = 'const char* const kLayoutNote ='
helper = '''// A whole-sphere / whole-torus body has one face and no edges. The kernel builds it as a bare NURBS face, which the
// application's mesher does not display or measure (bounding box, Volume and Area all came back 0 in the app), so it is
// rebuilt as the same native ON_BrepSphere / ON_BrepTorus the Sphere and Torus commands create. Anything else is untouched.
bool RebuildWholePrimitive(const kernel::Brep& in, kernel::Brep& out, const char*& what) {
  const ON_Brep& b = in.raw();
  if (b.m_F.Count() != 1 || b.m_E.Count() != 0) return false;
  const ON_Surface* srf = b.m_F[0].SurfaceOf();
  if (!srf) return false;
  ON_Sphere sph;
  ON_Torus tor;
  ON_Brep* made = nullptr;
  if (srf->IsSphere(&sph, 1e-6 * std::max(1.0, sph.radius)) || srf->IsSphere(&sph, 1e-4)) {
    made = ON_BrepSphere(sph);
    what = "sphere";
  } else if (srf->IsTorus(&tor, 1e-4)) {
    made = ON_BrepTorus(tor);
    what = "torus";
  }
  if (!made) return false;
  out.raw() = *made;
  delete made;
  return true;
}

'''
assert a in s
s = s.replace(a, helper + a, 1)
old = '''    SceneObject o = SceneObject::MakeBrep(res.bodies[i]);
    o.name = name;
    os << "\\n" << BodyLine(res.bodies[i], name, o.BoundingBox());
'''
new = '''    kernel::Brep body = res.bodies[i];
    kernel::Brep rebuilt;
    const char* prim = "";
    if (RebuildWholePrimitive(body, rebuilt, prim)) {
      body = rebuilt;
      rebuilt_notes += std::string("\\nNote: ") + name + " is a whole " + prim + " face with no edges; it was rebuilt as the application's native " + prim +
                       " Brep (outward orientation) so it can be displayed and measured.";
    }
    SceneObject o = SceneObject::MakeBrep(body);
    o.name = name;
    os << "\\n" << BodyLine(body, name, o.BoundingBox());
'''
assert old in s
s = s.replace(old, new)
s = s.replace('''  std::ostringstream os;
  os << "SAT import " << file''', '''  std::ostringstream os;
  std::string rebuilt_notes;
  os << "SAT import " << file''')
old2 = '''  for (const std::string& w : res.warnings) os << "\\nRefused/skipped: " << w;
  os << "\\nCoordinates were taken'''
assert old2 in s
s = s.replace(old2, '''  os << rebuilt_notes;
  for (const std::string& w : res.warnings) os << "\\nRefused/skipped: " << w;
  os << "\\nCoordinates were taken''')
open(p, 'w').write(s)
