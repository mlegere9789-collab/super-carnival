import sys
root = sys.argv[1]
p = root + '/include/dino8/kernel/subd.h'
s = open(p).read()
s = s.replace('''// One edge's current sharpness state, from SubD::EdgeSharpnessAt()''', '''// What SubD::ToNurbsPatchesToTolerance() measured and decided.
struct SubDFitReport {
  // True iff `max_deviation <= tolerance` at the reported level (the patches
  // are returned only in that case; on false the returned vector is empty
  // and `reason` says why).
  bool converged = false;
  double tolerance = 0.0;           // the requested fit tolerance (model units)
  double max_deviation = 0.0;       // worst sampled distance, over the IRREGULAR patches of the final level, from a patch sample to the limit surface (see ToNurbsPatchesToTolerance)
  int levels_used = 0;              // Catmull-Clark subdivisions applied to the working copy before the patches were cut (0 = the cage as given)
  int patches = 0;                  // patches at the final level (one per face)
  int exact_patches = 0;            // regular faces: the exact limit patch, deviation 0 by construction, not sampled
  int measured_patches = 0;         // irregular (Coons) patches whose deviation was sampled
  int samples_per_patch = 0;        // (n+1)^2 grid samples per measured patch
  int reference_levels = 0;         // extra subdivisions of the limit-point reference mesh used as the distance oracle
  std::vector<double> deviation_per_level;  // max_deviation measured at each level tried (-1 for a level skipped by the face budget)
  std::string reason;               // empty when converged; otherwise why not
};

// One edge's current sharpness state, from SubD::EdgeSharpnessAt()''', 1)
s = s.replace('''  std::vector<SubDNurbsPatch> ToNurbsPatchesWatertight(SubDWatertightReport* report = nullptr) const;
''', '''  std::vector<SubDNurbsPatch> ToNurbsPatchesWatertight(SubDWatertightReport* report = nullptr) const;

  // Watertight SubD -> NURBS conversion with a MEASURED fit tolerance.
  // Works on a copy (this SubD is untouched): starting from the cage as
  // given (Subdivide(1) first if any face is not a quad), it builds
  // ToNurbsPatchesWatertight() patches, measures how far the irregular
  // (Coons, `exact == false`) patches lie from the true Catmull-Clark
  // limit surface, and if the worst measured deviation exceeds `tolerance`
  // Subdivide(1)s the copy and tries again, up to `max_levels` extra
  // levels or `face_budget` faces (whichever binds first). Regular faces
  // keep their exact limit patch (deviation 0, not sampled).
  // Measurement: each irregular patch is sampled on an (n+1)x(n+1) grid
  // (n = 8) and every sample's distance to a REFERENCE mesh is taken via a
  // MeshClosestPointIndex. The reference mesh is the working copy
  // subdivided up to 3 further times whose vertices are moved to their
  // EXACT limit points (ON_SubDVertex::SurfacePoint, crease and corner
  // aware), so it is a polyhedral approximation of the limit surface
  // itself whose own sag shrinks 4x per level. HONEST LIMITS: the figure
  // is a sampled, one-sided distance (patch -> surface; the corner
  // coincidence of the watertight construction is what rules out an
  // uncovered region), measured to a reference whose own sag is small but
  // not certified, so it is a measurement, not a proof; the returned
  // patches always are the watertight set (shared edge curves are
  // bit-identical, so they join edge-matched into a closed polysurface on
  // a closed SubD). On non-convergence the returned vector is EMPTY and
  // `report->reason` states why (tolerance not met within the level or
  // face budget, with the best deviation reached) - never a silently
  // looser result. Throws std::invalid_argument for a non-finite or
  // non-positive `tolerance`, a negative `max_levels` or a non-positive
  // `face_budget`; std::runtime_error for an empty SubD.
  std::vector<SubDNurbsPatch> ToNurbsPatchesToTolerance(double tolerance, SubDFitReport* report = nullptr,
                                                        int max_levels = 5, int face_budget = 20000) const;
''', 1)
if '#include <string>' not in s:
    s = s.replace('#include <utility>', '#include <string>\n#include <utility>', 1)
open(p, 'w').write(s)

p = root + '/src/subd.cpp'
s = open(p).read()
impl = open(sys.argv[2]).read()
idx = s.rindex('}  // namespace dino8::kernel')
s = s[:idx] + impl + '\n' + s[idx:]
open(p, 'w').write(s)
