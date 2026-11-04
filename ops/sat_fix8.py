p = '/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e/dino8-app/src/io/FileSat.cpp'
s = open(p).read()
a = s.index('std::string BodyLine(')
b = s.index('const char* const kLayoutNote')
new = '''std::string BodyLine(const kernel::Brep& b, const std::string& name, const kernel::BoundingBox& box) {
  std::ostringstream os;
  os << "  " << name << ": " << b.LiveFaceCount() << " faces, " << b.LiveEdgeCount() << " edges, " << b.LiveVertexCount() << " vertices, ";
  if (b.raw().IsSolid()) os << "closed solid";
  else os << "no closed shell reported by the topology check (open sheet, or a whole-sphere/torus face without boundary edges)";
  os << ", bbox " << Num(box.max.x - box.min.x) << " x " << Num(box.max.y - box.min.y) << " x " << Num(box.max.z - box.min.z);
  // Brep::Area/Volume integrate NURBS faces exactly and refuse other surface types: say so instead of printing half a number.
  std::string area = "not computed here (use Area)";
  try { area = Num(b.Area()); } catch (...) {}
  os << ", area " << area;
  if (b.raw().IsSolid()) {
    std::string vol = "not computed here (use Volume)";
    try { vol = Num(b.Volume()); } catch (...) {}
    os << ", volume " << vol;
  }
  return os.str();
}

'''
s = s[:a] + new + s[b:]
s = s.replace('''    os << "\\n" << BodyLine(res.bodies[i], name);
    SceneObject o = SceneObject::MakeBrep(res.bodies[i]);
    o.name = name;
''', '''    SceneObject o = SceneObject::MakeBrep(res.bodies[i]);
    o.name = name;
    os << "\\n" << BodyLine(res.bodies[i], name, o.BoundingBox());
''')
s = s.replace('''    os << "\\n" << BodyLine(c.brep, c.obj->name.empty() ? std::string(ObjectKindName(c.obj->kind)) : c.obj->name)''', '''    os << "\\n" << BodyLine(c.brep, c.obj->name.empty() ? std::string(ObjectKindName(c.obj->kind)) : c.obj->name, c.obj->BoundingBox())''')
open(p, 'w').write(s)
