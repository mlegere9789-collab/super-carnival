p='/home/user/miniature-pancake/.claude/worktrees/agent-ad9fdba50f11440b3/dino8-kernel/src/fillet.cpp'
s=open(p).read()
def rep(old,new,cnt=1):
    global s
    assert s.count(old)==cnt,(old,s.count(old))
    s=s.replace(old,new)

rep('''  if (ic.closed) return refuse("the intersection curve is closed (a periodic rim); closed rims are not supported by this routine");
  if (ic.points.size() < 4 || !ic.curve.IsValid()) return refuse("the intersection curve is degenerate");
''','''  if (ic.points.size() < 4 || !ic.curve.IsValid()) return refuse("the intersection curve is degenerate");
  const bool closed = ic.closed;
  if (closed) {
    // A rim that crosses a parent's periodic seam is stored with a jump in that parent's parameter; the stations (clamped
    // to the parent's domain) cannot follow it across.
    for (size_t i = 0; i < ic.points.size(); ++i) {
      const size_t j = (i + 1) % ic.points.size();
      for (int d = 0; d < 2; ++d) {
        if (std::fabs(ic.uv_a[i][d] - ic.uv_a[j][d]) > 0.5 * a.raw().Domain(d).Length() || std::fabs(ic.uv_b[i][d] - ic.uv_b[j][d]) > 0.5 * b.raw().Domain(d).Length())
          return refuse("the closed rim crosses a periodic seam of a parent surface (its parameter jumps across the seam); re-seam the parent so the rim stays inside its domain");
      }
    }
  }
''')

rep('''  const int M = 160;
  std::vector<Station> scan((size_t)M + 1);
  int first = -1, last = -1;
  for (int i = 0; i <= M; ++i) {
    scan[(size_t)i] = SolveStation(cx, s0 + (s1 - s0) * i / M);
    const Code c = scan[(size_t)i].code;
    if (c == Code::Fold || c == Code::Tangent || c == Code::Singular) return hard_refusal(scan[(size_t)i], "scan");
    if (c == Code::Ok) { if (first < 0) first = i; last = i; }
  }
  if (first < 0) return refuse(''','''  const int M = 160;
  std::vector<Station> scan((size_t)M + 1);
  int first = -1, last = -1;
  for (int i = 0; i <= (closed ? M - 1 : M); ++i) {
    scan[(size_t)i] = SolveStation(cx, s0 + (s1 - s0) * i / M);
    const Code c = scan[(size_t)i].code;
    if (c == Code::Fold || c == Code::Tangent || c == Code::Singular) return hard_refusal(scan[(size_t)i], "scan");
    if (closed && c != Code::Ok) {
      if (c == Code::OutOfDomain) return refuse("the closed rim's rolling-ball contact points leave a parent's parameter domain at s = " + std::to_string(scan[(size_t)i].s) + " (the blend would run past a free edge of a parent; a closed blend needs the whole rim, offset by the radius, inside both parents)");
      return hard_refusal(scan[(size_t)i], "closed-rim scan");
    }
    if (c == Code::Ok) { if (first < 0) first = i; last = i; }
  }
  if (closed) { first = 0; last = M - 1; }
  if (first < 0) return refuse(''')

rep('''  double sa_ = scan[(size_t)first].s, sb_ = scan[(size_t)last].s;
  auto bisect''','''  double sa_ = closed ? s0 : scan[(size_t)first].s, sb_ = closed ? s1 : scan[(size_t)last].s;
  auto bisect''')
rep('''  if (first > 0) sa_ = bisect(scan[(size_t)first - 1].s, sa_);
  if (last < M) sb_ = bisect(scan[(size_t)last + 1].s, sb_);''','''  if (!closed && first > 0) sa_ = bisect(scan[(size_t)first - 1].s, sa_);
  if (!closed && last < M) sb_ = bisect(scan[(size_t)last + 1].s, sb_);''')

rep('''    const int N = (int)ss.size() - 1;
    std::vector<Station> st;
    st.reserve(ss.size());
    for (int i = 0; i <= N; ++i) {
      st.push_back(station(ss[(size_t)i]));
      const Station& q = st.back();
      if (q.code != Code::Ok) return hard_refusal(q, "station");
      if (q.cond > 1e6) return refuse("the centre solve is ill-conditioned (cond " + std::to_string(q.cond) + ") at s = " + std::to_string(q.s) + ": the centre curve branches or turns");
      if (i > 0) {
        const double dp = q.p.DistanceTo(st[(size_t)i - 1].p), dc = q.c.DistanceTo(st[(size_t)i - 1].c);
        if (dc > 4.0 * dp + 1e-9) return refuse("the centre curve jumps between stations s = " + std::to_string(st[(size_t)i - 1].s) + " and " + std::to_string(q.s) + " (a branch or turning point)");
      }
    }
    Fit fit;
    if (!BuildFit(st, radius, fit)) return refuse("the interpolation of the blend rows failed (singular system or non-positive arc weight)");
    std::unique_ptr<ON_NurbsSurface> S(FitSurface(fit));
    double sdev = 0;
    for (int i = 0; i <= N; ++i)''','''    const int N = (int)ss.size() - 1;
    const int NR = closed ? N : N + 1;  // station rows (a closed rim's last station is the first again)
    std::vector<Station> st;
    st.reserve(ss.size());
    for (int i = 0; i < NR; ++i) {
      st.push_back(station(ss[(size_t)i]));
      const Station& q = st.back();
      if (q.code != Code::Ok) return hard_refusal(q, "station");
      if (q.cond > 1e6) return refuse("the centre solve is ill-conditioned (cond " + std::to_string(q.cond) + ") at s = " + std::to_string(q.s) + ": the centre curve branches or turns");
      if (i > 0) {
        const double dp = q.p.DistanceTo(st[(size_t)i - 1].p), dc = q.c.DistanceTo(st[(size_t)i - 1].c);
        if (dc > 4.0 * dp + 1e-9) return refuse("the centre curve jumps between stations s = " + std::to_string(st[(size_t)i - 1].s) + " and " + std::to_string(q.s) + " (a branch or turning point)");
      }
    }
    if (closed) {
      const double dp = st.back().p.DistanceTo(st.front().p), dc = st.back().c.DistanceTo(st.front().c);
      if (dc > 4.0 * dp + 1e-9) return refuse("the centre curve jumps across the closing seam of the rim (a branch or turning point)");
    }
    Fit fit;
    if (!(closed ? BuildFitPeriodic(st, ss, radius, fit) : BuildFit(st, radius, fit))) return refuse("the interpolation of the blend rows failed (singular system or non-positive arc weight)");
    std::unique_ptr<ON_NurbsSurface> S(closed ? FitSurfacePeriodic(fit) : FitSurface(fit));
    double sdev = 0;
    for (int i = 0; i < NR; ++i)''')

rep('''      for (double f : {0.25, 0.5, 0.75}) {
        const double s = st[(size_t)i].s + f * (st[(size_t)i + 1].s - st[(size_t)i].s);''','''      for (double f : {0.25, 0.5, 0.75}) {
        const double s = ss[(size_t)i] + f * (ss[(size_t)i + 1] - ss[(size_t)i]);''')

rep('''      std::unique_ptr<ON_NurbsCurve> cen(FitCurve3(fit, 10));''','''      std::unique_ptr<ON_NurbsCurve> cen(closed ? FitCurve3Periodic(fit, 10) : FitCurve3(fit, 10));''')
rep('''        std::unique_ptr<ON_NurbsCurve> ca(FitCurve3(fit, 0)), cb(FitCurve3(fit, 7));''','''        std::unique_ptr<ON_NurbsCurve> ca(closed ? FitCurve3Periodic(fit, 0) : FitCurve3(fit, 0)), cb(closed ? FitCurve3Periodic(fit, 7) : FitCurve3(fit, 7));''')
rep('''      for (const Station& q : st) { out.uv_a.push_back(q.uv_a); out.uv_b.push_back(q.uv_b); out.station_s.push_back(q.s); }''','''      for (const Station& q : st) { out.uv_a.push_back(q.uv_a); out.uv_b.push_back(q.uv_b); out.station_s.push_back(q.s); }
      if (closed) { out.uv_a.push_back(st.front().uv_a); out.uv_b.push_back(st.front().uv_b); out.station_s.push_back(ss.back()); }
      out.closed = closed;''')
open(p,'w').write(s)
print("done")
