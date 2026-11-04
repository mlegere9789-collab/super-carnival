import os
os.chdir('/home/user/miniature-pancake/.claude/worktrees/agent-ae218ab20a1caf404/dino8-app')
p = 'src/commands/cmd_history.cpp'
s = open(p).read()
s = s.replace('''  SetParams("ExtrudeCrvTapered", {''', '''  SetParams("ExtrudeCrvAlongCrv", {
      YesNoParam("solid", "cap a closed planar profile into a solid (kernel Brep::ExtrudeAlongCurve)", "solid", false)});
  SetParams("ExtrudeCrvTapered", {''', 1)
open(p, 'w').write(s)

p = 'src/commands/history_rebuild.h'
s = open(p).read()
old = '// the profile along the path. Reads no num parameters.'
assert old in s
s = s.replace(old, '''// the profile along the path. Reads num: solid (1/0, default 0). With solid=1
// the kernel's Brep::ExtrudeAlongCurve builds the capped B-rep solid of a
// closed planar profile (rational profiles/paths are exact); a kernel refusal
// is reported with its reason and nothing is substituted.''')
open(p, 'w').write(s)

p = 'src/commands/cmd_surface.cpp'
s = open(p).read()
old = '''std::optional<SceneObject> RebuildExtrudeAlongCrv(CommandContext&, const kernel::NurbsCurve& profile, const kernel::NurbsCurve& path, const HistoryRecord&) {
  ON_SumSurface ss;'''
new = '''std::optional<SceneObject> RebuildExtrudeAlongCrv(CommandContext& ctx, const kernel::NurbsCurve& profile, const kernel::NurbsCurve& path, const HistoryRecord& rec) {
  const auto solid_it = rec.num.find("solid");
  if (solid_it != rec.num.end() && solid_it->second != 0.0) {
    // Solid=Yes: the kernel's exact sum surface plus two planar caps. A
    // refusal (open or non-planar profile, path displacement in the
    // profile plane, ...) is reported with the kernel's reason and NO
    // surface is substituted for the solid that was asked for.
    try {
      return SceneObject::MakeBrep(kernel::Brep::ExtrudeAlongCurve(profile, path, /*cap=*/true));
    } catch (const std::exception& ex) {
      ctx.Warn(std::string("ExtrudeCrvAlongCrv Solid=Yes: ") + ex.what());
      return std::nullopt;
    }
  }
  ON_SumSurface ss;'''
assert old in s
s = s.replace(old, new)
old = '''    ctx.Doc().BeginChange("ExtrudeCrvAlongCrv");
    int made = 0;
    for (size_t i = 0; i < profiles_.size(); ++i) {
      std::optional<SceneObject> built = RebuildExtrudeAlongCrv(ctx, profiles_[i], path[0], HistoryRecord{});
      if (!built) continue;
      const ObjectId new_id = ctx.Doc().Add(std::move(*built));
      RecordHistoryIfEnabled(ctx, new_id, "ExtrudeCrvAlongCrv", {profile_ids_[i], path_id}, {});
      ++made;
    }
    ctx.Print("ExtrudeCrvAlongCrv: " + std::to_string(made) + " surface(s)");
    Finish();
  }'''
new = '''    ctx.Doc().BeginChange("ExtrudeCrvAlongCrv");
    int made = 0;
    HistoryRecord rec;
    rec.command = "ExtrudeCrvAlongCrv";
    rec.num = {{"solid", solid_ ? 1.0 : 0.0}};
    for (size_t i = 0; i < profiles_.size(); ++i) {
      std::optional<SceneObject> built = RebuildExtrudeAlongCrv(ctx, profiles_[i], path[0], rec);
      if (!built) continue;
      const ObjectId new_id = ctx.Doc().Add(std::move(*built));
      RecordHistoryIfEnabled(ctx, new_id, "ExtrudeCrvAlongCrv", {profile_ids_[i], path_id}, rec.num);
      ++made;
    }
    ctx.Print("ExtrudeCrvAlongCrv: " + std::to_string(made) + (solid_ ? " solid(s)" : " surface(s)"));
    Finish();
  }
  void OnOption(CommandContext&, const std::string& n, const std::string& v) override {
    if (n == "Solid") { solid_ = (v == "Yes"); options[0].value = solid_ ? "Yes" : "No"; }
  }'''
assert old in s
s = s.replace(old, new)
old = '''  void Begin(CommandContext&) override { WantObjects("Select curves to extrude"); }
  void OnObjects(CommandContext& ctx, const std::vector<ObjectId>& ids) override {
    if (profiles_.empty()) {
      profiles_ = CurvesOf(ctx, ids);'''
new = '''  void Begin(CommandContext&) override {
    options = {{"Solid", "No", {"Yes", "No"}, false, true}};
    WantObjects("Select curves to extrude");
  }
  void OnObjects(CommandContext& ctx, const std::vector<ObjectId>& ids) override {
    if (profiles_.empty()) {
      profiles_ = CurvesOf(ctx, ids);'''
assert s.count(old) == 1
s = s.replace(old, new)
old = '''  std::vector<kernel::NurbsCurve> profiles_;
  std::vector<ObjectId> profile_ids_;  // history sources, in lockstep with profiles_
};

class ExtrudeTaperedCommand'''
new = '''  std::vector<kernel::NurbsCurve> profiles_;
  std::vector<ObjectId> profile_ids_;  // history sources, in lockstep with profiles_
  bool solid_ = false;
};

class ExtrudeTaperedCommand'''
assert old in s
s = s.replace(old, new)
open(p, 'w').write(s)
