WT = '/home/user/miniature-pancake/.claude/worktrees/agent-adf410ea55c17e4d8'
p = WT + '/dino8-kernel/src/sweep.cpp'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, (s.count(old), old[:80])
    s = s.replace(old, new, 1)

rep('''Brep Brep::Sweep1Sections(const std::vector<NurbsCurve>& sections_in, const NurbsCurve& rail_in, int stations, bool cap,
                          Sweep1SectionsReport* report) {
  const char* caller = "Sweep1Sections";
  if (stations < 2) Fail(caller, "stations must be at least 2");
  if (sections_in.size() < 2) Fail(caller, "at least 2 sections are required (one section is Sweep1())");
  ON_NurbsCurve rail = rail_in.raw();
  if (!rail.IsValid()) Fail(caller, "rail is not a valid NURBS curve");
''', '''Brep Brep::Sweep1Sections(const std::vector<NurbsCurve>& sections_in, const NurbsCurve& rail_in, int stations, bool cap,
                          Sweep1SectionsReport* report, const std::vector<std::pair<double, double>>* scale_x_schedule,
                          const std::vector<std::pair<double, double>>* scale_y_schedule, const Vector3d* scale_x_axis) {
  const char* caller = "Sweep1Sections";
  if (stations < 2) Fail(caller, "stations must be at least 2");
  if (sections_in.size() < 2) Fail(caller, "at least 2 sections are required (one section is Sweep1())");
  ON_NurbsCurve rail = rail_in.raw();
  if (!rail.IsValid()) Fail(caller, "rail is not a valid NURBS curve");
  const bool axis_scale = scale_x_schedule || scale_y_schedule;
  ValidateSweep1Schedule(scale_x_schedule, "scale_x_schedule", /*value_must_be_positive=*/true, caller);
  ValidateSweep1Schedule(scale_y_schedule, "scale_y_schedule", /*value_must_be_positive=*/true, caller);
  if (scale_x_axis && !axis_scale) Fail(caller, "scale_x_axis is only meaningful with scale_x_schedule or scale_y_schedule");
''')

rep('''  const bool cyclic = rail.IsClosed();
  std::vector<ON_NurbsCurve> sections;
  sections.reserve(sections_in.size());
  double section_scale = 0.0;''', '''  const bool cyclic = rail.IsClosed();
  if (cyclic) {
    const std::pair<const std::vector<std::pair<double, double>>*, const char*> axes[2] = {{scale_x_schedule, "scale_x_schedule"},
                                                                                           {scale_y_schedule, "scale_y_schedule"}};
    for (const auto& pr : axes) {
      if (!pr.first) continue;
      const double s0 = ScheduleAt(*pr.first, 0.0), s1 = ScheduleAt(*pr.first, 1.0);
      if (std::fabs(s1 - s0) > 1e-9 * (s0 + s1)) {
        Fail(caller, std::string(pr.second) + " on a closed rail must return to its starting value at t = 1 so the wall meets "
                                              "itself at the seam");
      }
    }
  }
  std::vector<ON_NurbsCurve> sections;
  sections.reserve(sections_in.size());
  double section_scale = 0.0;''')

rep('''  // The blended section placed in fine station k's frame: cubic Hermite''', '''  // Per-axis scale (scale_x_schedule / scale_y_schedule): applied to the blended local offsets of fine station k, i.e. in
  // that station's rotation-minimizing frame (x axis = the frame's reference normal turned by the fixed angle that takes
  // the frame at the first station onto `scale_x_axis`, projected perpendicular to the rail tangent; y = tangent x x),
  // about the rail point; the tangent component scales by sqrt(sx sy). The schedule's argument is the fraction of the
  // rail's arc length (the same table that spaces the stations).
  double axis_phi = 0.0;
  if (scale_x_axis) {
    ON_3dVector ax = *scale_x_axis;
    ax = ax - frames[0].t * ON_DotProduct(ax, frames[0].t);
    if (!ax.Unitize()) Fail(caller, "scale_x_axis is zero or parallel to the rail tangent at the start - the section's x axis is undefined");
    axis_phi = std::atan2(ON_DotProduct(ax, frames[0].s), ON_DotProduct(ax, frames[0].r));
  }
  const double axis_cos = std::cos(axis_phi), axis_sin = std::sin(axis_phi);
  auto frac_of = [&](int k) { return xf[static_cast<size_t>(k)] / ring_length; };
  if (axis_scale && m > 2) {
    const std::pair<const std::vector<std::pair<double, double>>*, const char*> axes[2] = {{scale_x_schedule, "scale_x_schedule"},
                                                                                           {scale_y_schedule, "scale_y_schedule"}};
    for (const auto& pr : axes) {
      if (!pr.first) continue;
      for (int q = 0; q + 1 < m + (cyclic ? 1 : 0); ++q) {
        const double f0 = frac_of(2 * q), f1 = q + 1 < m ? frac_of(2 * (q + 1)) : 1.0;
        const double v0 = ScheduleAt(*pr.first, f0), v1 = ScheduleAt(*pr.first, f1);
        const double ratio = std::max(v0, v1) / std::min(v0, v1);
        if (ratio > kMaxAxisScaleStep * (1.0 + 1e-9)) {
          char buf[400];
          std::snprintf(buf, sizeof(buf),
                        "%s changes by a factor of %.3g between the consecutive skin stations at rail fractions %.6g and %.6g (at most %.3g is "
                        "allowed, a larger jump is not resolved by the skin) - use a gentler schedule (breakpoints further apart) or more stations",
                        pr.second, ratio, f0, f1, kMaxAxisScaleStep);
          Fail(caller, buf);
        }
      }
    }
  }
  auto axis_scaled = [&](int k, const ON_3dVector& l) {
    const double f = frac_of(k);
    const double sx = scale_x_schedule ? ScheduleAt(*scale_x_schedule, f) : 1.0, sy = scale_y_schedule ? ScheduleAt(*scale_y_schedule, f) : 1.0;
    ON_3dVector out(l.x * std::sqrt(sx * sy), 0.0, 0.0);
    if (axis_phi == 0.0) {
      out.y = l.y * sx;
      out.z = l.z * sy;
    } else {
      const double a = (l.y * axis_cos + l.z * axis_sin) * sx, b = (-l.y * axis_sin + l.z * axis_cos) * sy;
      out.y = a * axis_cos - b * axis_sin;
      out.z = a * axis_sin + b * axis_cos;
    }
    return out;
  };
  // The blended section placed in fine station k's frame: cubic Hermite''')

rep('''      const ON_3dPoint p = f.origin + f.t * l.x + f.r * l.y + f.s * l.z;
      ck.SetCV(c, ON_4dPoint(p.x * w, p.y * w, p.z * w, w));''', '''      if (axis_scale) l = axis_scaled(k, l);
      const ON_3dPoint p = f.origin + f.t * l.x + f.r * l.y + f.s * l.z;
      ck.SetCV(c, ON_4dPoint(p.x * w, p.y * w, p.z * w, w));''')

rep('''      rep.max_section_deviation = std::max(rep.max_section_deviation, wall->PointAt(u, v).DistanceTo(compat[i].PointAt(t)));''',
    '''      rep.max_section_deviation = std::max(rep.max_section_deviation, wall->PointAt(u, v).DistanceTo(ref_section[i].PointAt(t)));''')
rep('''  const ON_Interval du = wall->Domain(0);
  Sweep1SectionsReport rep;
  rep.sections = static_cast<int>(na);''', '''  const ON_Interval du = wall->Domain(0);
  // (With a per-axis scale the reference of section i is the input section scaled by the schedule at its station.)
  std::vector<ON_NurbsCurve> ref_section;
  ref_section.reserve(na);
  for (size_t i = 0; i < na; ++i) ref_section.push_back(axis_scale ? copy_at(anchor_fine[i]) : compat[i]);
  Sweep1SectionsReport rep;
  rep.sections = static_cast<int>(na);''')
open(p, 'w').write(s)
print('ok')
