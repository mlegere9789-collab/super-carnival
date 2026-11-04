p = '/home/user/miniature-pancake/.claude/worktrees/agent-a1461cbbcbfc614b8/dino8-app/src/commands/cmd_solidtools.cpp'
B = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/csk_builder.inc'
t = open(p).read()
b = open(B).read()
hdr = '// ---------------------------------------------------------------------------\n// CountersinkHole / CounterboreHole: EXACT analytic hole features in a plate.'
assert t.count(hdr) == 1
t = t.replace(hdr, b + hdr)
a = t.index('    // Build and seal.')
e = t.index('    if (out.m_F.Count() == 0 || !out.IsSolid() || !out.IsValid())')
new = '''    // Build the plate with its hole directly from exact faces.
    prism::Prism pr;
    std::string why;
    bool not_prism = false;
    if (!prism::Recognize(b, pr, why, not_prism)) { ctx.Warn(label + ": refused - object " + Id(id) + " is not a plain right-prism plate (" + why + "); only a flat plate with straight or round sides and no other holes is supported"); continue; }
    const bool from_top = nout * pr.n > 0;
    if (std::fabs(pr.H - T) > 10 * tol) { ctx.Warn(label + ": refused - the plate thickness could not be read consistently"); continue; }
    const ON_3dVector ev = entry - pr.O;
    const prism::V2 hc{ev * pr.X, ev * pr.Y};
    const double zfar = through ? T : depth;
    std::vector<std::pair<double, double>> hprof;
    if (sink) hprof = {{Rc, 0.0}, {r, cone_d}, {r, zfar}};
    else hprof = {{Rc, 0.0}, {Rc, cb_depth}, {r, cb_depth}, {r, zfar}};
    std::optional<ON_Brep> built = BuildProfiledHolePlate(pr, hc, from_top, hprof, !through, why);
    if (!built) { ctx.Warn(label + ": refused - the exact faces did not assemble: " + why); continue; }
    ON_Brep out = *built;
'''
t = t[:a] + new + t[e:]
t = t.replace('sealed Boolean)");', 'built from exact faces)");')
t = t.replace('#include "dino8/kernel/boolean_general.h"\n', '#include "commands/prism_solid.h"\n', 1)
open(p, 'w').write(t)
print('ok')
