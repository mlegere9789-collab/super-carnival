p='dino8-kernel/src/sweep.cpp'
s=open(p).read()
old="""    for (const auto& cp : PairRailCorners(rail1, rail2, caller)) {
      const double merge1 = 1e-8 * (d1_max - d1_min), merge2 = 1e-8 * (d2_max - d2_min);
      size_t i = 0;
"""
new="""    for (const auto& cp : PairRailCorners(rail1, rail2, caller)) {
      const double merge1 = 1e-8 * (d1_max - d1_min), merge2 = 1e-8 * (d2_max - d2_min);
      if (cp.real_on != 0) {
        // A corner of ONE rail only: its partner on the other rail is just a fraction-derived point, which must
        // never override the user's anchors (that would refuse inputs that worked before corners were handled).
        // An anchor on the real corner makes that station the corner (the anchor defines the partner); otherwise
        // the pair is added only when its partner fits between the neighbouring anchors on the other rail, and
        // is dropped (the wall then cuts that corner, as before) when it does not.
        const bool r1 = cp.real_on == 1;
        const std::vector<double>& bp_real = r1 ? bp1 : bp2;
        const std::vector<double>& bp_other = r1 ? bp2 : bp1;
        const double real = r1 ? cp.first : cp.second, partner = r1 ? cp.second : cp.first;
        const double mreal = r1 ? merge1 : merge2, mother = r1 ? merge2 : merge1;
        size_t i = 0;
        while (i < bp_real.size() && bp_real[i] < real - mreal) ++i;
        if (i < bp_real.size() && std::fabs(bp_real[i] - real) <= mreal) {
          corner_at[i] = 1;
          continue;
        }
        if (i == 0 || i >= bp_real.size() || !(bp_other[i - 1] < partner - mother) || !(partner < bp_other[i] - mother)) continue;
        bp1.insert(bp1.begin() + static_cast<std::ptrdiff_t>(i), cp.first);
        bp2.insert(bp2.begin() + static_cast<std::ptrdiff_t>(i), cp.second);
        anchor_at.insert(anchor_at.begin() + static_cast<std::ptrdiff_t>(i), -1);
        corner_at.insert(corner_at.begin() + static_cast<std::ptrdiff_t>(i), 1);
        continue;
      }
      size_t i = 0;
"""
assert old in s
s=s.replace(old,new)
open(p,'w').write(s)
