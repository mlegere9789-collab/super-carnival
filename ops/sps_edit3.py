WT = '/home/user/miniature-pancake/.claude/worktrees/agent-adf410ea55c17e4d8'
p = WT + '/dino8-kernel/include/dino8/kernel/brep.h'
s = open(p).read()
def rep(old, new):
    global s
    assert s.count(old) == 1, (s.count(old), old[:80])
    s = s.replace(old, new, 1)

rep('''  // comment already discloses for its radius.
  static Brep Sweep1(const NurbsCurve& section, const NurbsCurve& rail, int stations = 32,
                     bool cap = true, double twist_total = 0.0, double scale_end = 1.0,
                     const Vector3d* roadlike_up = nullptr,
                     const std::vector<std::pair<double, double>>* twist_schedule = nullptr,
                     const std::vector<std::pair<double, double>>* scale_schedule = nullptr);
''', '''  // comment already discloses for its radius.
  //
  // `scale_x_schedule` / `scale_y_schedule` (either or both; a missing one is held at 1) scale the section NON-
  // UNIFORMLY along two perpendicular axes of its own frame: x along the frame's "x axis" and y along tangent x x, each a
  // piecewise-linear (t, value) schedule in the rail-arc-length fraction exactly like `scale_schedule` (same validation:
  // at least 2 points, strictly increasing t, every value POSITIVE - zero and negative are refused). The x axis is the
  // rotation-minimizing frame's reference normal (the world axis least aligned with the start tangent, projected) turned
  // by the station's twist; `scale_x_axis`, when given, replaces the reference with that direction projected
  // perpendicular to the rail tangent at the START (then carried along by the same frames and twist; zero or parallel
  // to the tangent is refused). The scaling acts about each station's rail point: a section lying in the plane
  // perpendicular to the rail is scaled by exactly (sx, sy) in that frame, the component of a section's offset ALONG
  // the tangent by sqrt(sx sy), so equal x and y values are the uniform scale. Measured: at every station the
  // cross-section is the input section's frame coordinates times (sx, sy) (see sweep_peraxis_scale_tests). Rules:
  //  - it replaces the uniform scale: combining it with `scale_end` != 1 or `scale_schedule` is refused (give equal x and
  //    y schedules for a uniform one - then every station takes the uniform code path, so the result is bit-for-bit
  //    the `scale_schedule` one);
  //  - every breakpoint is a real station (as for the other schedules), so the scale is exact there; between stations
  //    the skin interpolates;
  //  - a scale that changes by more than a factor of 2 between two consecutive stations (a near-discontinuity: two
  //    breakpoints almost at one fraction with very different values) is refused with the factor and the fractions - the
  //    factor 2 is a design bound, not a derived one; the 2-station exact straight-rail path (only the two end points
  //    {0, .} and {1, .}) is an exact ruled wall and is not subject to it;
  //  - on a closed rail each schedule must return to its t = 0 value at t = 1.
  static Brep Sweep1(const NurbsCurve& section, const NurbsCurve& rail, int stations = 32,
                     bool cap = true, double twist_total = 0.0, double scale_end = 1.0,
                     const Vector3d* roadlike_up = nullptr,
                     const std::vector<std::pair<double, double>>* twist_schedule = nullptr,
                     const std::vector<std::pair<double, double>>* scale_schedule = nullptr,
                     const std::vector<std::pair<double, double>>* scale_x_schedule = nullptr,
                     const std::vector<std::pair<double, double>>* scale_y_schedule = nullptr,
                     const Vector3d* scale_x_axis = nullptr);
''')

rep('''  static Brep Sweep1Sections(const std::vector<NurbsCurve>& sections, const NurbsCurve& rail, int stations = 32,
                             bool cap = false, Sweep1SectionsReport* report = nullptr);
''', '''  //
  // `scale_x_schedule` / `scale_y_schedule` / `scale_x_axis`: the per-axis scale of Sweep1() (same schedule contract and
  // axes) applied on top of the blended sections: every station's blended section is scaled by (sx, sy) about the rail
  // point in that station's frame (the blended local offsets along the frame's x axis and y axis times sx and sy, the
  // tangent offset times sqrt(sx sy)). So an input section is reproduced SCALED BY THE SCHEDULE AT ITS OWN STATION (the
  // report's `max_section_deviation` is measured against that scaled section), and schedule value 1 everywhere is
  // bit-for-bit the unscaled sweep. Unlike Sweep1() the schedule breakpoints are NOT inserted as stations (the stations
  // are those of the sections): the scale is exact at the skin stations and between them follows the skin's interpolant,
  // which the same gate measures (`max_between_station_deviation` against the exact scaled blend). Refused: a non-positive
  // value, a schedule that does not return to its starting value on a closed rail, a scale that changes by more than a
  // factor of 2 between two consecutive skin stations (naming the factor and the fractions - more stations or a gentler
  // schedule), a zero / tangent-parallel `scale_x_axis`.
  static Brep Sweep1Sections(const std::vector<NurbsCurve>& sections, const NurbsCurve& rail, int stations = 32,
                             bool cap = false, Sweep1SectionsReport* report = nullptr,
                             const std::vector<std::pair<double, double>>* scale_x_schedule = nullptr,
                             const std::vector<std::pair<double, double>>* scale_y_schedule = nullptr,
                             const Vector3d* scale_x_axis = nullptr);
''')
open(p, 'w').write(s)
print('ok')
