p='/home/user/miniature-pancake/.claude/worktrees/agent-a6f744a12b0e7f9d5/dino8-kernel/src/acis_sat.cpp'
s=open(p).read()
def rep(a,b,cnt=1):
    global s
    assert s.count(a)==cnt,(a,s.count(a))
    s=s.replace(a,b)
rep('''  std::string& surf_type() { return surf.type; }\n''','')
rep('''    std::string curve_type, curve_text;''','''    WRec curve;  // type + everything after the header triple''')
rep('''        wf.surf_type = "plane-surface";
        wf.surf_text = P3(pl.origin) + " " + V3(pl.zaxis) + " " + V3(pl.xaxis) + " forward_v I I I I";''','''        wf.surf.type = "plane-surface";
        wf.surf.Hdr().Pos(pl.origin).Vec(pl.zaxis).Vec(pl.xaxis).Id("forward_v").Ranges(4);''')
rep('''        wf.surf_type = "cone-surface";
        wf.surf_text = P3(cyl.circle.plane.origin) + " " + V3(ax) + " " + V3(cyl.circle.plane.xaxis * cyl.circle.radius) +
                       " 1 0 1 1 forward_v I I I I";''','''        wf.surf.type = "cone-surface";
        wf.surf.Hdr().Pos(cyl.circle.plane.origin).Vec(ax).Vec(cyl.circle.plane.xaxis * cyl.circle.radius);
        wf.surf.Real(1).Real(0).Real(1).Real(1).Id("forward_v").Ranges(4);''')
rep('''        wf.surf_type = "sphere-surface";
        wf.surf_text = P3(sph.plane.origin) + " " + Num(sph.radius) + " " + V3(sph.plane.xaxis) + " " + V3(sph.plane.zaxis) +
                       " forward_v I I I I";''','''        wf.surf.type = "sphere-surface";
        wf.surf.Hdr().Pos(sph.plane.origin).Real(sph.radius).Vec(sph.plane.xaxis).Vec(sph.plane.zaxis).Id("forward_v").Ranges(4);''')
rep('''        wf.surf_type = "torus-surface";
        wf.surf_text = P3(tor.plane.origin) + " " + V3(tor.plane.zaxis) + " " + Num(tor.major_radius) + " " +
                       Num(tor.minor_radius) + " " + V3(tor.plane.xaxis) + " forward_v I I I I";''','''        wf.surf.type = "torus-surface";
        wf.surf.Hdr().Pos(tor.plane.origin).Vec(tor.plane.zaxis).Real(tor.major_radius).Real(tor.minor_radius).Vec(tor.plane.xaxis);
        wf.surf.Id("forward_v").Ranges(4);''')
rep('''      we.curve_type = "straight-curve";
      we.curve_text = P3(P0) + " " + V3(d) + " I I";''','''      we.curve.type = "straight-curve";
      we.curve.Hdr().Pos(P0).Vec(d).Ranges(2);''')
rep('''      we.curve_type = "ellipse-curve";
      we.curve_text = P3(arc.Center()) + " " + V3(arc.Plane().zaxis) + " " + V3(arc.Plane().xaxis * arc.Radius()) + " 1 I I";''','''      we.curve.type = "ellipse-curve";
      we.curve.Hdr().Pos(arc.Center()).Vec(arc.Plane().zaxis).Vec(arc.Plane().xaxis * arc.Radius()).Real(1).Ranges(2);''')
a=s.index('  void Emit(std::vector<std::string>& lines) {')
b=s.index('  const ON_Brep& b_;\n  std::vector<std::string>& warnings_;')
emit=open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/sab_emit.inc').read()
s=s[:a]+emit+s[b:]
rep('''  // Appends this body's records to `lines`; `base` is the record index of its
  // first record.
  void Write(std::vector<std::string>& lines) {
    Classify();
    Emit(lines);
  }''','''  // Appends this body's records; their indices start at recs.size().
  void Write(std::vector<WRec>& recs) {
    Classify();
    Emit(recs);
  }''')
open(p,'w').write(s)
