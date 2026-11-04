p='dino8-kernel/src/sweep.cpp'
full=open(p).read()
A=full.index('Brep Brep::Sweep2Sections(')
B=full.index('Brep Brep::Sweep1Sections(')
s=full[A:B]
def rep(old,new):
    global s
    assert s.count(old)==1, old[:70]
    s=s.replace(old,new)
rep('''  for (size_t i = 0; i < na; ++i) {
    const TwoRailFrame& f = frames[static_cast<size_t>(anchor_station[i])];
    for (int c = 0; c < n; ++c) {
      const ON_3dVector d = EuclideanCV(compat[i], c) - f.origin;''','''  for (size_t i = 0; i < na; ++i) {
    const TwoRailFrame& f = frames[static_cast<size_t>(anchor_station[i])];
    if (!(f.width > 0.0)) Fail(caller, "a section sits where the two rails touch - it has no width to be decoded against");
    for (int c = 0; c < n; ++c) {
      const ON_3dVector d = EuclideanCV(compat[i], c) - f.origin;''')
rep('''    const size_t lo = i == 0 ? 0 : i - 1, hi = i + 1 == na ? na - 1 : i + 1;
    const double dx = anchor_x[hi] - anchor_x[lo];''','''    // (cyclic: the neighbours wrap round the ring, an abscissa one ring length further on/back across the seam)
    const size_t lo = cyclic ? (i + na - 1) % na : (i == 0 ? 0 : i - 1), hi = cyclic ? (i + 1) % na : (i + 1 == na ? na - 1 : i + 1);
    const double dx = (anchor_x[hi] + (cyclic && i + 1 == na ? ring_length : 0.0)) - (anchor_x[lo] - (cyclic && i == 0 ? ring_length : 0.0));''')
rep('''    while (seg + 1 < na && anchor_station[seg + 1] <= k) ++seg;
    const TwoRailFrame& f = frames[static_cast<size_t>(k)];
    ON_NurbsCurve ck = compat.front();
    const bool before_first = k <= anchor_station[0];
    const bool after_last = k >= anchor_station[na - 1];''','''    while (seg + 1 < na && anchor_station[seg + 1] <= k) ++seg;
    const TwoRailFrame& f = frames[static_cast<size_t>(k)];
    ON_NurbsCurve ck = compat.front();
    const bool before_first = !cyclic && k <= anchor_station[0];
    const bool after_last = !cyclic && k >= anchor_station[na - 1];
    const size_t seg_next = (seg + 1) % na;  // cyclic: the last segment runs on to the first anchor, one ring further''')
rep('''        const double x0 = anchor_x[seg], x1 = anchor_x[seg + 1], h = x1 - x0;''','''        const double x0 = anchor_x[seg], x1 = seg + 1 < na ? anchor_x[seg + 1] : ring_length, h = x1 - x0;''')
rep('''        l = local[seg][static_cast<size_t>(c)] * (2 * s3 - 3 * s2 + 1) + slope[seg][static_cast<size_t>(c)] * (h * (s3 - 2 * s2 + s)) +
            local[seg + 1][static_cast<size_t>(c)] * (-2 * s3 + 3 * s2) + slope[seg + 1][static_cast<size_t>(c)] * (h * (s3 - s2));
        w = weight[seg][static_cast<size_t>(c)] * (1.0 - s) + weight[seg + 1][static_cast<size_t>(c)] * s;''','''        l = local[seg][static_cast<size_t>(c)] * (2 * s3 - 3 * s2 + 1) + slope[seg][static_cast<size_t>(c)] * (h * (s3 - 2 * s2 + s)) +
            local[seg_next][static_cast<size_t>(c)] * (-2 * s3 + 3 * s2) + slope[seg_next][static_cast<size_t>(c)] * (h * (s3 - s2));
        w = weight[seg][static_cast<size_t>(c)] * (1.0 - s) + weight[seg_next][static_cast<size_t>(c)] * s;''')
rep('''  const std::vector<double> params_v = SkinParameters(copies, false, &period, caller);
  std::unique_ptr<ON_NurbsSurface> wall = SkinSections(copies, std::min(3, m - 1), false, params_v, period, caller);

  if (report) {''','''  const std::vector<double> params_v = SkinParameters(copies, cyclic, &period, caller);
  std::unique_ptr<ON_NurbsSurface> wall = SkinSections(copies, std::min(3, m - 1), cyclic, params_v, period, caller);

  if (report) {''')
open(p,'w').write(full[:A]+s+full[B:])
