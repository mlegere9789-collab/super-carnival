import sys
root = sys.argv[1]
p = root + '/src/curve.cpp'
s = open(p).read()

def rep(old, new, count_ok=1):
    global s
    assert s.count(old) >= 1, old[:80]
    s = s.replace(old, new)

rep("""Result OffsetLineAlongNormal(const Point3d& p0, const Point3d& p1, const Vector3d& normal,
                              double distance, NurbsCurve& out) {
  Vector3d dir = p1 - p0;
  if (!dir.Unitize()) return Result::Failed;
  Vector3d offset_dir = ON_CrossProduct(dir, normal);
  if (!offset_dir.Unitize()) return Result::Failed;""", """Result OffsetLineAlongNormal(const Point3d& p0, const Point3d& p1, const Vector3d& normal,
                              double distance, NurbsCurve& out, std::string* why = nullptr) {
  Vector3d dir = p1 - p0;
  if (!dir.Unitize()) {
    if (why != nullptr) *why = "degenerate line: zero length";
    return Result::Failed;
  }
  Vector3d offset_dir = ON_CrossProduct(dir, normal);
  if (!offset_dir.Unitize()) {
    if (why != nullptr) *why = "offset direction degenerates: the line is parallel to the plane normal, so line x normal vanishes";
    return Result::Failed;
  }""")

rep("""Result OffsetGeneralAlongNormal(const NurbsCurve& curve, const Vector3d& normal, double distance,
                                 double tol, NurbsCurve& out) {""", """Result OffsetGeneralAlongNormal(const NurbsCurve& curve, const Vector3d& normal, double distance,
                                 double tol, NurbsCurve& out, std::string* why = nullptr) {
  auto refuse = [&](const char* msg) {
    if (why != nullptr) *why = msg;
    return Result::Failed;
  };""")

rep("""  offset_points.reserve(static_cast<size_t>(n) + 1);
  for (int i = 0; i <= n; ++i) {
    const double t = dom.min + (dom.max - dom.min) * i / n;
    Vector3d offset_dir = ON_CrossProduct(curve.TangentAt(t), normal);
    if (!offset_dir.Unitize()) return Result::Failed;  // tangent parallel to normal here
""", """  offset_points.reserve(static_cast<size_t>(n) + 1);
  Vector3d previous_dir;
  for (int i = 0; i <= n; ++i) {
    const double t = dom.min + (dom.max - dom.min) * i / n;
    Vector3d offset_dir = ON_CrossProduct(curve.TangentAt(t), normal);
    // Tangent parallel to the plane normal: no offset direction exists.
    // Also refused when tangent x normal is merely tiny (sine of the angle
    // below 1e-3) or when the unit direction jumps by more than 90 degrees
    // between consecutive samples: that is the direction field flipping
    // sign THROUGH a parallel point between two samples (e.g. a plane whose
    // normal lies in the circle's own plane), which would otherwise produce
    // a zig-zag "offset" that is no offset at all.
    if (!offset_dir.Unitize() || ON_CrossProduct(curve.TangentAt(t), normal).Length() < 1e-3 * normal.Length()) {
      return refuse(
          "offset direction degenerates: the curve's tangent is parallel (or nearly parallel) to the plane "
          "normal at some parameter, so tangent x normal vanishes and no offset direction exists");
    }
    if (i > 0 && ON_DotProduct(previous_dir, offset_dir) < 0.0) {
      return refuse(
          "offset direction flips: the curve's tangent crosses the plane normal's direction between samples "
          "(the plane normal lies in the curve's own plane), so tangent x normal changes sign and the offset "
          "locus is discontinuous");
    }
    previous_dir = offset_dir;
""")

rep("""      if (inward_component >= 1.0 / kappa) return Result::Failed;  // folds through its own center of curvature""", """      if (inward_component >= 1.0 / kappa) {
        return refuse(
            "curvature fold: |distance| reaches the local radius of curvature, so the offset folds through "
            "its own center of curvature");
      }""")

rep("""    if (NurbsCurve::FitLeastSquares(offset_points, curve.Degree(), cv_count, fitted) != Result::Ok) {
      return Result::Failed;
    }""", """    if (NurbsCurve::FitLeastSquares(offset_points, curve.Degree(), cv_count, fitted) != Result::Ok) {
      return refuse("offset fit failed: the least-squares refit could not be solved");
    }""")

rep("""    if (worst <= tol) {
      out = fitted;
      return Result::Ok;
    }
    if (cv_count >= max_cv_count) return Result::Failed;  // tolerance unreachable even at the maximum feasible count""", """    if (worst <= tol) {
      out = fitted;
      return Result::Ok;
    }
    best_worst = std::min(best_worst, worst);
    if (cv_count >= max_cv_count) {
      if (why != nullptr) {
        *why = "tolerance not reachable: the offset needs more control points than the sample ceiling (" +
               std::to_string(max_cv_count) + ") can resolve at tolerance " + std::to_string(tol) +
               "; the best fit reached a deviation of " + std::to_string(best_worst) +
               ". No offset is returned rather than an out-of-tolerance fit";
      }
      return Result::Failed;
    }""")

rep("""  NurbsCurve fitted;
  for (;;) {
    if (NurbsCurve::FitLeastSquares(offset_points""", """  NurbsCurve fitted;
  double best_worst = std::numeric_limits<double>::infinity();
  for (;;) {
    if (NurbsCurve::FitLeastSquares(offset_points""")

hdr = """  if (refusal_reason != nullptr) refusal_reason->clear();
  auto refuse = [&](const char* msg) {
    if (refusal_reason != nullptr) *refusal_reason = msg;
    return Result::Failed;
  };
  if (!ON_IsValid(distance)) {"""
rep("""Result NurbsCurve::OffsetInPlane(double distance, NurbsCurve& out, double tolerance,
                                  CurveOffsetCornerStyle corner_style) const {
  if (!ON_IsValid(distance)) {""", """Result NurbsCurve::OffsetInPlane(double distance, NurbsCurve& out, double tolerance,
                                  CurveOffsetCornerStyle corner_style, std::string* refusal_reason) const {
""" + hdr)
rep("""Result NurbsCurve::OffsetInPlane(const ON_Plane& plane, double distance, NurbsCurve& out, double tolerance,
                                  CurveOffsetCornerStyle corner_style) const {
  if (!ON_IsValid(distance)) {""", """Result NurbsCurve::OffsetInPlane(const ON_Plane& plane, double distance, NurbsCurve& out, double tolerance,
                                  CurveOffsetCornerStyle corner_style, std::string* refusal_reason) const {
""" + hdr)
rep("""  if (!curve_.IsPlanar(&plane, tol)) {
    return Result::Failed;
  }

  if (distance == 0.0) {""", """  if (!curve_.IsPlanar(&plane, tol)) {
    return refuse("curve is not planar within the tolerance, so it has no single plane to offset in");
  }

  if (distance == 0.0) {""")
rep("return OffsetLineAlongNormal(curve_.PointAtStart(), curve_.PointAtEnd(), plane.zaxis, distance, out);", "return OffsetLineAlongNormal(curve_.PointAtStart(), curve_.PointAtEnd(), plane.zaxis, distance, out, refusal_reason);")
rep("""      if (polyline_result == Result::Ok) out = polyline_out;
      return polyline_result;""", """      if (polyline_result != Result::Ok) {
        return refuse(
            "polyline offset refused: a zero-length edge, an edge parallel to the plane normal, a near-180-degree "
            "fold, or a self-crossing offset polygon");
      }
      out = polyline_out;
      return polyline_result;""")
rep("""      if (!offset_dir.Unitize() || !radial.Unitize()) return Result::Failed;
      const double sign = OffsetSignAlong(offset_dir, radial);
      const double new_radius = arc.radius + sign * distance;
      if (!(new_radius > 0.0)) return Result::Failed;
      const ON_Circle new_circle(arc.plane, new_radius);
      const ON_Arc new_arc(new_circle, arc.DomainRadians());
      ON_NurbsCurve nc;
      if (new_arc.GetNurbForm(nc) == 0) return Result::Failed;""", """      if (!offset_dir.Unitize() || !radial.Unitize()) return refuse("degenerate arc: offset direction undefined");
      const double sign = OffsetSignAlong(offset_dir, radial);
      const double new_radius = arc.radius + sign * distance;
      if (!(new_radius > 0.0)) return refuse("arc offset radius would reach zero or below (curvature fold)");
      const ON_Circle new_circle(arc.plane, new_radius);
      const ON_Arc new_arc(new_circle, arc.DomainRadians());
      ON_NurbsCurve nc;
      if (new_arc.GetNurbForm(nc) == 0) return refuse("arc offset could not be built");""")
rep("""        if (!offset_dir.Unitize() || !radial.Unitize()) return Result::Failed;
        const double sign = OffsetSignAlong(offset_dir, radial);
        const double new_radius = arc.radius + sign * distance;
        if (!(new_radius > 0.0)) return Result::Failed;
        const ON_Circle new_circle(arc.plane, new_radius);
        const ON_Arc new_arc(new_circle, arc.DomainRadians());
        ON_NurbsCurve nc;
        if (new_arc.GetNurbForm(nc) == 0) return Result::Failed;""", """        if (!offset_dir.Unitize() || !radial.Unitize()) return refuse("degenerate arc: offset direction undefined");
        const double sign = OffsetSignAlong(offset_dir, radial);
        const double new_radius = arc.radius + sign * distance;
        if (!(new_radius > 0.0)) return refuse("arc offset radius would reach zero or below (curvature fold)");
        const ON_Circle new_circle(arc.plane, new_radius);
        const ON_Arc new_arc(new_circle, arc.DomainRadians());
        ON_NurbsCurve nc;
        if (new_arc.GetNurbForm(nc) == 0) return refuse("arc offset could not be built");""")
rep("return OffsetGeneralAlongNormal(*this, plane.zaxis, distance, tol, out);", "return OffsetGeneralAlongNormal(*this, plane.zaxis, distance, tol, out, refusal_reason);")
open(p, 'w').write(s)

h = root + '/include/dino8/kernel/curve.h'
t = open(h).read()
a = """  Result OffsetInPlane(double distance, NurbsCurve& out, double tolerance = -1.0,
                       CurveOffsetCornerStyle corner_style = CurveOffsetCornerStyle::Sharp) const;"""
assert a in t
t = t.replace(a, """  //
  // `refusal_reason` (optional, default null): on `Result::Failed` receives
  // why (cleared on success), `out` untouched. Distinct causes: not planar,
  // arc radius reaching zero, offset direction degenerate (tangent parallel
  // to the plane normal, or flipping sign between samples), curvature fold,
  // and "tolerance not reachable" (with the best deviation reached).
  Result OffsetInPlane(double distance, NurbsCurve& out, double tolerance = -1.0,
                       CurveOffsetCornerStyle corner_style = CurveOffsetCornerStyle::Sharp,
                       std::string* refusal_reason = nullptr) const;""")
b = """  Result OffsetInPlane(const ON_Plane& plane, double distance, NurbsCurve& out, double tolerance = -1.0,
                       CurveOffsetCornerStyle corner_style = CurveOffsetCornerStyle::Sharp) const;"""
assert b in t
t = t.replace(b, """  // `refusal_reason` - see the other overload; also set when the offset
  // direction `TangentAt(t) x plane.zaxis` is degenerate or flips sign
  // (the plane normal lies in the curve's own plane).
  Result OffsetInPlane(const ON_Plane& plane, double distance, NurbsCurve& out, double tolerance = -1.0,
                       CurveOffsetCornerStyle corner_style = CurveOffsetCornerStyle::Sharp,
                       std::string* refusal_reason = nullptr) const;""")
open(h, 'w').write(t)
