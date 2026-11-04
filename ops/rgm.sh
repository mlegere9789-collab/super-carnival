#!/usr/bin/env bash
# Headless functional QC for Dino 8: runs a command script through the real
# app under Xvfb and checks the resulting history/object counts.
set -euo pipefail
# Hundreds of checks below are `echo "$BIG" | grep -q PATTERN`. GitHub's
# runner starts this script with SIGPIPE ignored, so when grep exits on its
# first match a still-writing echo gets EPIPE ("echo: write error: Broken
# pipe") instead of dying silently, and under `pipefail` that turned a
# MATCHED check into a FAIL at random (the e7b5a52c Linux run). An echo's
# write status must never decide a check: only grep's does.
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE=/home/user/miniature-pancake/dino8-app/tests
BIN="${1:-$HERE/../build/Dino8}"
TMP="$(mktemp -d)"
# The real, OS-native form of $TMP - needed wherever a path is embedded as
# literal TEXT inside a script file the app itself parses (Save/Open/Export/
# Import command lines), as opposed to a bash-level file operation or a
# command-line argument handed straight to $BIN. Bash's own POSIX-path file
# ops (mkdir/cat/grep/rm) and argv passed directly to a spawned native
# process both get Git-for-Windows' automatic MSYS<->Windows path
# translation; a path baked into a script file's own bytes gets none of
# that; the app's own file I/O then tries to open "/tmp/xxx" literally,
# which Windows resolves as "current drive's root\tmp\xxx" - never the
# real temp directory - and every Save/Export/Import in that script fails.
# cygpath -m gives the same drive-letter path with forward slashes (valid
# to Win32 file APIs, and avoids backslash-escaping issues in sed/heredoc
# text); on Linux/macOS (no cygpath) this is just $TMP again, a no-op.
if command -v cygpath >/dev/null 2>&1; then TMPW="$(cygpath -m "$TMP")"; else TMPW="$TMP"; fi
# Same reasoning as TMPW above, for $HERE (this file's own directory):
# a handful of sed substitutions below bake $HERE into a *.dflow/script
# path that becomes literal TEXT inside a generated script file (an
# @DINO8ROOT@/@TREEFILE@/@SOLVERFILE@/@GEOMFILE@ token, not a bash-level
# file argument), so it needs the same OS-native form.
if command -v cygpath >/dev/null 2>&1; then HEREW="$(cygpath -m "$HERE")"; else HEREW="$HERE"; fi
# Isolate settings so persisted toggles (Ortho, snaps, theme) from earlier runs cannot leak into the checks.
export XDG_CONFIG_HOME="$TMPW/config"
mkdir -p "$XDG_CONFIG_HOME"
# Windows (Git-Bash on the CI runner): the app's config directory there is
# %APPDATA%\Dino8 (app/Settings.h - XDG_CONFIG_HOME is a freedesktop
# convention the app rightly does not consult on Windows), so the export
# above alone isolated nothing on that platform: every script shared, and
# persisted into, the runner's real %APPDATA%\Dino8, and the one check that
# reads the config directory back off disk (plugin_reviews.json, below)
# looked in a directory the app never wrote to. Pointing APPDATA at the
# same per-run scratch directory gives Windows exactly the isolation
# XDG_CONFIG_HOME gives Linux. Nothing else this script runs (the app, curl,
# python3's stdlib) keys off APPDATA. CONFIG_DIR is the directory the app
# actually writes on the current platform, for the checks that read it.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; *) IS_WINDOWS=0 ;; esac
if [ "$IS_WINDOWS" = 1 ]; then
  export APPDATA="$XDG_CONFIG_HOME"
  CONFIG_DIR="$APPDATA/Dino8"
else
  CONFIG_DIR="$XDG_CONFIG_HOME/dino8"
fi
trap 'rm -rf "$TMP"' EXIT

cat > "$TMPW/script.txt" <<EOS
Box 0,0,0 20,20,0 10
Sphere 10,10,10 8
SelNone
SelID 1
BooleanDifference
SelID 2
Enter
SelAll
Volume
SelNone
Circle 40,0,0 5
SelCrv
ExtrudeCrv 12
SelAll
Save $TMPW/test.3dm
New
Open $TMPW/test.3dm
SelAll
List
Undo
Redo
Line 0,0,0 10,10,0
SelCrv
Length
SelAll
Export $TMPW/test.obj
SelNone
Cylinder 60,0,0 5 15
SelLast
What
ToolbarAddCommand Fillet
ToolbarAddCommand NotARealCommandXYZ
ToolbarAddCommand b
EOS

if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  OUT="$(timeout 900 "$BIN" --smoke 200 --script "$TMPW/script.txt" 2>&1)" || { echo "$OUT"; echo "FAIL: app exited non-zero"; exit 1; }
else
  OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$TMPW/script.txt" 2>&1)" || { echo "$OUT"; echo "FAIL: app exited non-zero"; exit 1; }
fi
echo "$OUT" | grep "^smoke:" || { echo "$OUT"; echo "FAIL: no smoke line"; exit 1; }
fail=0
# On a FAIL, show what the app actually printed for the line the check was
# looking for, so a platform-specific value difference (e.g. MSVC vs GCC
# producing "Volume = 199.9999" instead of "Volume = 200") is visible in the
# CI log directly instead of only "FAIL <description>". The expected pattern
# is trimmed at its first digit to get a stable prefix ("Volume = ", "CV[0] ",
# "Shell: thickness "), and every output line carrying that prefix is echoed
# (capped, so a runaway match can't flood the log). Diagnostic only - never
# changes pass/fail.
near() {
  local out="$1" pat="$2" prefix
  prefix="${pat%%[0-9]*}"
  prefix="${prefix%%\\*}"
  prefix="${prefix%%[\[\]\(\)\.\*\^\$]*}"
  # A pattern with no digits/regex-special char to trim at (e.g. a plain
  # "Command: installed X" literal) leaves prefix == pat, which used to skip
  # printing entirely - a self-grep for the exact string that already failed
  # grep -q is pointless, but giving up there means a command that printed
  # nothing AT ALL (or printed an error instead of its success line) shows
  # no actual output here either, just "expected:" with nothing to compare
  # against. Fall back to the pattern's own first word (most of this app's
  # commands print "CommandName: <result or error>", so even an error line
  # usually still starts with it) so at least something nearby surfaces.
  if [ "$prefix" == "$pat" ]; then prefix="${pat%% *}"; fi
  echo "     expected: $pat"
  if [ -n "$prefix" ] && [ "$prefix" != "$pat" ]; then
    echo "$out" | grep -F -- "$prefix" | head -16 | sed 's/^/     actual:   /' || true
  fi
}
# Fillet family: FilletEdge/ChamferEdge exact box-corner trims, FilletSrf, BlendEdge,
# MatchSrf, SplitFace, MergeFaces, ConnectSrf, surface/surface and curve/surface
# Intersect (see fillet_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FL="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/fillet_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: fillet script exited non-zero"; exit 1; }
else
  FL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/fillet_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: fillet script exited non-zero"; exit 1; }
fi
flcheck() { if echo "$FL" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FL" "$1"; fail=1; fi; }
flcheck "FilletEdge: edge 10 of object 1 replaced with an exact fillet (radius 2)" "FilletEdge trimmed the box corner into a real B-rep, not a mesh fallback"
flcheck "Volume = 991.4 cubic" "a 10x10x10 box minus a r=2 edge fillet has volume 1000 - 10*4*(1-pi/4) = 991.42"
flcheck "ChamferEdge: edge 10 of object 2 replaced with an exact chamfer (radius 3)" "ChamferEdge trimmed the box corner exactly"
flcheck "Volume = 955 cubic" "a 10x10x10 box minus a 3x3 edge chamfer has volume 1000 - 10*3^2/2 = 955 exactly"
flcheck "FilletSrf: built between object 4 and 6, radius 2; both surfaces trimmed" "FilletSrf trimmed two independently-picked planar surfaces"
flcheck "Area = 31.41 square" "the r=2 fillet's quarter-cylinder lateral area is (pi/2)*2*10 = 31.42"
flcheck "ChamferSrf: faces .* and .* of object .* replaced with an exact chamfer (distance 3)" "ChamferSrf's two-face-pick UI now reaches kernel::ChamferConvexEdge (the same exact construction ChamferEdge's own path uses) when both picks land on the same solid's own adjacent planar faces, instead of always building the approximate RuledBetween ruled surface"
flcheck "Volume = 955 cubic" "a 10x10x10 box minus a 3x3 ChamferSrf chamfer has the identical exact volume as the plain ChamferEdge case above: 1000 - 10*3^2/2 = 955"
flcheck "BlendEdge: edge 10 of object .* trimmed and joined into the polysurface (Continuity=Tangency)" "BlendEdge now real-trims both adjacent planar faces and stitches the G1 blend in as a genuine third face, closing PARITY_MAP.md's own 'Edge blend trimmed and joined into the polysurface' gap - fixing a real, previously-undiscovered degeneracy along the way: the un-offset construction this replaced fed BuildBlendSurfaceG1 the SAME shared edge as both its 'face A' and 'face B' boundary, collapsing every row to one point (confirmed directly, not assumed - the resulting surface sampled to the identical 3D point everywhere), an invisible, zero-area patch rather than a real blend"
flcheck "7 faces, 15 edges, closed solid" "BlendEdge's own trim-and-join result is a genuine closed solid (6 box faces - 2 trimmed-in-place + the new blend face = 7), not three independent disconnected pieces"
flcheck "Volume = 994.5 cubic" "the box's own corner material actually removed by the blend (a real, reproducible number - no closed form for an arbitrary Hermite blend's own removed volume, the same 'no closed form, check the real number' convention this file's own FilletSrf/Area checks already use), stable across repeated runs"
flcheck "MatchSrf: 2 boundary control point.s. moved to position on the target curve" "MatchSrf moved a plane's edge onto a target line"
flcheck "MatchSrf: 2 boundary control point.s. moved to position on the target curve" "MatchSrf moved a plane's edge onto a target line"
flcheck "MatchSrf: exact edge match (G1) to the target surface, max position error 0, max tangent error 0" "MatchSrf against a target *surface* edge now uses the kernel's exact NurbsSurface::MatchEdge() (self-checked by evaluation, both residuals genuinely ~0), not the app's older per-control-point loop that only assumed a shared parameterization"
flcheck "degree 2 x 1, CVs 3 x 2" "the matched floor plane's real G1 bend toward the box's vertical front face: degree elevated 1->2 and one control point added in the edge-crossing direction to hold position+tangent rows, the other direction (degree 1, 2 CVs) untouched"
# MatchSrf Curvature (G2): closes PARITY_MAP.md's surfaceops "Kernel
# MatchEdge() - wire G2 into MatchSrf" gap - previously only Position/
# Tangency reached kernel::NurbsSurface::MatchEdge(); Curvature was wired
# but unreachable from any app command.
flcheck "MatchSrf: exact edge match (G2) to the target surface, max position error 0, max tangent error 0, max curvature error 0" "MatchSrf's new Curvature option reaches kernel::NurbsSurface::MatchEdge()'s own G2 level for the first time, matched against a genuinely curved quarter-cylinder panel (not a trivial zero-curvature planar target) with every residual self-checked at ~0"
flcheck "degree 1 x 3, CVs 2 x 4" "the matched flat panel's real G2 bend toward the quarter-cylinder's own curvature: degree elevated 1->3 and two control points added in the edge-crossing direction to hold position+tangent+curvature rows, the other direction (degree 1, 2 CVs) untouched"
flcheck "MatchSrf: Curvature continuity needs an exact edge match against a target SURFACE edge (kernel::NurbsSurface::MatchEdge) - the exact match failed (periodic edge, or the target's degree is too low to carry a curvature row); nothing was changed" "MatchSrf's Curvature option fails closed, not silently downgraded to G1/G0, against a target whose own degree structurally can't carry a curvature row (two flat planar faces)"
flcheck "MatchSrf: Curvature continuity needs an exact edge match against a target SURFACE edge (kernel::NurbsSurface::MatchEdge) - a target curve has no curvature-match fallback; nothing was changed" "MatchSrf's Curvature option fails closed against a target CURVE too - MatchEdge() only ever matches two surface edges, and the per-control-point fallback has no curvature construction at all"
flcheck "SplitFace: face 0 split into 2 surfaces along the curve's crossing" "SplitFace found a real CSX crossing of a piercing polyline (a coplanar line can't cross a flat face twice)"
flcheck "MergeFaces: 2 coplanar face.s. merged into 1" "MergeFaces recombined two joined coplanar planes"
flcheck "Area = 100 square" "the merged 5x10 + 5x10 planes have area 100"
flcheck "ConnectSrf: extended both surfaces to their real intersection curve; both surfaces trimmed to the join" "ConnectSrf found the real SSX join line between two already-touching planes"
flcheck "ConnectSrf: extended both surfaces to their real intersection curve; 1/2 surfaces trimmed (surface .*: the join curve does not reach this surface's own domain edge anywhere" "ConnectSrf's general (non-planar) trim: a real quarter-cylinder (exact rational-arc extrusion) genuinely trimmed to the SSX join curve against an oversized plane that honestly reports why IT was left untrimmed, instead of both silently falling back to Split"
flcheck " 1 faces, [0-9]* edges, open" "the cylinder's own real trim produced a single-face open B-rep (not a mesh fallback, not the untrimmed extended surface)"
flcheck "Area = 193.8 square" "the trimmed cylinder patch's real, reproducible lateral area (stable across repeated runs; not a hand-derived closed form, since ON_NurbsSurface::Extend() only continues the original arc smoothly - matching end tangent/curvature - not as an exact circle, past the original 90 degrees the join curve needed to reach the domain edge on)"
flcheck "Intersect: 1 surface intersection curve.s., 0 curve/surface point.s." "Intersect (SSX) found the crossing line of two planes meeting at a right angle"
flcheck "Intersect: 0 surface intersection curve.s., 1 curve/surface point.s." "Intersect (CSX) found where a line pierces a plane"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (variable radius: 1 at t=0, 3 at t=1 (exact))" "FilletEdge Radii= built a genuine variable-radius fillet via the exact planar closed form, not the constant-radius approximation"
flcheck "Volume = 990.8 cubic" "a 10x10x10 box minus a variable r=1->3 edge fillet now goes through kernel::FilletConvexEdgeTapered: the naive closed-form integral of a linear radius ramp with a plain quarter-circle cross-section gives 1000 - (1-pi/4)*10*(1+3+9)/3 = 990.70, but that ignores the elliptical corner-notch splice the kernel builds at each end (see TestFilletConvexEdgeTaperedClosesCornerNotch) - a genuinely different, more faithful notch than the app's old RoundFaceCorner splice - so the tessellated (tol 0.005, not exact analytic) Volume lands one display digit away, at 990.8"
flcheck "FilletSrf: built between object .* and .*, radius 1 to 2; one surface trimmed (the other could not be split)" "VariableFilletSrf built a plane+cylinder variable-radius fillet via BuildPlaneCylinderVariableFillet, not the constant-radius approximation (no 'approximate' suffix means every sample landed exactly on the plane and exactly on the cylinder); the cylinder's own full-circumference contact curve is a closed loop, which TrimBySplit's kernel::SplitFaceByCurve correctly refuses to split (a closed loop can only become an interior hole, not a two-way split), so it still falls back to left-untrimmed there - the planar cap is the one TrimWholeLoop trims"
flcheck "degree 2 x 3, CVs 3 x 33" "the plane+cylinder variable fillet lofted all 33 (samples+1) exact rows into its NURBS surface"
flcheck "VariableBlendSrf: blend surface added between object .* and .*, width 0.2 to 0.8 .Continuity=Curvature: quintic blend, cross-boundary curvature matched exactly to both surfaces." "VariableBlendSrf built a real independent blend (BuildBlendSurfaceG2, same construction as BlendSrf/BlendEdge) with a width that genuinely ramps from 0.2 to 0.8 along the rail, not the rolling-ball fillet VariableFilletSrf uses"
flcheck "degree 5 x 3, CVs 6 x 49" "VariableBlendSrf's Continuity=Curvature output is the degree-5x3 quintic-Hermite blend, the same construction BuildBlendSurfaceG2 gives BlendSrf/BlendEdge - not a rolling-ball fillet arc, and see tests/test_variable_blend.cpp for the numeric proof the width itself (measured on the constructed surface's own control points) actually varies along the rail while the G2 curvature match still holds at both ends. 49 (not the old fixed-sample 24+1=25) rows: VariableBlendSrfCommand now builds through BuildBlendSurfaceG2Adaptive (geom/BlendSurface.h) instead of a bare fixed-sample call - PARITY_MAP.md's own disclosed 'tolerance enforcement exists in the geometry library but is not yet reachable from any app command' gap for Surface-to-surface continuity blend - so this box-face-to-extracted-face pair's own real measured gap at 24 samples exceeded the scale-aware max_gap floor and the adaptive wrapper genuinely doubled to 48 (49 rows) to certify it, rather than silently accepting the coarser build's own unmeasured error the way the fixed-sample call used to"
# BlendSrf (plain, not Variable): now tries the exact kernel::NurbsSurface::
# BlendSurfaces() Hermite-skin construction FIRST, reachable because this
# fixture's two picks (the TOP edge of two separate boxes' facing
# extracted faces, 10 units apart with a real gap between them - unlike
# VariableBlendSrf's own shared-corner-edge fixture just above, where both
# rails are actually the SAME physical box edge and the exact construction
# correctly rejects it as degenerate) are both genuine isoparametric
# boundaries. One run per Continuity value on the identical two-box gap,
# so the three are directly comparable: Tangency (G1) is the degree-3
# cubic BlendCurves() itself builds per row, Curvature (G2) the degree-5
# quintic, and G3 the degree-7 septic - the genuine new capability neither
# BlendSrf nor VariableBlendSrf could reach at all before this wiring
# (BuildBlendSurfaceG1/G2 cap out at G2). All three converge at 16 rows
# (doubled once from the 8-row floor) since this is flat, simple geometry.
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=Tangency, exact kernel blend." "BlendSrf's default Continuity=Tangency now reaches the exact kernel::NurbsSurface::BlendSurfaces() construction, not the approximate BuildBlendSurfaceG1Adaptive fallback"
flcheck "degree 3 x 3, CVs 4 x 16" "BlendSrf's Continuity=Tangency (G1) output is the expected degree-3 (2*1+1) row curve, skinned over 16 rows"
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=Curvature, exact kernel blend." "BlendSrf's Continuity=Curvature now reaches the exact kernel construction too"
flcheck "degree 5 x 3, CVs 6 x 16" "BlendSrf's Continuity=Curvature (G2) output is the expected degree-5 (2*2+1) row curve - one degree past the G1 case just above, same 16-row convergence on the identical fixture"
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=G3, exact kernel blend." "BlendSrf's new Continuity=G3 option reaches kernel::NurbsSurface::BlendSurfaces()'s own continuity=3 path - unreachable from any app command before this wiring, since BuildBlendSurfaceG1/G2 cap out at G2"
flcheck "degree 7 x 3, CVs 8 x 16" "BlendSrf's Continuity=G3 output is the expected degree-7 (2*3+1) row curve - one degree past the G2 case just above, same 16-row convergence on the identical fixture"
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=G4, exact kernel blend." "BlendSrf's new Continuity=G4 option reaches kernel::NurbsSurface::BlendSurfaces()'s own continuity=4 path - the genuine new capability this round's own kernel-side pass adds, one degree past G3"
flcheck "degree 9 x 3, CVs 10 x 16" "BlendSrf's Continuity=G4 output is the expected degree-9 (2*4+1) row curve - one degree past the G3 case just above, same 16-row convergence on the identical fixture"
flcheck "FilletEdge: edge .* -- mesh fallback (exact B-rep trim unavailable here; result is an approximate mesh, not a clean B-rep)" "FilletEdge succeeded on a solid cylinder's own closed (periodic) rim edge via the mesh fallback - this used to fail unconditionally with a watertight-gap error regardless of radius (see adversarial_corpus_notes.md SS3)"
flcheck "FilletEdge: edge .* -- mesh fallback (exact B-rep trim unavailable here; result is an approximate mesh, not a clean B-rep)\$" "BuildFilletAdaptive's own offset-sampling refinement (cmd_fillet.cpp) drives this plane+cylinder pair's contact-point gap below the scale-aware tolerance floor (measured directly during development: 0.4497 unrefined -> 0.0369 at an 8x8 offset-sample grid -> 0.00309 at 16x16, well under the ~0.0245 target) - the trailing \$ anchor means this line carries NO '(surface quality: contact points off by up to ...)' qualifier, i.e. BuildFillet's own long-unenforced max_gap signal is now genuinely under control here, not just silently approximate; PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact conic fillet (rho 0.5, distance 2)" "FilletEdge's Rho option wires straight to kernel::FilletConvexEdgeConic, a genuine ellipse/parabola/hyperbola cross-section blend distinct from the default rolling-ball circular arc"
flcheck "Volume = 993.3 cubic" "a 10x10x10 box minus a rho=0.5 (exact parabola) conic edge fillet at distance 2 has volume 1000 - 2*2*sin(90deg)*10/6 = 993.3, the closed form FilletConvexEdgeConic's own doc comment derives for rho=0.5"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (RailType=DistFromEdge, distance 2)" "FilletEdge's RailType=DistFromEdge option wires straight to kernel::FilletConvexEdgeByDistanceFromEdge, the same rolling-ball circular fillet as a plain Radius= but specified as a distance-from-edge instead of the radius directly"
flcheck "Volume = 991.4 cubic" "a 10x10x10 box minus a DistFromEdge=2 edge fillet: on a box corner (dihedral 90 degrees) radius = distance*tan(45deg) = 2 exactly, the same r=2 rolling-ball fillet the very first FilletEdge case already verified, now reached via the distance-based RailType path"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (RailType=DistBetweenRails, distance 2)" "FilletEdge's RailType=DistBetweenRails option wires straight to kernel::FilletConvexEdgeByDistanceBetweenRails, the same rolling-ball circular fillet specified by the straight-line distance between the two rails instead of the radius"
flcheck "Volume = 995.7 cubic" "a 10x10x10 box minus a DistBetweenRails=2 edge fillet: radius = rail_distance/(2*cos(45deg)) gives radius^2 = 2 exactly, so removed volume = 10*2*(1-pi/4) = 4.292, leaving 1000 - 4.292 = 995.7"
flcheck "FilletEdge: 3 staged edges of object .* replaced with an exact multi-edge fillet (RailType=DistFromEdge, distance 2)" "closes PARITY_MAP.md's Blending .. chamfering Alternative blend rail types .no multi-edge/vertex-blend form. gap: FilletEdgeCommand's pending_rail_ staging now batches every RailType pick into one kernel::FilletConvexEdgesByDistanceFromEdge call, the same staging idea pending_conic_/pending_fillet_ already established, reaching that function's own m == 3 trihedral spherical-corner blend instead of rejecting the 2nd/3rd pick's own PlanarFaces() check"
flcheck "Volume = 975.4 cubic" "all 3 edges of a fresh box corner share the identical 90-degree dihedral, so DistFromEdge's own closed-form distance-to-radius conversion lands every edge on radius = 2, the identical closed solid and tessellated volume the plain multi-edge Radius=2 FilletConvexEdges case verifies elsewhere in this script"
flcheck "RemoveFillet: fillet on object .* removed, sharp edge.vertex restored" "RemoveFillet's kernel::RemoveBlend wiring inverts a plain box-corner FilletEdge, restoring the sharp edge purely from the solid's own geometry - PARITY_MAP.md's Blending .. chamfering .Blend removal . defeaturing with healing. entry's own .nothing in the app calls any of these. gap"
flcheck "Volume = 1000 cubic" "RemoveFillet's fillet round trip restores the box's own exact original volume"
flcheck "RemoveFillet: chamfer on object .* removed, sharp edge.vertex restored" "RemoveFillet's kernel::RemoveChamfer wiring inverts a plain box-corner ChamferEdge the same way, dispatched automatically since RemoveFillet tries RemoveBlend then RemoveChamfer then RemoveChamferVertex from a single picked face with no separate face-type option"
flcheck "Volume = 1000 cubic" "RemoveFillet's chamfer round trip also restores the box's own exact original volume"
flcheck "FilletVertex: convex spherical corner at vertex .* of object .* filleted (radius 2)" "FilletVertex reached kernel::FilletConvexEdges' own m==3 spherical-corner blend from a single picked vertex - PARITY_MAP.md's Blending .. chamfering .Vertex blend. entry's own previously-zero app reachability for FilletConvexEdges/FilletConcaveEdges"
flcheck "10 faces, [0-9]* edges, closed solid" "the rounded corner is a genuine closed solid: 6 planar + 3 cylindrical + 1 spherical face, matching kernel::FilletConvexEdges' own single-corner regression test"
flcheck "Volume = 975.4 cubic" "a 10x10x10 box minus one r=2 spherical vertex-blend corner: the closed form 3(1-r)r^2(1-pi/4) + r^3(1-pi/6) at r=0.2 scaled by 1000 gives 1000*(1 - 3*0.8*0.04*(1-pi/4) - 0.008*(1-pi/6)) = 975.587, but Volume tessellates the exact analytic sphere/cylinder/plane solid at a fixed 0.005 tolerance rather than measuring it exactly, and a coarse polygonal approximation of a convex curved surface always inscribes chords slightly inside the true surface, landing at 975.4"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact tapered fillet (radius 1 to 3)" "VariableFilletSrf's two-face-pick UI now reaches kernel::FilletConvexEdgeTapered (the same exact construction FilletEdge's own Radii= path uses) when both picks land on the same solid's own adjacent planar faces with r0 != r1, instead of always building the approximate BuildPlaneCylinderVariableFillet/BuildFillet loft"
flcheck "Volume = 990.8 cubic" "a 10x10x10 box minus a radius 1->3 VariableFilletSrf taper has the identical exact volume as the plain FilletEdge Radii=0:1,1:3 case above: same kernel::FilletConvexEdgeTapered construction, just reached via two picked faces instead of one picked edge"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact conic fillet (rho 0.5, distance 2)" "FilletSrf's own new Rho option (previously FilletEdgeCommand-only) wires straight to kernel::FilletConvexEdgeConic when both picks land on the same solid's own adjacent planar faces with Trim=Yes"
flcheck "Volume = 993.3 cubic" "a 10x10x10 box minus a rho=0.5 FilletSrf conic fillet at distance 2 has the identical exact volume as the plain FilletEdge Rho=0.5 case above"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact fillet (RailType=DistFromEdge, distance 2)" "FilletSrf's own new RailType option (previously FilletEdgeCommand-only) wires straight to kernel::FilletConvexEdgeByDistanceFromEdge when both picks land on the same solid's own adjacent planar faces with Trim=Yes"
flcheck "Volume = 991.4 cubic" "a 10x10x10 box minus a DistFromEdge=2 FilletSrf fillet has the identical exact volume as the plain FilletEdge RailType=DistFromEdge case above"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact fillet (RailType=DistBetweenRails, distance 2)" "FilletSrf's own new RailType=DistBetweenRails option reaches kernel::FilletConvexEdgeByDistanceBetweenRails the same way"
flcheck "Volume = 995.7 cubic" "a 10x10x10 box minus a DistBetweenRails=2 FilletSrf fillet has the identical exact volume as the plain FilletEdge RailType=DistBetweenRails case above"
flcheck "ChamferVertex: convex corner at vertex .* of object .* chamfered (distance 3)" "ChamferVertex wires kernel::ChamferConvexVertex, previously zero call sites anywhere in dino8-app (RemoveFillet already reached its own inverse, RemoveChamferVertex, but nothing built one forward)"
flcheck "Volume = 995.5 cubic" "a 10x10x10 box minus a distance=3 vertex chamfer has the exact closed-form volume 1000 - 3^3/6 = 995.5"
flcheck "FilletEdge: edge .* of object .* staged for an exact conic fillet (rho 0.5, distance 2) - 1 staged, Enter to apply" "the first Rho pick is staged, not applied immediately - kernel::FilletConvexEdgesConic/FilletConcaveEdgesConic need one shared PlanarFaces() snapshot of every staged edge"
flcheck "FilletEdge: edge .* of object .* staged for an exact conic fillet (rho 0.5, distance 2) - 2 staged, Enter to apply" "the second Rho pick, on the same object, is staged alongside the first rather than applied against the (still untouched) object"
flcheck "FilletEdge: an exact conic (Rho) fillet of the 2 staged edge(s) on object .* failed (convex attempt:.*concave attempt:" "two staged Rho edges that share a face (this box's own TOP-front and TOP-back edges) are rejected as ONE atomic batch - kernel::FilletConvexEdgesConic's own 'two edges in this batch share a face' validation - instead of the pre-fix bug where the first edge's own committed conic result would silently apply, then the second pick would fail confusingly (already-curved solid no longer PlanarFaces()-describable)"
flcheck "Volume = 1000 cubic" "neither staged edge touched the box - a clean atomic failure, not a partially-filleted object"
flcheck "FilletSrf: built between object .* and .*, radius 0.3; both surfaces trimmed" "FilletSrf's TrimBySplit (cmd_fillet.cpp) genuinely trims a NON-planar pick too now, not just a planar one: a bounded quarter-cylinder panel (open, non-periodic - its contact curve crosses the trim boundary at exactly two points) built from the same Arc+ExtrudeCrv fixture ConnectSrf's own general-trim case uses, paired with an oversized tilted plane - kernel::SplitFaceByCurve (boolean_general.h) is general to ANY ON_Surface, unlike TrimWholeLoop's ON_BrepTrimmedPlane"
flcheck "Area = 167 square" "the trimmed quarter-cylinder panel's real, reproducible combined area (stable across repeated runs; not a hand-derived closed form, the same 'no closed form, check the real number' convention the ConnectSrf case above uses) - reads 167, not the pre-BuildFilletAdaptive value of 169.1, since the underlying contact curve is now built from a genuinely more accurate (point-sampled, not per-CV-translated) offset surface; see PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
flcheck "FilletSrf: built between object .* and .*, radius 0.3; both surfaces trimmed\$" "BuildFilletAdaptive's own offset-sampling refinement converges dramatically on this curved-panel-plus-tilted-plane pair (measured directly during development: 0.295421 unrefined -> 0.00028232 at the very first, 8x8 offset-sample grid attempt - roughly a 1000x reduction), landing well under the scale-aware tolerance floor; the trailing \$ anchor means this line carries NO '(approximate: contact points off by up to ...)' suffix, confirming the certification actually succeeded rather than just not crashing - PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
flcheck "FilletEdge: edge .* of object .* staged for an exact fillet (radius 2) - 1 staged, Enter to apply" "the first of 3 box-corner edges is staged, not applied immediately, for the plain (non-Rho) radius case too now"
flcheck "FilletEdge: edge .* of object .* staged for an exact fillet (radius 2) - 2 staged, Enter to apply" "the second box-corner edge is staged alongside the first rather than applied against the (still untouched) object"
flcheck "FilletEdge: edge .* of object .* staged for an exact fillet (radius 2) - 3 staged, Enter to apply" "the third box-corner edge completes the staged batch"
flcheck "FilletEdge: 3 staged edges of object .* replaced with an exact multi-edge fillet (radius 2)" "all 3 staged edges were built as ONE kernel::FilletConvexEdges call, reaching its own m == 3 trihedral spherical-corner blend - PARITY_MAP.md's own 'no app command surfaces either function's own chain-pick at all' gap for the plain circular case"
flcheck "10 faces, 21 edges, closed solid" "one spherical corner blend: 6 planar + 3 cylindrical + 1 spherical = 10 faces, a genuine closed solid - not three independent disconnected pieces the old per-edge-immediate behavior would have left (the second and third picks would have hit a non-planar PlanarFaces() rejection and fallen back to the approximate BuildFillet path instead)"
flcheck "Volume = 975.4 cubic" "matches the app's own tessellated reading of the exact closed form 1000 - 3*8*4*(1-pi/4) - 8*(1-pi/6) = 975.587 (see this section's own comment in fillet_script.txt for why the app's coarser spherical-patch tessellation reads 975.4, not 975.587, and why that gap is pre-existing and unrelated to this fix)"
echo "$FL" | grep -E "^(ok|FAIL)"
if echo "$FL" | grep -q "^FAIL"; then fail=1; fi
flcheck "^ok   expect_objects 62" "fillet script produced the expected object count"

# Adversarial fillets: tiny/at-the-limit/too-large radii relative to the
# shortest adjacent edge, a huge-coordinate-scale box (now fixed for the
# plain constant-radius planar case by TryExactFillet - see
# adversarial_corpus_notes.md), and a shallow-bend FilletSrf (see
# fillet_adversarial_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FA="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/fillet_adversarial_script.txt" 2>&1)" || { echo "$FA"; echo "FAIL: fillet-adversarial script exited non-zero"; exit 1; }
else
  FA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/fillet_adversarial_script.txt" 2>&1)" || { echo "$FA"; echo "FAIL: fillet-adversarial script exited non-zero"; exit 1; }
fi
facheck() { if echo "$FA" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FA" "$1"; fail=1; fi; }
facheck "FilletEdge: edge 10 of object 1 replaced with an exact fillet (radius 0.02)" "a radius far smaller than the shortest adjacent edge still built a real, exact fillet"
facheck "FilletEdge: edge 10 of object 2 replaced with an exact fillet (radius 1)" "a radius at exactly half the shortest adjacent edge's length still built a valid fillet"
facheck "7 faces, 15 edges, closed solid" "the at-the-limit fillet is a genuine closed solid, not degenerate"
facheck "! FilletEdge: the offset surfaces do not meet" "a radius more than double what the geometry supports failed with a clear diagnostic, not a hang or garbage surface"
facheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (radius 2)" "a huge-coordinate-scale box's otherwise-ordinary fillet now succeeds: TryExactFillet's kernel::FilletConvexEdge builds one coherent double-precision Brep instead of stitching together independently-intersected spine samples, so the later float-mesh Volume check no longer sees a gap at this scale (see adversarial_corpus_notes.md's updated note)"
facheck "Volume = 991.4 cubic" "the huge-coordinate-scale fillet's tessellated volume matches the identical exact closed-form value fillet_script.txt's own origin-scale Radius=2 box case verifies, proving no precision was lost"
facheck "ChamferEdge: edge 10 of object 5 replaced with an exact chamfer (distance1 2, distance2 4)" "ChamferEdge's Distance2 option wires straight to kernel::ChamferConvexEdge's own two-INDEPENDENT-distance construction, not the symmetric rolling-ball-derived approximate path"
facheck "Volume = 960 cubic" "a 10x10x10 box minus a 2x4 asymmetric edge chamfer has volume 1000 - 2*4*10/2 = 960 exactly"
facheck "ChamferEdge: edge 10 of object 6 replaced with an exact chamfer (distance1 2, angle 45 degrees from face 1)" "ChamferEdge's Angle option wires to kernel::ChamferConvexEdgeAngle, whose law-of-sines dispatch to the two-distance form is exercised here at exactly the symmetric 45-degree case"
facheck "Volume = 980 cubic" "at Angle=45 on a right-angle edge distance_j == distance_i exactly, so this lands on the identical volume a plain symmetric Radius=2 chamfer would: 1000 - 2*2*10/2 = 980"
facheck "ChamferEdge: edge .* of object .* replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "a Distance2 request on a cylinder's curved-adjacent-face rim edge now reaches kernel::ChamferCylinderRim's exact two-distance cone (wall 1 / cap 2) instead of failing with the planar-only diagnostic - the one curved case with an exact unequal-distance construction; the Distance/Angle diagnostic on the same rim is pinned in kernel_wiring_script.txt below"
facheck "FilletEdge: edge 10 of object 8 replaced with an exact conic fillet (rho 0.5, distance1 2, distance2 4)" "FilletEdge's Rho option combined with Distance2 wires straight to kernel::FilletConvexEdgeConic's own two-INDEPENDENT-distance form, an elliptical (not parabolic) conic cross-section"
facheck "Volume = 986.7 cubic" "a 10x10x10 box minus an asymmetric distance1=2/distance2=4 rho=0.5 conic edge fillet has volume 1000 - 2*4*sin(90deg)*10/6 = 986.7"
facheck "! FilletEdge: an exact conic .Rho. fillet needs the whole object to be planar-faced at this edge" "a Rho request on a cylinder's curved-adjacent-face rim edge fails outright instead of silently building a plain circular rolling-ball fillet that quietly ignores Rho - unlike Chamfer's symmetric-distance case, there is no approximate fallback a non-circular conic could ever be represented by"
facheck "! FilletEdge: an exact RailType=DistFromEdge fillet needs the whole object to be planar-faced at this edge" "a RailType=DistFromEdge request on a cylinder's curved-adjacent-face rim edge fails outright instead of silently building a plain radius=1 rolling-ball fillet under a mismatched distance interpretation - like Rho, the dihedral-angle-to-radius conversion has no meaning on a curved adjacent face"
facheck "! FilletEdge: an exact RailType=DistFromEdge fillet of the 2 staged edge.s. on object .* failed" "two RailType edges staged in one FilletEdge run that meet at a shared vertex (TOP-FRONT and TOP-LEFT, an m == 2 configuration whose third edge stays sharp) are rejected atomically by FilletConvexEdgesByDistanceFromEdge's own documented scope limit - the pending_rail_ staging this pass added - rather than silently applying the first pick and failing the second"
facheck "Volume = 1000 cubic" "the two-RailType-edges-meeting-at-a-vertex batch rejection leaves the box completely untouched, not a partially-filleted result"
facheck "! FilletSrf: the offset surfaces do not meet" "FilletSrf on two nearly-flat planes failed with its own clear diagnostic instead of a garbage surface"
facheck "ChamferSrf: built between object .* and .*, radius 1" "ChamferSrf Trim=No on a cylinder's own flat-top cap and curved side wall still falls through to the approximate RuledBetween path (the exact kernel::ChamferCylinderRim path always replaces the whole solid with an already-trimmed result, not the untrimmed separate surface Trim=No asks for) instead of crashing or silently misbuilding"
facheck "ChamferSrf: built between object .* and .*, radius 2" "ChamferSrf Trim=No on an otherwise-exact planar box corner also falls through to the approximate path - the exact kernel path always replaces the whole solid with an already-trimmed result, not the untrimmed separate surface Trim=No asks for"
facheck "! RemoveFillet: the picked face is not a recognized fillet, chamfer, or vertex-chamfer facet" "RemoveFillet on a plain box face declines with a clear diagnostic (kernel::RemoveBlend finds no fillet-family patch at all, kernel::RemoveChamfer's rail-pairing check fails for both of a box face's own parallel neighbour pairs, kernel::RemoveChamferVertex rejects the 4-point loop outright) instead of crashing or misidentifying an ordinary face as a blend"
facheck "Volume = 1000 cubic" "the box RemoveFillet declined to touch survives with its exact original volume"
facheck "! FilletVertex: not a supported trihedral corner" "a FilletVertex radius too large for a 2x2x2 box's own corner edges fails cleanly on both the convex and concave kernel attempts, not a crash or garbage geometry"
facheck "Volume = 8 cubic" "the box a failed FilletVertex declined to touch survives with its exact original 2x2x2 volume"
facheck "FilletSrf: built between object .* and .*, radius 1 to 2; one surface trimmed (the other could not be split)" "VariableFilletSrf on a cylinder's own flat-top cap and curved side wall falls through to the approximate BuildPlaneCylinderVariableFillet/BuildFillet cascade (kernel::FilletConvexEdgeTapered needs the WHOLE solid planar-faced, which a cylindrical face fails outright) instead of crashing or silently misbuilding; the wall's own contact curve is still a closed loop TrimBySplit correctly refuses, but the cap's own TrimWholeLoop now succeeds - BuildFilletAdaptive's genuinely more accurate (point-sampled) contact curve closes the cap's own trim loop cleanly where the pre-fix, less-accurate OffsetBy-derived curve did not, so only one side stays untrimmed now, not both; see PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
facheck "FilletSrf: built between object .* and .*, radius 1 to 2$" "VariableFilletSrf Trim=No on an otherwise-exact planar box corner also falls through to the approximate cascade - the exact kernel path always replaces the whole solid, not the untrimmed separate surface Trim=No asks for"
facheck "! FilletSrf: an exact conic (Rho) fillet needs the two faces to share an edge on one planar-faced solid with Trim=Yes (convex attempt:.*not planar" "FilletSrf Rho on a cylinder's own flat-top cap and curved side wall refuses with a clear diagnostic instead of silently building a plain round fillet that quietly ignores Rho - unlike Chamfer/VariableFillet just above, there is no approximate fallback a non-circular conic could ever be represented by"
facheck "! FilletSrf: an exact conic (Rho) fillet needs the two faces to share an edge on one planar-faced solid with Trim=Yes (the two picks are independent surfaces with no shared edge)" "FilletSrf Rho on two genuinely independent (no shared edge) extracted surfaces refuses the same way - fa.id != fb.id means kernel::FilletConvexEdgeConic/FilletConcaveEdgeConic have no shared ON_BrepEdge to identify at all, not merely a curved-face rejection"
facheck "! BlendSrf: could not build the blend" "BlendSrf Continuity=G3, picking the same face/edge twice (a genuinely degenerate, zero-length rail pairing), fails closed with a clear diagnostic instead of silently building a degenerate patch - G3 has no approximate fallback to drop to the way Continuity=Tangency/Curvature would"
facheck "BlendEdge: blend surface added between the two faces at edge 2" "BlendEdge on a cylinder's own curved-adjacent-face rim edge falls through to the pre-existing 'added as a separate surface' behaviour unchanged - the new exact trim-and-join path needs both adjacent faces planar"
facheck "3 faces, 3 edges, closed solid" "the cylinder itself survives completely untouched by the failed trim-and-join attempt"
facheck "! FilletEdge: the offset surfaces do not meet .*(the largest radius this edge's own two faces support is 5)" "a radius 10x beyond what either adjacent face supports (50, on an edge whose kernel::MaxFilletRadius is exactly 5) now reports the REAL largest radius this edge can take, not just the approximate path's own generic diagnostic - closing PARITY_MAP.md's own 'the app reports the failure rather than handling it' half of the Fillet overflow gap"
facheck "Volume = 1000 cubic" "the box a radius-50 FilletEdge declined to touch survives with its exact original volume"
facheck "Domain: 1 object(s) now have domain 0 to 24.95" "Domain pinned the ruled chamfer surface's V length to 24.9513866589378, a value where equal-step isocurve parameters overshoot the domain end by one ulp"
if echo "$FA" | grep -q "IsoCurve: parameter is outside"; then echo "FAIL a surface's isocurve display parameter overshot its own domain end by an ulp and NurbsSurface::IsoCurve threw (SceneObject.cpp DomainParameter regression - this is what killed Windows CI with 0xE06D7363)"; fail=1; else echo "ok   a surface whose equal-step isocurve parameter would overshoot its domain end by an ulp still draws (DomainParameter pins the endpoints)"; fi
# An exception a command, the frame/draw path or a display tessellation threw
# is contained and reported on stderr by the app (main.cpp / SceneObject.cpp)
# instead of terminating the process (Windows CI used to die here with a bare
# "UNHANDLED EXCEPTION: code=0xE06D7363"). It does not fail the run by itself,
# but surface the message so the real thrower is visible in the CI log.
echo "$FA" | grep -E "^dino8: (! |display tessellation)" | sed 's/^/note   fillet-adversarial: contained exception: /' || true
echo "$FA" | grep -E "^(ok|FAIL)"
exit $fail
