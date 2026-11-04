base = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/src/commands/'
p = base + 'cmd_surface.cpp'
s = open(p).read()

# 1. shared helpers before ProjectCommand
anchor = "class ProjectCommand : public Command {"
assert s.count(anchor) == 1
helpers = r'''// Project/Pull's mapping, shared by ProjectCommand and the history rebuild
// (RebuildProject, below the anonymous namespace). `dir` is the projection
// direction (Project) and unused for Pull (always the true nearest point).
std::optional<Target> TargetOf(const SceneObject& o) {
  if (o.kind == ObjectKind::Curve || o.kind == ObjectKind::Point) return std::nullopt;
  Target t;
  if (o.kind == ObjectKind::Surface && o.surface) t.surface = *o.surface;
  std::optional<kernel::Mesh> m = MeshOf(o, 0.002);
  if (!m) return std::nullopt;
  t.mesh = *m;
  return t;
}

std::optional<Point3d> MapToTargets(const std::vector<Target>& targets, bool pull, Vector3d dir, Point3d p) {
  std::optional<Point3d> best;
  for (const Target& t : targets) {
    std::optional<Point3d> q;
    if (pull) q = t.surface ? t.surface->ClosestPoint(p, 40, 40) : t.mesh.ClosestPoint(p);
    else q = LineHit(t.mesh, p, dir);
    if (q && (!best || q->DistanceTo(p) < best->DistanceTo(p))) best = q;
  }
  return best;
}

// The curve pieces a source curve maps to: runs of consecutive hits each become one curve.
std::vector<kernel::NurbsCurve> ProjectCurvePieces(const kernel::NurbsCurve& curve, const std::vector<Target>& targets, bool pull, Vector3d dir) {
  std::vector<kernel::NurbsCurve> out;
  const bool polyline = curve.Degree() == 1;
  Row samples;
  if (polyline) { for (int i = 0; i < curve.ControlPointCount(); ++i) samples.push_back(curve.ControlPointAt(i)); }
  else samples = SampleCurve(curve, std::min(64, std::max(16, 4 * curve.ControlPointCount())), false);
  Row run;
  auto flush = [&]() {
    if (run.size() >= 2) out.push_back((polyline || run.size() < 4) ? PolylineCurve(run) : kernel::NurbsCurve::FromControlPoints(run, 3));
    run.clear();
  };
  for (const Point3d& p : samples) { if (std::optional<Point3d> q = MapToTargets(targets, pull, dir, p)) run.push_back(*q); else flush(); }
  flush();
  return out;
}

'''
s = s.replace(anchor, helpers + anchor)

# 2. record target ids
old = '''      Target t;
      if (o->kind == ObjectKind::Surface && o->surface) t.surface = *o->surface;
      std::optional<kernel::Mesh> m = MeshOf(*o, 0.002);
      if (!m) continue;
      t.mesh = *m;
      targets_.push_back(std::move(t));
    }'''
assert old in s
s = s.replace(old, '''      std::optional<Target> t = TargetOf(*o);
      if (!t) continue;
      targets_.push_back(std::move(*t));
      target_ids_.push_back(id);
    }''', 1)

# 3. DoWork body
start = s.index("  void DoWork(CommandContext& ctx, Vector3d dir) {")
end = s.index("  bool pull_;\n  bool have_sources_ = false;")
newwork = r'''  void DoWork(CommandContext& ctx, Vector3d dir) {
    // Snapshot the sources before adding anything (Add() may reallocate).
    struct Source { ObjectId id; std::optional<kernel::NurbsCurve> curve; Point3d point; int layer; };
    std::vector<Source> sources;
    for (ObjectId id : sources_) {
      const SceneObject* o = ctx.Doc().Find(id);
      if (!o) continue;
      Source s;
      s.id = id;
      s.layer = o->layer_index;
      if (o->kind == ObjectKind::Curve) s.curve = *o->curve; else s.point = o->point;
      sources.push_back(s);
    }
    const char* label = pull_ ? "Pull" : "Project";
    ctx.Doc().BeginChange(label);
    int curves = 0, points = 0, recorded = 0, split = 0;
    // History On: a source that maps to exactly ONE result is recorded as {source, targets...} so the result follows edits of
    // the source or of a target; a source that splits into several pieces is not (the piece count can change on an edit).
    std::vector<ObjectId> rec_sources;
    std::map<std::string, double> rec_num{{"dx", dir.x}, {"dy", dir.y}, {"dz", dir.z}, {"pull", pull_ ? 1.0 : 0.0}};
    auto record = [&](ObjectId src_id, ObjectId result_id) {
      std::vector<ObjectId> srcs{src_id};
      srcs.insert(srcs.end(), target_ids_.begin(), target_ids_.end());
      RecordHistoryIfEnabled(ctx, result_id, label, srcs, rec_num);
      if (ctx.App().State().history_recording) ++recorded;
    };
    for (const Source& s : sources) {
      if (!s.curve) {
        if (std::optional<Point3d> q = MapToTargets(targets_, pull_, dir, s.point)) {
          SceneObject n = SceneObject::MakePoint(*q);
          n.layer_index = s.layer;
          const ObjectId nid = ctx.Doc().Add(std::move(n));
          record(s.id, nid);
          ++points;
        }
        continue;
      }
      const std::vector<kernel::NurbsCurve> pieces = ProjectCurvePieces(*s.curve, targets_, pull_, dir);
      for (const kernel::NurbsCurve& c : pieces) {
        SceneObject n = SceneObject::MakeCurve(c);
        n.layer_index = s.layer;
        const ObjectId nid = ctx.Doc().Add(std::move(n));
        if (pieces.size() == 1) record(s.id, nid);
        ++curves;
      }
      if (pieces.size() > 1) ++split;
    }
    ctx.Print(std::string(label) + ": " + std::to_string(curves) + " curve(s), " + std::to_string(points) + " point(s)" +
              (ctx.App().State().history_recording
                   ? "; " + std::to_string(recorded) + " result(s) recorded in history" +
                         (split ? ", " + std::to_string(split) + " source(s) split into several pieces and not recorded" : std::string())
                   : std::string()));
  }
  std::vector<ObjectId> target_ids_;
'''
s = s[:start] + newwork + s[end:]

# 4. RebuildProject after the anonymous namespace (before RebuildNetworkSrf2's comment)
anchor2 = "// Shared by NetworkSrf's own 2-curve case above and UpdateHistory"
assert s.count(anchor2) == 1
rebuild = r'''// Project / Pull re-execution (history_rebuild.h). inputs[0] is the source curve or
// point, inputs[1..] the target surfaces/polysurfaces/meshes. A curve must still map
// to exactly ONE piece (it did when recorded); more, fewer or a miss refuses.
std::optional<SceneObject> RebuildProject(CommandContext&, const HistoryInputs& in, const HistoryRecord& rec, std::string& why) {
  if (in.size() < 2) { why = "the record names no target object"; return std::nullopt; }
  auto num = [&](const char* k) { const auto it = rec.num.find(k); return it == rec.num.end() ? 0.0 : it->second; };
  const bool pull = rec.command == "Pull";
  const Vector3d dir(num("dx"), num("dy"), num("dz"));
  if (!pull && dir.Length() < 1e-9) { why = "the record holds no projection direction"; return std::nullopt; }
  std::vector<Target> targets;
  for (size_t i = 1; i < in.size(); ++i) {
    std::optional<Target> t = TargetOf(*in[i]);
    if (!t) { why = "target object " + std::to_string(in[i]->id) + " is " + HistoryKindName(in[i]->kind) + ", not a surface, polysurface or mesh"; return std::nullopt; }
    targets.push_back(std::move(*t));
  }
  const SceneObject& src = *in[0];
  const std::string verb = pull ? "pulled" : "projected";
  if (src.kind == ObjectKind::Point) {
    std::optional<Point3d> q = MapToTargets(targets, pull, dir, src.point);
    if (!q) { why = "the point no longer hits any target when " + verb; return std::nullopt; }
    return SceneObject::MakePoint(*q);
  }
  if (src.kind != ObjectKind::Curve || !src.curve) { why = "source object " + std::to_string(src.id) + " is " + HistoryKindName(src.kind) + ", not a curve or point"; return std::nullopt; }
  const std::vector<kernel::NurbsCurve> pieces = ProjectCurvePieces(*src.curve, targets, pull, dir);
  if (pieces.size() != 1) {
    why = "the curve now " + verb + " to " + std::to_string(pieces.size()) + " piece(s) instead of the one that was recorded";
    return std::nullopt;
  }
  return SceneObject::MakeCurve(pieces[0]);
}

'''
s = s.replace(anchor2, rebuild + anchor2, 1)
open(p, 'w').write(s)

p = base + 'history_rebuild.h'
h = open(p).read()
anchor = "// Offset (cmd_edit.cpp), curves:"
h = h.replace(anchor, '''// Project / Pull (cmd_surface.cpp). sources = {curve or point, target...}; num: dx,dy,dz
// (the projection direction, unused by Pull), pull (1/0). Recorded only for a source that
// maps to exactly ONE result piece; the rebuild refuses (reason printed, result kept) when
// the curve now maps to zero or several pieces, or a point no longer hits a target.
std::optional<SceneObject> RebuildProject(CommandContext& ctx, const HistoryInputs& inputs, const HistoryRecord& rec, std::string& why);

''' + anchor, 1)
open(p, 'w').write(h)

p = base + 'cmd_history.cpp'
t = open(p).read()
old = '''  RegisterHistoryRebuilder("FilletEdge", '''
t = t.replace(old, '''  RegisterHistoryRebuilder("Project", "Project of a curve or point onto surfaces/polysurfaces/meshes (one result piece)", RebuildProject);
  RegisterHistoryRebuilder("Pull", "Pull of a curve or point to surfaces/polysurfaces/meshes (one result piece)", RebuildProject);
''' + old, 1)
a = "FilletEdge/ChamferEdge (exact kernel paths, edges re-found by geometry), Cap, and the exact"
assert a in t
t = t.replace(a, "FilletEdge/ChamferEdge (exact kernel paths, edges re-found by geometry), Cap, Project/Pull (a source that maps to one piece), and the exact", 1)
a = "ChamferEdge by angle, Project/Pull,"
assert a in t
t = t.replace(a, "ChamferEdge by angle, Project/Pull of a source that splits into several pieces,", 1)
open(p, 'w').write(t)
print('ok')
