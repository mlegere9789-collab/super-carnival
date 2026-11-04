p='dino8-kernel/src/sweep.cpp'
s=open(p).read()
old="""  const int m = static_cast<int>(fractions.size());
  std::vector<Frame> frames = RmfFrames(rail, params, wrap, caller);
  if (roadlike_up) {"""
new="""  const int m = static_cast<int>(fractions.size());
  if (wrap && (twist_total != 0.0 || twist_schedule)) {
    // Station k carries the twist of its own fraction and nothing looks at the angle BETWEEN consecutive copies,
    // so a twist of several whole turns spread over too few stations aliases (at one turn per station every
    // copy is the untwisted section again) or is a coarse interpolant. The skin through the copies is only a
    // faithful twisted tube while consecutive copies differ by at most kMaxClosedTwistStep (30 degrees: the
    // relative error of a periodic cubic through a rotation of theta per station is about theta^4/384, 2e-4 at
    // 30 degrees); beyond that the call is refused, naming the angle and the station count that would do.
    constexpr double kMaxClosedTwistStep = ON_PI / 6.0;
    double worst = 0.0;
    for (int k = 0; k < m; ++k) {
      const double f0 = fractions[static_cast<size_t>(k)], f1 = k + 1 < m ? fractions[static_cast<size_t>(k + 1)] : 1.0;
      const double tw0 = twist_schedule ? ScheduleAt(*twist_schedule, f0) : twist_total * f0;
      const double tw1 = twist_schedule ? ScheduleAt(*twist_schedule, f1) : twist_total * f1;
      worst = std::max(worst, std::fabs(tw1 - tw0));
    }
    if (worst > kMaxClosedTwistStep * (1.0 + 1e-9)) {
      const double total_turn = twist_schedule ? std::fabs(ScheduleAt(*twist_schedule, 1.0) - ScheduleAt(*twist_schedule, 0.0)) : std::fabs(twist_total);
      const int need = static_cast<int>(std::ceil(total_turn / kMaxClosedTwistStep)) + 1;
      char buf[320];
      std::snprintf(buf, sizeof(buf),
                    "the twist on a closed rail turns the section by %.1f degrees between consecutive stations (at most 30 "
                    "degrees is allowed, a larger step aliases or is skinned too coarsely) - use more stations (about %d or "
                    "more) or a smaller twist",
                    worst * 180.0 / ON_PI, need);
      Fail(caller, buf);
    }
  }
  std::vector<Frame> frames = RmfFrames(rail, params, wrap, caller);
  if (roadlike_up) {"""
assert old in s
s=s.replace(old,new,1)
open(p,'w').write(s)
