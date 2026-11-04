import sys
WT = '/home/user/miniature-pancake/.claude/worktrees/agent-adf410ea55c17e4d8'
p = WT + '/dino8-kernel/src/sweep.cpp'
s = open(p).read()

def rep(old, new):
    global s
    assert s.count(old) == 1, (s.count(old), old[:80])
    s = s.replace(old, new, 1)

rep('''Brep Brep::Sweep1(const NurbsCurve& section_in, const NurbsCurve& rail_in, int stations, bool cap, double twist_total,
                  double scale_end, const Vector3d* roadlike_up,
                  const std::vector<std::pair<double, double>>* twist_schedule,
                  const std::vector<std::pair<double, double>>* scale_schedule) {
  const char* caller = "Sweep1";''', '''Brep Brep::Sweep1(const NurbsCurve& section_in, const NurbsCurve& rail_in, int stations, bool cap, double twist_total,
                  double scale_end, const Vector3d* roadlike_up,
                  const std::vector<std::pair<double, double>>* twist_schedule,
                  const std::vector<std::pair<double, double>>* scale_schedule,
                  const std::vector<std::pair<double, double>>* scale_x_schedule,
                  const std::vector<std::pair<double, double>>* scale_y_schedule, const Vector3d* scale_x_axis) {
  const char* caller = "Sweep1";''')

rep('''  if (scale_schedule && scale_end != 1.0) {
    Fail(caller, "scale_end must be 1 when scale_schedule is given - the two are mutually exclusive");
  }
''', '''  if (scale_schedule && scale_end != 1.0) {
    Fail(caller, "scale_end must be 1 when scale_schedule is given - the two are mutually exclusive");
  }
  // Per-axis scale (scale_x_schedule / scale_y_schedule): same validation as the uniform schedule, and it replaces the
  // uniform scale rather than stacking on it.
  const bool axis_scale = scale_x_schedule || scale_y_schedule;
  ValidateSweep1Schedule(scale_x_schedule, "scale_x_schedule", /*value_must_be_positive=*/true, caller);
  ValidateSweep1Schedule(scale_y_schedule, "scale_y_schedule", /*value_must_be_positive=*/true, caller);
  if (axis_scale && (scale_schedule || scale_end != 1.0)) {
    Fail(caller, "scale_x_schedule / scale_y_schedule cannot be combined with scale_end or scale_schedule - give the uniform "
                 "scale as equal x and y schedules instead");
  }
  if (scale_x_axis && !axis_scale) Fail(caller, "scale_x_axis is only meaningful with scale_x_schedule or scale_y_schedule");
''')

rep('''  if (wrap && scale_schedule) {
    const double s0 = ScheduleAt(*scale_schedule, 0.0), s1 = ScheduleAt(*scale_schedule, 1.0);
    if (std::fabs(s1 - s0) > 1e-9 * (s0 + s1)) {
      Fail(caller, "a scale_schedule on a closed rail must return to its starting value at t = 1 so the tube meets "
                   "itself at the seam");
    }
  }
''', '''  if (wrap && scale_schedule) {
    const double s0 = ScheduleAt(*scale_schedule, 0.0), s1 = ScheduleAt(*scale_schedule, 1.0);
    if (std::fabs(s1 - s0) > 1e-9 * (s0 + s1)) {
      Fail(caller, "a scale_schedule on a closed rail must return to its starting value at t = 1 so the tube meets "
                   "itself at the seam");
    }
  }
  if (wrap) {
    const std::pair<const std::vector<std::pair<double, double>>*, const char*> axes[2] = {{scale_x_schedule, "scale_x_schedule"},
                                                                                           {scale_y_schedule, "scale_y_schedule"}};
    for (const auto& pr : axes) {
      if (!pr.first) continue;
      const double s0 = ScheduleAt(*pr.first, 0.0), s1 = ScheduleAt(*pr.first, 1.0);
      if (std::fabs(s1 - s0) > 1e-9 * (s0 + s1)) {
        Fail(caller, std::string(pr.second) + " on a closed rail must return to its starting value at t = 1 so the tube meets "
                                              "itself at the seam");
      }
    }
  }
''')

rep('''  const bool has_schedule = twist_schedule || scale_schedule;  // (closed rail''',
    '''  const bool has_schedule = twist_schedule || scale_schedule || axis_scale;  // (closed rail''')
rep('''    if (straight && is_trivial_two_point(twist_schedule) && is_trivial_two_point(scale_schedule)) {''',
    '''    if (straight && is_trivial_two_point(twist_schedule) && is_trivial_two_point(scale_schedule) &&
        is_trivial_two_point(scale_x_schedule) && is_trivial_two_point(scale_y_schedule)) {''')
rep('''                  (scale_schedule ? scale_schedule->size() : 0));
      // (closed rail: the closing point''', '''                  (scale_schedule ? scale_schedule->size() : 0) + (scale_x_schedule ? scale_x_schedule->size() : 0) +
                  (scale_y_schedule ? scale_y_schedule->size() : 0));
      // (closed rail: the closing point''')
rep('''      if (scale_schedule) {
        for (const auto& p : *scale_schedule) raw.push_back(p.first);
      }
      std::sort(raw.begin(), raw.end());''', '''      if (scale_schedule) {
        for (const auto& p : *scale_schedule) raw.push_back(p.first);
      }
      if (scale_x_schedule) {
        for (const auto& p : *scale_x_schedule) raw.push_back(p.first);
      }
      if (scale_y_schedule) {
        for (const auto& p : *scale_y_schedule) raw.push_back(p.first);
      }
      std::sort(raw.begin(), raw.end());''')

rep('''  const int m = static_cast<int>(fractions.size());
  if (wrap && (twist_total != 0.0 || twist_schedule)) {''', '''  const int m = static_cast<int>(fractions.size());
  if (axis_scale && m > 2) {
    // A scale that jumps between two consecutive stations (a near-discontinuity: breakpoints very close together with
    // very different values) is not resolved by the skin through the stations - refused, not smoothed over.
    const std::pair<const std::vector<std::pair<double, double>>*, const char*> axes[2] = {{scale_x_schedule, "scale_x_schedule"},
                                                                                           {scale_y_schedule, "scale_y_schedule"}};
    for (const auto& pr : axes) {
      if (!pr.first) continue;
      for (int k = 0; k + 1 < m; ++k) {
        const double f0 = fractions[static_cast<size_t>(k)], f1 = fractions[static_cast<size_t>(k + 1)];
        const double v0 = ScheduleAt(*pr.first, f0), v1 = ScheduleAt(*pr.first, f1);
        const double ratio = std::max(v0, v1) / std::min(v0, v1);
        if (ratio > kMaxAxisScaleStep * (1.0 + 1e-9)) {
          char buf[400];
          std::snprintf(buf, sizeof(buf),
                        "%s changes by a factor of %.3g between the consecutive stations at rail fractions %.6g and %.6g (at most %.3g is "
                        "allowed, a larger jump is not resolved by the skin) - use a gentler schedule (breakpoints further apart) or more stations",
                        pr.second, ratio, f0, f1, kMaxAxisScaleStep);
          Fail(caller, buf);
        }
      }
    }
  }
  if (wrap && (twist_total != 0.0 || twist_schedule)) {''')

rep('''    const double s = scale_at(fractions[static_cast<size_t>(k)]);
    if (s != 1.0) {
      xf = ON_Xform::ScaleTransformation(fk.origin, s) * xf;
    }
    if (a != 0.0 || s != 1.0 || k > 0) ck.Transform(xf);''', '''    const double fr = fractions[static_cast<size_t>(k)];
    double sx = scale_at(fr), sy = sx;
    if (axis_scale) {
      sx = scale_x_schedule ? ScheduleAt(*scale_x_schedule, fr) : 1.0;
      sy = scale_y_schedule ? ScheduleAt(*scale_y_schedule, fr) : 1.0;
    }
    if (sx == sy) {
      // (uniform: the pre-existing transform, bit for bit)
      if (sx != 1.0) xf = ON_Xform::ScaleTransformation(fk.origin, sx) * xf;
    } else {
      xf = AxisScaleAbout(fk.origin, fk.t, axis_r(k, a), sx, sy) * xf;
    }
    if (a != 0.0 || sx != 1.0 || sy != 1.0 || k > 0) ck.Transform(xf);''')

rep('''  std::vector<ON_NurbsCurve> copies;
  copies.reserve(static_cast<size_t>(m));
  for (int k = 0; k < m; ++k) {
    ON_NurbsCurve ck = section;
    const Frame& fk = frames[static_cast<size_t>(k)];
    ON_Xform xf = FrameToFrame(frames[0], fk);''', '''  // The section frame's "x" axis at station k: the frame's reference normal turned by the station's twist and by the fixed
  // angle that takes the frame at station 0 onto `scale_x_axis` (projected into the plane perpendicular to the rail
  // tangent there; none given: the reference normal itself). "y" is tangent x x.
  double axis_phi = 0.0;
  if (scale_x_axis) {
    ON_3dVector ax = *scale_x_axis;
    ax = ax - frames[0].t * ON_DotProduct(ax, frames[0].t);
    if (!ax.Unitize()) Fail(caller, "scale_x_axis is zero or parallel to the rail tangent at the start - the section's x axis is undefined");
    axis_phi = std::atan2(ON_DotProduct(ax, frames[0].s), ON_DotProduct(ax, frames[0].r));
  }
  auto axis_r = [&](int k, double twist) {
    const Frame& fk = frames[static_cast<size_t>(k)];
    ON_3dVector r = fk.r;
    const double ang = axis_phi + twist;
    if (ang != 0.0) r.Rotate(ang, fk.t);
    return r;
  };
  std::vector<ON_NurbsCurve> copies;
  copies.reserve(static_cast<size_t>(m));
  for (int k = 0; k < m; ++k) {
    ON_NurbsCurve ck = section;
    const Frame& fk = frames[static_cast<size_t>(k)];
    ON_Xform xf = FrameToFrame(frames[0], fk);''')

rep('''}  // namespace

Brep Brep::Sweep1(const NurbsCurve& section_in,''', '''// Largest ratio between a per-axis scale at two consecutive stations (Sweep1 / Sweep1Sections): a design bound, not a
// derived one - see the doc comment of Brep::Sweep1.
constexpr double kMaxAxisScaleStep = 2.0;

// Affine map about `origin` that scales by `sx` along the unit vector `x` and `sy` along `y = t x x` (both lying in the
// plane perpendicular to the unit rail tangent `t`) and by sqrt(sx sy) along `t`, so equal factors give the uniform scale.
ON_Xform AxisScaleAbout(const ON_3dPoint& origin, const ON_3dVector& t, const ON_3dVector& x, double sx, double sy) {
  const ON_3dVector y = ON_CrossProduct(t, x);
  const double sz = std::sqrt(sx * sy);
  ON_Xform m(ON_Xform::IdentityTransformation);
  const ON_3dVector ax[3] = {x, y, t};
  const double f[3] = {sx, sy, sz};
  for (int i = 0; i < 3; ++i) {
    for (int j = 0; j < 3; ++j) m[i][j] = f[0] * ax[0][i] * ax[0][j] + f[1] * ax[1][i] * ax[1][j] + f[2] * ax[2][i] * ax[2][j];
  }
  const ON_3dVector o(origin);
  for (int i = 0; i < 3; ++i) m[i][3] = o[i] - (m[i][0] * o.x + m[i][1] * o.y + m[i][2] * o.z);
  return m;
}

}  // namespace

Brep Brep::Sweep1(const NurbsCurve& section_in,''')
open(p, 'w').write(s)
print("ok")
