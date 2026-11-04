import re
p = '/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel/src/surface_edit.cpp'
s = open(p).read()

# remove trace lines
lines = [l for l in s.split('\n') if 'OFIT_TRACE' not in l and 'trace_t0' not in l]
s = '\n'.join(lines)
s = s.replace('#include <chrono>\n#include <cstdlib>\n', '', 1) if s.count('#include <chrono>') == 1 else s

# cut the degree/source-breaks block out of the tail
a = s.index("  // The fitted spline's degree. Raising a low source degree")
b = s.index("  // Truth at the verification points, measured once")
blk = s[a:b]
s = s[:a] + s[b:]

# cut the gap-analysis block
ga = s.index("  // A base surface whose tangent plane jumps across a knot line")
gb = s.index("  auto distinct = [](double t0, double t1")
gap = s[ga:gb]
s = s[:ga] + s[gb:]

# gap analysis must not depend on the sample grids: use evenly spaced lines
gap = gap.replace("        const std::vector<double>& along = dir == 0 ? v_params : u_params;\n        const size_t stride = std::max<size_t>(1, along.size() / 150);\n",
                  "        const Interval& od = dir == 0 ? dv : du;\n        constexpr int kLines = 121;\n")
gap = gap.replace("          for (size_t k = 0; k < along.size(); k += stride) {\n            const double c = along[k];\n",
                  "          for (int k = 0; k < kLines; ++k) {\n            const double c = od.min + (od.max - od.min) * k / (kLines - 1.0);\n")
gap = gap.replace("std::to_string(u_samples) + \" x \" + std::to_string(v_samples) +\n                    \"); ask", "std::to_string(guard_nu + 1) + \" x \" + std::to_string(guard_nv + 1) +\n                    \"); ask")

# insert both before the sample-building: right before "  int u_samples = guard_nu + 1;"
marker = "  int u_samples = guard_nu + 1;"
assert s.count(marker) == 1
# the blk uses nothing from the samples; it needs nudge-free dom, `du`, `dv`, surface_
s = s.replace(marker, blk + gap + marker)
open(p, 'w').write(s)
print('ok', 'OFIT' in s)
