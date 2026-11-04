p = '/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel/src/surface_edit.cpp'
s = open(p).read()
old = "            const double c = od.min + (od.max - od.min) * k / (kLines - 1.0);\n"
new = "            const double c = od.min + (od.max - od.min) * (k + 0.5) / kLines;\n"
assert old in s
s = s.replace(old, new)
old = "            const double gap = locus(ua, va).DistanceTo(locus(ub2, vb2));\n"
new = '''            // A pole or other point where the tangent plane is undefined is not a tear.
            if (!regular(ua, va) || !regular(ub2, vb2)) continue;
            const double gap = locus(ua, va).DistanceTo(locus(ub2, vb2));
'''
assert old in s
s = s.replace(old, new)
old = "    auto locus = [&](double u, double v) { return PointAt(u, v) + distance * NormalAt(u, v); };\n"
new = '''    auto locus = [&](double u, double v) { return PointAt(u, v) + distance * NormalAt(u, v); };
    auto regular = [&](double u, double v) {
      ON_3dPoint pt;
      ON_3dVector su, sv;
      if (!surface_.Ev1Der(u, v, pt, su, sv)) return false;
      const double e = su * su, g = sv * sv, f = su * sv;
      return e > 0.0 && g > 0.0 && (e * g - f * f) > 1e-10 * e * g;
    };
'''
assert old in s
s = s.replace(old, new)
open(p, 'w').write(s)
print('ok')
