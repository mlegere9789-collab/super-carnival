import sys
D = '/home/user/miniature-pancake/.claude/worktrees/agent-a6793fdf3e148e078/dino8-app/src/commands/'
p = D + 'cmd_surface.cpp'
s = open(p).read()

a = s.index("    if (profiles.size() >= 2) {\n      const double tol = ctx.Settings().absolute_tolerance > 0 ? ctx.Settings().absolute_tolerance : 0.001;\n      std::string multi_reason;\n      for (const int stations : {32, 64, 128, 256}) {")
b = s.index("    const bool wrap = closed_ && rail.IsClosed();")
new1 = '''    if (profiles.size() >= 2) {
      std::string multi_reason;
      HistoryRecord rec;
      rec.command = "Sweep1";
      std::vector<const kernel::NurbsCurve*> ptrs;
      for (const kernel::NurbsCurve& c : profiles) ptrs.push_back(&c);
      if (std::optional<SceneObject> exact = RebuildSweep1Sections(ctx, ptrs, rail, rec, multi_reason)) {
        const ObjectId new_id = ctx.Doc().Add(std::move(*exact));
        // History: {rail, section 1, section 2, ...} - the same order UpdateHistory rebuilds from.
        if (rail_id_ && profile_ids_.size() == profiles.size()) {
          std::vector<ObjectId> srcs{*rail_id_};
          srcs.insert(srcs.end(), profile_ids_.begin(), profile_ids_.end());
          RecordHistoryIfEnabled(ctx, new_id, "Sweep1", srcs, rec.num);
        }
        return;
      }
      ctx.Print("Sweep1: the exact multi-section sweep was not used (" + multi_reason + "); using the sampled approximation");
    }
'''
s = s[:a] + new1 + s[b:]

a = s.index("    std::string multi_reason;\n    if (profiles.size() >= 2) {\n      const double tol")
b = s.index("    kernel::NurbsCurve a = rails_[0], b = rails_[1];")
new2 = '''    if (profiles.size() >= 2) {
      std::string multi_reason;
      HistoryRecord rec;
      rec.command = "Sweep2";
      std::vector<const kernel::NurbsCurve*> ptrs;
      for (const kernel::NurbsCurve& c : profiles) ptrs.push_back(&c);
      if (std::optional<SceneObject> exact = RebuildSweep2Sections(ctx, ptrs, rails_[0], rails_[1], rec, multi_reason)) {
        ctx.Doc().BeginChange("Sweep2");
        const ObjectId new_id = ctx.Doc().Add(std::move(*exact));
        // History: {rail 1, rail 2, section 1, section 2, ...}.
        if (rail_ids_.size() == 2 && profile_ids_.size() == profiles.size()) {
          std::vector<ObjectId> srcs{rail_ids_[0], rail_ids_[1]};
          srcs.insert(srcs.end(), profile_ids_.begin(), profile_ids_.end());
          RecordHistoryIfEnabled(ctx, new_id, "Sweep2", srcs, rec.num);
        }
        return;
      }
      ctx.Print("Sweep2: the exact multi-section sweep was not used (" + multi_reason + "); using the scaled-frame fit");
    }
'''
s = s[:a] + new2 + s[b:]

marker = "\n// OffsetSrf's construction for ONE object - shared by OffsetSrfCommand and"
fn = '''
// Sweep1 with SEVERAL cross-sections (Sweep1Command::Build and UpdateHistory):
// the kernel's exact Brep::Sweep1Sections. Every section is anchored on the
// rail, decoded in its rotation-minimizing frame, blended between neighbours and
// skinned through the stations, so each section is reproduced. The kernel's own
// report is held to the DOCUMENT tolerance (sections reproduced; the wall
// against the exact blended sections between stations, retried at up to 256
// stations). Always an uncapped Surface. Returns nullopt with `why` set when the
// kernel refuses (closed rail, a plane the rail never crosses, two sections at
// one station, seams that do not line up) or the tolerance is missed; the live
// command then takes its older sampled construction, UpdateHistory keeps the
// object as it was. Prints one measured line on success.
std::optional<SceneObject> RebuildSweep1Sections(CommandContext& ctx, const std::vector<const kernel::NurbsCurve*>& sections,
                                                  const kernel::NurbsCurve& rail, const HistoryRecord&, std::string& why) {
  if (sections.size() < 2) { why = "needs at least two cross sections"; return std::nullopt; }
  std::vector<kernel::NurbsCurve> profiles;
  for (const kernel::NurbsCurve* c : sections) profiles.push_back(*c);
  const double tol = ctx.Settings().absolute_tolerance > 0 ? ctx.Settings().absolute_tolerance : 0.001;
  for (const int stations : {32, 64, 128, 256}) {
    try {
      kernel::Brep::Sweep1SectionsReport rep;
      kernel::Brep body = kernel::Brep::Sweep1Sections(profiles, rail, stations, /*cap=*/false, &rep);
      const ON_NurbsSurface* ns = body.raw().m_F.Count() > 0 ? ON_NurbsSurface::Cast(body.raw().m_F[0].SurfaceOf()) : nullptr;
      if (!ns) { why = "the kernel result has no NURBS wall"; return std::nullopt; }
      if (rep.max_section_deviation > tol) {
        why = "the kernel wall misses an input section by " + FormatDeviation(rep.max_section_deviation) + " (tolerance " + FormatNumber(tol) + ")";
        return std::nullopt;
      }
      if (rep.max_between_station_deviation > tol) {
        why = "between its " + std::to_string(rep.stations) + " stations the wall is " + FormatDeviation(rep.max_between_station_deviation) +
              " from the exact blended sections (tolerance " + FormatNumber(tol) + ")";
        continue;  // more stations
      }
      kernel::NurbsSurface k;
      k.raw() = *ns;
      ctx.Print("Sweep1: exact kernel multi-section sweep (" + std::to_string(rep.sections) + " sections, " + std::to_string(rep.stations) +
                " rail stations); measured: sections reproduced to " + FormatDeviation(rep.max_section_deviation) +
                ", between stations within " + FormatDeviation(rep.max_between_station_deviation) + " of the exact blended sections; document tolerance " +
                FormatNumber(tol));
      return SceneObject::MakeSurface(k);
    } catch (const std::exception& e) {
      why = e.what();
      return std::nullopt;
    }
  }
  return std::nullopt;
}

// Sweep2 with SEVERAL cross-sections: the kernel's Brep::Sweep2Sections, same
// contract as RebuildSweep1Sections (each section decoded in its own station's
// two-rail frame; sections reproduced within the document tolerance and, when
// the sections touch the rails, the wall edges within it of the rails; retried at
// 64 and 128 stations).
std::optional<SceneObject> RebuildSweep2Sections(CommandContext& ctx, const std::vector<const kernel::NurbsCurve*>& sections,
                                                  const kernel::NurbsCurve& rail1, const kernel::NurbsCurve& rail2,
                                                  const HistoryRecord&, std::string& why) {
  if (sections.size() < 2) { why = "needs at least two cross sections"; return std::nullopt; }
  std::vector<kernel::NurbsCurve> profiles;
  for (const kernel::NurbsCurve* c : sections) profiles.push_back(*c);
  const double tol = ctx.Settings().absolute_tolerance > 0 ? ctx.Settings().absolute_tolerance : 0.001;
  for (const int stations : {32, 64, 128}) {
    try {
      kernel::Brep::Sweep2SectionsReport rep;
      kernel::Brep body = kernel::Brep::Sweep2Sections(profiles, rail1, rail2, stations, &rep);
      const ON_NurbsSurface* ns = body.raw().m_F.Count() > 0 ? ON_NurbsSurface::Cast(body.raw().m_F[0].SurfaceOf()) : nullptr;
      if (!ns) { why = "the kernel result has no NURBS wall"; return std::nullopt; }
      const bool touches = rep.rails_on_boundary && rep.section_rail_gap <= tol;
      const double rail_dev = std::max(rep.max_rail1_deviation, rep.max_rail2_deviation);
      if (rep.max_section_deviation > tol) {
        why = "the kernel wall misses an input section by " + FormatDeviation(rep.max_section_deviation) + " (tolerance " + FormatNumber(tol) + ")";
        return std::nullopt;
      }
      if (touches && rail_dev > tol) {
        why = "the wall edges are " + FormatDeviation(rail_dev) + " from the rails at " + std::to_string(rep.stations) + " stations (tolerance " + FormatNumber(tol) + ")";
        continue;  // more stations
      }
      kernel::NurbsSurface k;
      k.raw() = *ns;
      ctx.Print("Sweep2: exact kernel multi-section sweep (" + std::to_string(rep.sections) + " sections, " + std::to_string(rep.stations) +
                " rail stations); measured: sections reproduced to " + FormatDeviation(rep.max_section_deviation) +
                (touches ? ", wall edges within " + FormatDeviation(rail_dev) + " of the rails"
                         : ", sections do not touch both rails (largest gap " + FormatDeviation(rep.section_rail_gap) + ") so no rail-edge claim is made") +
                "; document tolerance " + FormatNumber(tol));
      return SceneObject::MakeSurface(k);
    } catch (const std::exception& e) {
      why = e.what();
      return std::nullopt;
    }
  }
  return std::nullopt;
}

'''
i = s.index(marker)
s = s[:i] + fn + s[i:]
open(p, 'w').write(s)

h = open(D + 'history_rebuild.h').read()
decl = '''
// Sweep1 / Sweep2 with SEVERAL cross-sections (cmd_surface.cpp): the kernel's exact
// Brep::Sweep1Sections / Sweep2Sections. History sources are {rail, section 1, section 2,
// ...} and {rail 1, rail 2, section 1, section 2, ...}. Reads no num parameters. Returns
// nullopt with `why` set when the kernel refuses or the measured result misses the document
// tolerance (the live command then falls back to its older sampled construction and records
// nothing; UpdateHistory keeps the object as it was).
std::optional<SceneObject> RebuildSweep1Sections(CommandContext& ctx, const std::vector<const kernel::NurbsCurve*>& sections,
                                                  const kernel::NurbsCurve& rail, const HistoryRecord& rec, std::string& why);
std::optional<SceneObject> RebuildSweep2Sections(CommandContext& ctx, const std::vector<const kernel::NurbsCurve*>& sections,
                                                  const kernel::NurbsCurve& rail1, const kernel::NurbsCurve& rail2,
                                                  const HistoryRecord& rec, std::string& why);
'''
m = "\n// Patch (the free Patch function, cmd_surface.cpp), single-closed-planar-"
assert m in h
h = h.replace(m, decl + m, 1)
open(D + 'history_rebuild.h', 'w').write(h)

# registry
p = D + 'cmd_history.cpp'
c = open(p).read()
a = c.index('  // Sweep1 sources are {rail, section}')
b = c.index('  RegisterHistoryRebuilder("Patch"')
reg = '''  // Sweep1 sources are {rail, section...}; the kernel call takes (section, rail). Two sources: the
  // single-section sweep; three or more: the multi-section sweep (Brep::Sweep1Sections).
  RegisterHistoryRebuilder("Sweep1", "Sweep1 {rail, section...} (one or several cross-sections)",
      [](CommandContext& ctx, const HistoryInputs& in, const HistoryRecord& rec, std::string& why) -> std::optional<SceneObject> {
        if (in.size() < 2) { why = "expected a rail and at least one cross section, the record has " + std::to_string(in.size()) + " source object(s)"; return std::nullopt; }
        std::vector<const kernel::NurbsCurve*> curves;
        for (const SceneObject* o : in) { const kernel::NurbsCurve* c = HistoryRequireCurve(o, why); if (!c) return std::nullopt; curves.push_back(c); }
        if (curves.size() == 2) return RebuildSweep1(ctx, *curves[1], *curves[0], rec);
        std::vector<const kernel::NurbsCurve*> sections(curves.begin() + 1, curves.end());
        return RebuildSweep1Sections(ctx, sections, *curves[0], rec, why);
      });
  // Sweep2 sources are {rail1, rail2, section...}.
  RegisterHistoryRebuilder("Sweep2", "Sweep2 {rail1, rail2, section...} (one or several cross-sections)",
      [](CommandContext& ctx, const HistoryInputs& in, const HistoryRecord& rec, std::string& why) -> std::optional<SceneObject> {
        if (in.size() < 3) { why = "expected two rails and at least one cross section, the record has " + std::to_string(in.size()) + " source object(s)"; return std::nullopt; }
        std::vector<const kernel::NurbsCurve*> curves;
        for (const SceneObject* o : in) { const kernel::NurbsCurve* c = HistoryRequireCurve(o, why); if (!c) return std::nullopt; curves.push_back(c); }
        if (curves.size() == 3) return RebuildSweep2(ctx, *curves[2], *curves[0], *curves[1], rec);
        std::vector<const kernel::NurbsCurve*> sections(curves.begin() + 2, curves.end());
        return RebuildSweep2Sections(ctx, sections, *curves[0], *curves[1], rec, why);
      });
'''
c = c[:a] + reg + c[b:]
open(p, 'w').write(c)
print("ok")
