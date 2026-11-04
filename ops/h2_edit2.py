import os
base = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/src/commands/'

p = base + 'cmd_fillet.cpp'
s = open(p).read()
marker = "void RegisterFilletCommands(CommandEngine& e) {"
assert s.count(marker) == 1
fn = r'''// FilletEdge / ChamferEdge re-execution (history_rebuild.h): replays the recorded
// steps on the CURRENT source solid. Each recorded edge is re-found by its
// geometric signature on the solid as it stands at that step (so a chamfer
// recorded after an earlier one is searched for on the already-chamfered
// intermediate), then the same exact kernel calls the live command made are
// run: FilletConvexEdges/FilletConcaveEdges for a fillet step, ChamferConvexEdge/
// ChamferConcaveEdge for a chamfer. There is no approximate fallback: a
// refusal names the edge or the kernel's reason and the dependent is kept.
std::optional<SceneObject> RebuildEdgeBlend(CommandContext& ctx, const HistoryInputs& in, const HistoryRecord& rec, std::string& why) {
  if (in.size() != 1) { why = "expected 1 source object, the record has " + std::to_string(in.size()); return std::nullopt; }
  const SceneObject& src = *in[0];
  if (src.kind != ObjectKind::Brep || !src.brep) {
    why = "source object " + std::to_string(src.id) + " is " + HistoryKindName(src.kind) + ", not a polysurface solid";
    return std::nullopt;
  }
  const bool fillet = rec.command == "FilletEdge";
  auto num = [&](const std::string& k, double d = 0.0) { const auto it = rec.num.find(k); return it == rec.num.end() ? d : it->second; };
  const double r = num("r");
  const bool sym = num("sym", 1.0) != 0.0;
  const double d2 = sym ? r : num("d2", r);
  const int n = static_cast<int>(num("n")), groups = static_cast<int>(num("groups", 1));
  if (!(r > 0) || n < 1) { why = "the record holds no usable distance or edge list"; return std::nullopt; }
  ON_Brep cur = src.brep->raw();
  for (int g = 0; g < groups; ++g) {
    std::vector<std::pair<Point3d, Point3d>> es;
    for (int k = 0; k < n; ++k) {
      if (static_cast<int>(num(EdgeKey(k, "g"), 0.0)) != g) continue;
      EdgeSig want;
      if (!LoadSig(rec.num, k, want)) { why = "the record of edge " + std::to_string(k + 1) + " is incomplete"; return std::nullopt; }
      std::string reason;
      const int ei = FindEdgeBySignature(cur, want, reason);
      if (ei < 0) { why = "edge " + std::to_string(k + 1) + " of " + std::to_string(n) + ": " + reason; return std::nullopt; }
      es.emplace_back(Point3d(cur.m_E[ei].PointAtStart()), Point3d(cur.m_E[ei].PointAtEnd()));
      ctx.Print(rec.command + ": edge " + std::to_string(k + 1) + " re-found as edge " + std::to_string(ei) + " of the source (direction and both face normals match)");
    }
    if (es.empty()) { why = "step " + std::to_string(g + 1) + " has no edges"; return std::nullopt; }
    kernel::Brep kb;
    kb.raw() = cur;
    std::string convex_err, concave_err;
    kernel::Brep out;
    auto attempt = [&](bool convex, std::string& err) {
      try {
        if (fillet) {
          out = convex ? kernel::FilletConvexEdges(kb, es, r) : kernel::FilletConcaveEdges(kb, es, r);
        } else {
          kernel::Brep b = kb;
          for (const auto& e : es) b = convex ? kernel::ChamferConvexEdge(b, e.first, e.second, r, d2) : kernel::ChamferConcaveEdge(b, e.first, e.second, r, d2);
          out = b;
        }
        return true;
      } catch (const std::exception& ex) {
        err = ex.what();
        return false;
      }
    };
    const bool ok = attempt(true, convex_err) || attempt(false, concave_err);
    if (!ok) {
      why = std::string("the exact kernel ") + (fillet ? "fillet" : "chamfer") + " refused the edited source (convex attempt: " + convex_err + "; concave attempt: " + concave_err + ")";
      return std::nullopt;
    }
    cur = out.raw();
  }
  kernel::Brep result;
  result.raw() = cur;
  return SceneObject::MakeBrep(result);
}

'''
s = s.replace(marker, fn + marker)
open(p, 'w').write(s)

p = base + 'history_rebuild.h'
s = open(p).read()
anchor = "// Offset (cmd_edit.cpp), curves:"
assert anchor in s
s = s.replace(anchor, '''// FilletEdge / ChamferEdge (cmd_fillet.cpp), exact kernel paths only. One source
// solid; the record holds the options (num: r = radius or distance1, d2 =
// distance2, sym = 1 when distance2 follows r), the number of edge entries (n),
// the number of steps (groups) and, per edge k, its geometric signature
// (e<k>_{r,m,d,a,b}{x,y,z}: bounding-box-relative midpoint, midpoint, direction,
// the two face normals) and its step (e<k>_g). Each edge is re-found on the
// edited source by direction + both face normals (+ relative position when
// several match); no edge, or no clear nearest one, refuses with the reason.
std::optional<SceneObject> RebuildEdgeBlend(CommandContext& ctx, const HistoryInputs& inputs, const HistoryRecord& rec, std::string& why);

''' + anchor, 1)
open(p, 'w').write(s)

p = base + 'cmd_history.cpp'
s = open(p).read()
old = '''  for (const char* name : {"BooleanUnion", "BooleanDifference", "BooleanIntersection", "Boolean2Objects"}) SetParams(name, BooleanParams());
}'''
assert old in s
s = s.replace(old, '''  SetParams("FilletEdge", {
      NumberParam("radius", "fillet radius", "> 0",
                  [](const HistoryRecord& r) { return NumOf(r, "r"); },
                  [](HistoryRecord& r, double d) -> std::string {
                    if (!(d > 0.0)) return "radius must be positive";
                    r.num["r"] = d;
                    return "";
                  })});
  SetParams("ChamferEdge", {
      NumberParam("distance", "chamfer distance (distance1; distance2 follows it while it is symmetric)", "> 0",
                  [](const HistoryRecord& r) { return NumOf(r, "r"); },
                  [](HistoryRecord& r, double d) -> std::string {
                    if (!(d > 0.0)) return "distance must be positive";
                    r.num["r"] = d;
                    return "";
                  }),
      NumberParam("distance2", "second chamfer distance (setting it makes the chamfer asymmetric)", "> 0",
                  [](const HistoryRecord& r) { return NumOf(r, "sym", 1.0) != 0.0 ? NumOf(r, "r") : NumOf(r, "d2"); },
                  [](HistoryRecord& r, double d) -> std::string {
                    if (!(d > 0.0)) return "distance2 must be positive";
                    r.num["d2"] = d;
                    r.num["sym"] = 0.0;
                    return "";
                  })});
''' + old, 1)
old = '''  for (const char* name : {"BooleanUnion", "BooleanDifference", "BooleanIntersection", "Boolean2Objects"})
    RegisterHistoryRebuilder(name, std::string(name) + " of closed solid B-reps (exact engines)", RebuildBoolean);'''
assert old in s
s = s.replace(old, '''  RegisterHistoryRebuilder("FilletEdge", "FilletEdge of a solid (exact kernel fillet, edges re-found by direction and face normals)", RebuildEdgeBlend);
  RegisterHistoryRebuilder("ChamferEdge", "ChamferEdge of a solid (exact kernel chamfer, edges re-found by direction and face normals)", RebuildEdgeBlend);
''' + old, 1)
a = "OffsetSrf, Shell (closed, uniform thickness, no opened faces), and the exact"
assert a in s
s = s.replace(a, "OffsetSrf, Shell (closed, uniform thickness, no opened faces), FilletEdge/ChamferEdge (exact kernel paths, edges re-found by geometry), and the exact", 1)
a = "Revolve Output=SubD, FilletEdge/ChamferEdge, Project/Pull,"
assert a in s
s = s.replace(a, "Revolve Output=SubD, FilletEdge with Rho/RailType/variable radii or the approximate path, ChamferEdge by angle, Project/Pull,", 1)
open(p, 'w').write(s)
print("done")
