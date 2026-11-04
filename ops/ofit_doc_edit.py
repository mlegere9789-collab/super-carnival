p = '/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel/include/dino8/kernel/surface.h'
s = open(p).read()

old = '''  // surface to that sampled locus with more control points - repeating
  // with the control count doubled in each direction (independently, U
  // and V) until the measured worst-case deviation is within `tolerance`
  // or a sample-grid-limited ceiling is reached.
  //
  // The refit itself reuses Rebuild()'s own machinery (surface_edit.cpp):
  // the identical row-then-column global tensor-product least-squares
  // solve (Piegl & Tiller A9.7), applied here to the sampled OFFSET
  // locus instead of to this surface's own points. Consequences that
  // follow directly from reusing that machinery, exactly as Rebuild()
  // documents for itself: the result is always a new NON-rational
  // surface (never an edited copy of this surface's own, possibly
  // rational, control net), of this surface's own degree in each
  // direction over the same domain, with its four corners interpolated
  // exactly.
'''
new = '''  // surface to that sampled locus with more control points, put where the
  // measured error needs them, until the measured worst-case deviation is
  // within `tolerance` or no further refinement can help.
  //
  // The fit is a row-then-column global tensor-product least-squares solve
  // (Piegl & Tiller A9.7) of the sampled OFFSET locus, with the normal
  // equations factorised once per direction. The result is always a new
  // NON-rational surface (never an edited copy of this surface's own,
  // possibly rational, control net) over the same domain, with its four
  // corners interpolated exactly, of degree max(this surface's degree, 3) in
  // each direction (a quadratic source is fitted by a cubic: the offset
  // locus is smooth but not a low-degree polynomial, and the higher degree
  // reaches the same tolerance with far fewer control points).
  //
  // Where the knots go: the fit starts from this surface's own distinct
  // interior knots, each with the multiplicity that gives the continuity the
  // TRUE offset has there (the offset P + d*N has one derivative less than
  // the source, so a C^(p-m) source knot becomes a C^(p-m-1) knot) - which
  // stops the fit paying first-order error at every source knot. It then
  // repeats: measure the deviation on a verification grid twice as fine as
  // the fit samples, find the knot spans in U and in V whose measured error
  // is among the largest, and bisect only those (the sample grid is
  // densified, at most twice, when spans get as narrow as it can support).
  // Uniform doubling of the whole control net, which this replaces, took e.g.
  // a 4x4 bump to 64 x 64 control points at 1e-5; this reaches the same
  // tolerance with 34 x 34 (measured: offset_fit_cost_tests).
  //
  // Torn offsets: if this surface's tangent plane jumps across a knot line (a
  // G1 break, e.g. one control point of a smooth rational patch moved), the
  // true parallel surface is torn there by about |distance| times the normal
  // turn, and no continuous surface is nearer than half that gap to both
  // sides. That is measured directly on the exact locus either side of every
  // source knot and, when half the gap exceeds `tolerance`, refused up front
  // with the gap, the knot line and the smallest reachable tolerance (the
  // refusal says "tolerance not reachable" and names the tear, not a
  // control-point ceiling).
'''
assert old in s
s = s.replace(old, new)

old2 = '''  // `tolerance` (default `<= 0`, meaning `tolerance::DistanceForSize()`
  // of this surface's bounding-box diagonal) sets the curvature-guard
  // sampling density via SuggestedDivisions(); it does not affect the
  // per-control-point translation itself. Throws std::invalid_argument
  // if `distance` isn't finite; `distance == 0.0` returns an exact copy.
'''
new2 = '''  // `tolerance` (default `<= 0`, meaning `tolerance::DistanceForSize()`
  // of this surface's bounding-box diagonal) sets the curvature-guard
  // sampling density via SuggestedDivisions(); it does not affect the
  // per-control-point translation itself. Throws std::invalid_argument
  // if `distance` isn't finite; `distance == 0.0` returns an exact copy.
  //
  // What this method promises, precisely (tested against the unified
  // Offset() in offset_fit_cost_tests):
  //  - It is NOT tolerance-controlled and does not delegate to Offset():
  //    `tolerance` never changes the surface it returns. Use Offset() (or
  //    OffsetRefit()) when a deviation bound matters.
  //  - The result has exactly this surface's control-net size, degrees,
  //    knots and weights; only the control points move. That structural
  //    compatibility is the reason it exists (Brep::Thicken() and the shell
  //    side walls rely on two offsets of one surface sharing a control net),
  //    and the reason it is kept as it is rather than replaced by a refit,
  //    whose control net differs from the source's.
  //  - Because the control points move by `distance` times a distance-
  //    independent vector, result(u, v) = this(u, v) + distance * F(u, v)
  //    for ONE vector field F (the control-point normals blended by the
  //    basis). The deviation from the true offset this(u, v) + distance *
  //    NormalAt(u, v) is therefore exactly |distance| * |F - NormalAt|: linear
  //    in `distance` and symmetric in its sign. Measured: 0.085 for a 4x4
  //    bump at 0.2, 0.0145 for a wavy 6x5 patch at 0.12, 0.013 for a
  //    rational 3x3 patch at 0.1, 0.05 for a closed elliptical tube at 0.2,
  //    where the unified Offset() at 1e-4 is within 2.2e-5.
  //  - The sign of `distance` follows this surface's own NormalAt(), as
  //    Offset() does; the same fold guard refuses the same distances; a
  //    surface closed in a direction stays closed. It is exact for a plane.
'''
assert old2 in s
s = s.replace(old2, new2)
open(p, 'w').write(s)
print('ok')
