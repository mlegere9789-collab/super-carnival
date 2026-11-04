WT = '/home/user/miniature-pancake/.claude/worktrees/agent-adf410ea55c17e4d8'
p = WT + '/dino8-app/src/commands/cmd_surface.cpp'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, (s.count(old), old[:90])
    s = s.replace(old, new, 1)

# ---- helpers in the anonymous namespace (after Percent)
rep('''std::string Percent(double fraction) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.1f%%", 100.0 * fraction);
  return buf;
}
''', '''std::string Percent(double fraction) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "%.1f%%", 100.0 * fraction);
  return buf;
}

// Per-axis scale of Sweep1 (the ScaleX / ScaleY options): "start,end" - the scale along the section's X (resp. Y) axis at the
// rail's start and end, linear in the rail's arc length in between (a single number is that value all along). Both must be
// positive. The pair is what History records (num sx0 sx1 sy0 sy1); the kernel's two-point schedule {(0, start), (1, end)}.
bool ParseScalePair(const std::string& text, double& a, double& b) {
  std::string t = text;
  for (char& c : t) {
    if (c == ';' || c == ' ') c = ',';
  }
  const size_t comma = t.find(',');
  const std::string first = t.substr(0, comma), second = comma == std::string::npos ? first : t.substr(comma + 1);
  char* e1 = nullptr;
  char* e2 = nullptr;
  a = std::strtod(first.c_str(), &e1);
  b = std::strtod(second.c_str(), &e2);
  if (first.empty() || second.empty() || *e1 != 0 || *e2 != 0 || !std::isfinite(a) || !std::isfinite(b)) return false;
  return a > 0.0 && b > 0.0;
}

std::string ScalePairText(double a, double b) { return FormatNumber(a) + "," + FormatNumber(b); }

bool HasAxisScale(const HistoryRecord& rec) { return rec.num.count("sx0") || rec.num.count("sy0"); }

// The schedules recorded in `rec` (an axis without a record is not scaled).
struct AxisScaleSchedules {
  std::vector<std::pair<double, double>> x, y;
  const std::vector<std::pair<double, double>>* xp = nullptr;
  const std::vector<std::pair<double, double>>* yp = nullptr;
  kernel::Vector3d axis{1.0, 0.0, 0.0};
};

void ReadAxisScale(const HistoryRecord& rec, const kernel::NurbsCurve& rail, AxisScaleSchedules& out) {
  auto get = [&](const char* k) { return rec.num.at(k); };
  if (rec.num.count("sx0")) { out.x = {{0.0, get("sx0")}, {1.0, get("sx1")}}; out.xp = &out.x; }
  if (rec.num.count("sy0")) { out.y = {{0.0, get("sy0")}, {1.0, get("sy1")}}; out.yp = &out.y; }
  // The section's X axis: world X seen in the plane perpendicular to the rail at its start (world Y when the rail starts along X).
  kernel::Vector3d t = rail.TangentAt(rail.Domain().min);
  if (std::fabs(t.x) > 0.99 * t.Length()) out.axis = kernel::Vector3d(0.0, 1.0, 0.0);
}
''')

# ---- the scaled single-section rebuild, placed before RebuildSweep1
rep('''std::optional<SceneObject> RebuildSweep1(CommandContext& ctx, const kernel::NurbsCurve& section,
                                          const kernel::NurbsCurve& rail, const HistoryRecord& rec) {
  try {
    AnchoredSweep r = AnchoredSweep1(section, rail);''', '''// Sweep1 with a per-axis scale (ScaleX / ScaleY): the kernel's Brep::Sweep1 with scale_x_schedule / scale_y_schedule, the
// section at the rail start (the kernel carries a section from the rail's start; a section elsewhere is refused with the
// reason rather than swept with a scale schedule anchored in the wrong place). Never falls back to an unscaled sweep.
std::optional<SceneObject> RebuildSweep1Scaled(CommandContext& ctx, const kernel::NurbsCurve& section, const kernel::NurbsCurve& rail,
                                               const HistoryRecord& rec) {
  try {
    const sectionfit::RailAnchor an = sectionfit::AnchorOnRail(section, rail);
    const kernel::Interval dom = rail.Domain();
    const double rail_tol = kAnchorTolerance * std::max(sectionfit::CurveSize(rail), 1e-9);
    if (rail.PointAt(an.t).DistanceTo(rail.PointAt(dom.min)) > rail_tol) {
      ctx.Print("Sweep1: per-axis scale refused - the section sits " + Percent(RailFraction(rail, an.t)) +
                " along the rail; a scaled sweep needs the section at the rail start (the schedule is measured from there)");
      return std::nullopt;
    }
    AxisScaleSchedules sc;
    ReadAxisScale(rec, rail, sc);
    std::optional<kernel::NurbsSurface> wall = SweptWall(kernel::Brep::Sweep1(section, rail, /*stations=*/32, /*cap=*/false, 0.0, 1.0, nullptr, nullptr, nullptr, sc.xp, sc.yp, &sc.axis));
    if (!wall) {
      ctx.Print("Sweep1: per-axis scale refused - the kernel sweep returned no surface");
      return std::nullopt;
    }
    std::string what;
    if (sc.xp) what += "x " + ScalePairText(rec.num.at("sx0"), rec.num.at("sx1"));
    if (sc.yp) what += std::string(what.empty() ? "" : ", ") + "y " + ScalePairText(rec.num.at("sy0"), rec.num.at("sy1"));
    ctx.Print("Sweep1: exact kernel sweep with a per-axis scale along the rail (" + what + "; x axis = " +
              (sc.axis.y == 1.0 ? "world Y" : "world X") + " in the section plane at the rail start, y perpendicular to it)");
    return CapOrKeepWall(ctx, "Sweep1", *wall, CapRequested(rec));
  } catch (const std::exception& ex) {
    ctx.Print(std::string("Sweep1: per-axis scale refused - the kernel refused (") + ex.what() + ")");
    return std::nullopt;
  }
}

std::optional<SceneObject> RebuildSweep1(CommandContext& ctx, const kernel::NurbsCurve& section,
                                          const kernel::NurbsCurve& rail, const HistoryRecord& rec) {
  if (HasAxisScale(rec)) return RebuildSweep1Scaled(ctx, section, rail, rec);
  try {
    AnchoredSweep r = AnchoredSweep1(section, rail);''')

# ---- multi-section: pass the schedules
rep('''  const double tol = ctx.Settings().absolute_tolerance > 0 ? ctx.Settings().absolute_tolerance : 0.001;
  for (const int stations : {32, 64, 128, 256}) {
    try {
      kernel::Brep::Sweep1SectionsReport rep;
      kernel::Brep body = kernel::Brep::Sweep1Sections(profiles, rail, stations, /*cap=*/false, &rep);''', '''  const double tol = ctx.Settings().absolute_tolerance > 0 ? ctx.Settings().absolute_tolerance : 0.001;
  AxisScaleSchedules sc;
  ReadAxisScale(rec, rail, sc);
  for (const int stations : {32, 64, 128, 256}) {
    try {
      kernel::Brep::Sweep1SectionsReport rep;
      kernel::Brep body = kernel::Brep::Sweep1Sections(profiles, rail, stations, /*cap=*/false, &rep, sc.xp, sc.yp, (sc.xp || sc.yp) ? &sc.axis : nullptr);''')
rep('''      ctx.Print("Sweep1: exact kernel multi-section sweep (" + std::to_string(rep.sections) + " sections, " + std::to_string(rep.stations) +
                " rail stations); measured: sections reproduced to " + FormatDeviation(rep.max_section_deviation) +
                ", between stations within " + FormatDeviation(rep.max_between_station_deviation) + " of the exact blended sections; document tolerance " +
                FormatNumber(tol));''', '''      ctx.Print("Sweep1: exact kernel multi-section sweep (" + std::to_string(rep.sections) + " sections, " + std::to_string(rep.stations) +
                " rail stations); measured: sections reproduced to " + FormatDeviation(rep.max_section_deviation) +
                ", between stations within " + FormatDeviation(rep.max_between_station_deviation) + " of the exact blended sections; document tolerance " +
                FormatNumber(tol));
      if (sc.xp || sc.yp) {
        ctx.Print("Sweep1: per-axis scale applied to the blended sections (" + std::string(sc.xp ? "x " + ScalePairText(rec.num.at("sx0"), rec.num.at("sx1")) : std::string()) +
                  (sc.xp && sc.yp ? ", " : "") + (sc.yp ? "y " + ScalePairText(rec.num.at("sy0"), rec.num.at("sy1")) : std::string()) +
                  "); the reproduced-section figure above is against each input section scaled by the schedule at its own station");
      }''')

# ---- command: options, members, parse, record
rep('''  void Begin(CommandContext&) override {
    options = {{"Cap", "No", {"Yes", "No"}, false, true}};
    WantObjects("Select rail");
  }''', '''  void Begin(CommandContext&) override {
    options = {{"Cap", "No", {"Yes", "No"}, false, true}, {"ScaleX", "1,1", {}, false, false}, {"ScaleY", "1,1", {}, false, false}};
    WantObjects("Select rail");
  }''')
rep('''      options = {{"Closed", closed_ ? "Yes" : "No", {"Yes", "No"}, false, true}, {"Cap", cap_ ? "Yes" : "No", {"Yes", "No"}, false, true}};''',
    '''      options = {{"Closed", closed_ ? "Yes" : "No", {"Yes", "No"}, false, true}, {"Cap", cap_ ? "Yes" : "No", {"Yes", "No"}, false, true},
                 {"ScaleX", ScalePairText(sx_[0], sx_[1]), {}, false, false}, {"ScaleY", ScalePairText(sy_[0], sy_[1]), {}, false, false}};''')
rep('''  void OnOption(CommandContext&, const std::string& n, const std::string& v) override {
    for (OptionSpec& o : options) {
      if (o.name == "Closed" && n == "Closed") { closed_ = (v == "Yes"); o.value = closed_ ? "Yes" : "No"; }
      if (o.name == "Cap" && n == "Cap") { cap_ = (v == "Yes"); o.value = cap_ ? "Yes" : "No"; }
    }
  }''', '''  void OnOption(CommandContext& ctx, const std::string& n, const std::string& v) override {
    for (OptionSpec& o : options) {
      if (o.name == "Closed" && n == "Closed") { closed_ = (v == "Yes"); o.value = closed_ ? "Yes" : "No"; }
      if (o.name == "Cap" && n == "Cap") { cap_ = (v == "Yes"); o.value = cap_ ? "Yes" : "No"; }
      if (o.name == n && (n == "ScaleX" || n == "ScaleY")) {
        double a = 1.0, b = 1.0;
        if (ParseScalePair(v, a, b)) {
          double* dst = n == "ScaleX" ? sx_ : sy_;
          dst[0] = a;
          dst[1] = b;
          o.value = ScalePairText(a, b);
          ctx.Print("Sweep1: " + n + " = " + o.value + " (scale along the section's " + (n == "ScaleX" ? "X" : "Y") + " axis at the rail start, at the rail end)");
        } else {
          ctx.Warn("Sweep1: " + n + " must be 'start,end' - two positive numbers (or one), got '" + v + "'; zero and negative scales are refused, the option keeps " + o.value);
        }
      }
    }
  }
  // The per-axis scale pairs as History numbers (an axis left at 1,1 records nothing, so a plain sweep records exactly what it did before).
  void RecordAxisScale(HistoryRecord& rec) const {
    if (sx_[0] != 1.0 || sx_[1] != 1.0) { rec.num["sx0"] = sx_[0]; rec.num["sx1"] = sx_[1]; }
    if (sy_[0] != 1.0 || sy_[1] != 1.0) { rec.num["sy0"] = sy_[0]; rec.num["sy1"] = sy_[1]; }
  }''')

rep('''      HistoryRecord rec;
      rec.command = "Sweep1";
      if (cap_) rec.num["cap"] = 1.0;
      if (std::optional<SceneObject> exact = RebuildSweep1(ctx, profiles.front(), rail, rec)) {
        const ObjectId new_id = ctx.Doc().Add(std::move(*exact));
        if (rail_id_ && !profile_ids_.empty()) RecordHistoryIfEnabled(ctx, new_id, "Sweep1", {*rail_id_, profile_ids_.front()}, rec.num);
        ctx.Print("Sweep1: exact kernel sweep (rotation-minimizing frames)");
        return;
      }''', '''      HistoryRecord rec;
      rec.command = "Sweep1";
      if (cap_) rec.num["cap"] = 1.0;
      RecordAxisScale(rec);
      if (std::optional<SceneObject> exact = RebuildSweep1(ctx, profiles.front(), rail, rec)) {
        const ObjectId new_id = ctx.Doc().Add(std::move(*exact));
        if (rail_id_ && !profile_ids_.empty()) RecordHistoryIfEnabled(ctx, new_id, "Sweep1", {*rail_id_, profile_ids_.front()}, rec.num);
        ctx.Print("Sweep1: exact kernel sweep (rotation-minimizing frames)");
        return;
      }
      if (HasAxisScale(rec)) {
        ctx.Print("Sweep1: no surface created - the per-axis scale (ScaleX / ScaleY) is only applied by the exact kernel sweep, and it is not silently dropped for the sampled approximation");
        return;
      }''')
rep('''      HistoryRecord rec;
      rec.command = "Sweep1";
      if (cap_) rec.num["cap"] = 1.0;
      std::vector<const kernel::NurbsCurve*> ptrs;''', '''      HistoryRecord rec;
      rec.command = "Sweep1";
      if (cap_) rec.num["cap"] = 1.0;
      RecordAxisScale(rec);
      std::vector<const kernel::NurbsCurve*> ptrs;''')
rep('''      ctx.Print("Sweep1: the exact multi-section sweep was not used (" + multi_reason + "); using the sampled approximation");''',
    '''      if (HasAxisScale(rec)) {
        ctx.Print("Sweep1: no surface created - the per-axis scale (ScaleX / ScaleY) was refused by the exact multi-section sweep (" + multi_reason + ") and is not silently dropped for the sampled approximation");
        return;
      }
      ctx.Print("Sweep1: the exact multi-section sweep was not used (" + multi_reason + "); using the sampled approximation");''')
rep('''  bool closed_ = false;
  bool cap_ = false;
};

// ---------------------------------------------------------------------------
// Sweep2: two rails''', '''  bool closed_ = false;
  bool cap_ = false;
  double sx_[2] = {1.0, 1.0};  // ScaleX: scale along the section's X axis at the rail start / end
  double sy_[2] = {1.0, 1.0};  // ScaleY
};

// ---------------------------------------------------------------------------
// Sweep2: two rails''')
open(p, 'w').write(s)
print('ok')
