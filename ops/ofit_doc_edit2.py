p = '/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel/include/dino8/kernel/surface.h'
s = open(p).read()
old = "compatibility is the reason it exists (Brep::Thicken() and the shell\n  //    side walls rely on two offsets of one surface sharing a control net),"
new = "compatibility is the reason it exists (Brep::Thicken() builds its ruled\n  //    side walls between isocurves of two offsets of one surface, which\n  //    works because they share a control net and knots),"
assert old in s
s = s.replace(old, new)
old = '''  // WHY (cleared on success), and `out` is left untouched. Three distinct
  // causes are reported: "curvature fold" (|distance| reaches the local
  // radius of curvature), "singular surface" (zero-area / direction-
  // dependent normal, e.g. a cone apex), and "tolerance not reachable"
  // (the fit needs more control points than the sample-grid ceiling can
  // resolve at the requested tolerance, with the best deviation reached).'''
new = '''  // WHY (cleared on success), and `out` is left untouched. Four distinct
  // causes are reported: "curvature fold" (|distance| reaches the local
  // radius of curvature), "singular surface" (zero-area / direction-
  // dependent normal, e.g. a cone apex), "tolerance not reachable ... torn"
  // (the exact parallel surface has a gap across a G1-broken knot line that
  // is more than twice the tolerance; the gap and the smallest reachable
  // tolerance are stated), and "tolerance not reachable" (the adaptive fit
  // could not split any further at the sample density, or stopped improving,
  // before reaching the requested tolerance; the best deviation is stated).'''
assert old in s
s = s.replace(old, new)
open(p, 'w').write(s)
print('ok')
