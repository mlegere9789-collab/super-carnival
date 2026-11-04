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
HERE="/home/user/miniature-pancake/dino8-app/tests"
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
if echo "$FA" | grep -q "^FAIL"; then fail=1; fi
facheck "^ok   expect_objects 0" "fillet-adversarial script cleaned up to zero objects at the end"

# Extended selection and state commands: SelDupAll, SelShortCrv, SelKeyValue, SelVolumeSphere, Dot, Camera, SetActiveViewport, licence rule (see state_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  ST="$(timeout 900 "$BIN" --smoke 120 --script "$HERE/state_script.txt" 2>&1)" || { echo "$ST"; echo "FAIL: state script exited non-zero"; exit 1; }
else
  ST="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 120 --script "$HERE/state_script.txt" 2>&1)" || { echo "$ST"; echo "FAIL: state script exited non-zero"; exit 1; }
fi
stcheck() { if echo "$ST" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$ST" "$1"; fail=1; fi; }
stcheck "SelDupAll: 2 duplicate object(s) selected" "SelDupAll found the two identical lines"
stcheck "SelShortCrv: 1 curve(s) shorter than 5 selected" "SelShortCrv picked the 2-unit line"
stcheck "Hyperlink 'https://example.org/dino8' set on 1 object(s)" "Hyperlink stored user text"
stcheck "SelKeyValue: 1 object(s) with Hyperlink=https://example.org/dino8 selected" "SelKeyValue matched the user text"
stcheck "SelVolumeSphere: radius 15, 2 object(s) selected" "SelVolumeSphere selected the objects near the origin"
stcheck "Dot 'Hello' at 5,5,0 (object 5)" "Dot created a text dot"
stcheck "Named selection 'dots' restored: 1 object(s) selected" "NamedSelections saved and restored a set"
stcheck "Camera (Perspective): location" "Camera reported the perspective camera"
stcheck "Active viewport: Top" "SetActiveViewport switched to Top"
stcheck "Camera (Top): location .*parallel projection" "Camera reported the Top (parallel) camera"
stcheck "Perspective angle 60 deg" "PerspectiveAngle set the lens"
stcheck "Dino 8 is free software: no licenses, accounts or subscriptions." "CheckOutLicense/Login print the no-licence rule"
stcheck "Selection filter edges on" "SelectionFilterEdges toggled the filter"
# FRH: exact fillet / chamfer of the rim of a cylindrical hole (frh_script.txt) - a 6 x 6 x 4 box minus a
# radius-1.5 through-hole (the exact General-engine Boolean the app produces; V0 = 144 - pi*1.5^2*4 = 115.726). The rim
# is a plane/concave-cylinder edge; the rolling ball there is an exact torus (chamfer: an exact cone), so the result
# is assembled from exact pieces (cmd_fillet.cpp ClassifyHolePlateRim / BuildBlendedHolePlate) and must be a closed
# polysurface that the app's own Check calls valid (the Boolean input itself is a sewn, 129-edge polyline-rim solid).
# Volumes are read from the display mesh, which reads this base solid as 115.8 (+0.07 over the exact 115.726) and
# prints 4 significant digits (0.1 steps), so each window is the Pappus closed form +0.07 +- 0.25 -- narrower than
# the removed volume itself for every case (smallest: the r = 0.5 lower rim, 0.54), so a fillet that did nothing,
# or the old mesh fillet's different volume, cannot pass:
#   fillet r:        2*pi*r^2*(R + r/2 - (pi/4)*(R + r) + r/3)    r=1: 2.3238   r=0.5: 0.5433   (R = 1.5)
#   chamfer w / c:   pi*w*c*(R + c/3)                              1x1: 5.7596   1.5x0.5: 3.9270
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FRH_OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/frh_script.txt" 2>&1)" || { echo "$FRH_OUT"; echo "FAIL: frh script exited non-zero"; exit 1; }
else
  FRH_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/frh_script.txt" 2>&1)" || { echo "$FRH_OUT"; echo "FAIL: frh script exited non-zero"; exit 1; }
fi
frhblock() { awk -v name="$1" '$0 ~ ("Unknown command: FRHBEGIN_" name "$") { on = 1; next } on && /Unknown command: FRHBEGIN_|Unknown command: FRHEND/ { exit } on { print }' <<<"$FRH_OUT"; }
frhcheck() { local blk; blk="$(frhblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Boolean|FilletEdge|ChamferEdge|Object|  [0-9]|Volume|!)" <<<"$blk" | head -8 | sed 's/^/     actual:   /' || true; fail=1; fi; }
# frhvol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
frhvol() {
  local blk v; blk="$(frhblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
frhcheck base "7 faces, [0-9]* edges, closed solid" "control: the Boolean result is the 7-face closed solid (box minus through-hole)"
frhvol base 115.6 116.0 "control: Boolean base Volume = 144 - pi*1.5^2*4 = 115.726 (display mesh)"
frhcheck F_top "hole rim(s) of object 3 replaced with an exact fillet (upper radius 1; exact torus patch on the concave hole wall, 8 faces, closed solid)" "FilletEdge of the hole's upper rim is an exact torus fillet (before: 'mesh fallback ... approximate mesh')"
frhcheck F_top "8 faces, 17 edges, closed solid" "...8 faces (4 sides, 2 ends, wall, torus) and 17 edges, closed solid (before: an 8000-vertex mesh)"
frhcheck F_top "(polysurface)" "...stays a polysurface, not a mesh"
frhcheck F_top "Object 3: valid" "...passes the app's own Check"
frhvol F_top 113.2 113.7 "upper-rim fillet r=1 Volume = 115.726 - 2.3238 = 113.402"
frhcheck F_both "upper radius 1, lower radius 0.5; exact torus patches on the concave hole wall, 9 faces, closed solid" "both rims picked in one run become one exact solid"
frhcheck F_both "9 faces, 19 edges, closed solid" "...9 faces and 19 edges, closed solid"
frhcheck F_both "Object 3: valid" "...passes Check"
frhvol F_both 112.7 113.2 "both-rim fillet Volume = 115.726 - 2.3238 - 0.5433 = 112.859"
frhcheck F_bottom "lower radius 0.5; exact torus patch on the concave hole wall, 8 faces, closed solid" "the lower rim alone is exact too"
frhcheck F_bottom "Object 3: valid" "...passes Check"
frhvol F_bottom 115.0 115.5 "lower-rim fillet r=0.5 Volume = 115.726 - 0.5433 = 115.183"
frhcheck C_top "ChamferEdge: edge [0-9]* of object 3 replaced with an exact chamfer (radius 1; exact cone on the cylinder rim" "ChamferEdge of the hole's rim is an exact cone (before: the approximate mesh chamfer)"
frhcheck C_top "8 faces, 17 edges, closed solid" "...8 faces, 17 edges, closed solid"
frhcheck C_top "Object 3: valid" "...passes Check"
frhvol C_top 109.8 110.4 "chamfer 1x1 Volume = 115.726 - 5.7596 = 109.966"
frhcheck C_asym "distance1 1.5, distance2 0.5; exact cone on the cylinder rim" "asymmetric chamfer (1.5 along the wall, 0.5 across the cap) is exact"
frhcheck C_asym "Object 3: valid" "...passes Check"
frhvol C_asym 111.6 112.1 "asymmetric chamfer Volume = 115.726 - 3.927 = 111.799"
frhcheck F_toobig "exact cylinder-rim fillet not used (the blend would run off the end face)" "a radius that would run off the end face is refused with the reason"
frhcheck F_toobig "FilletEdge: edge [0-9]* -- mesh fallback" "...and the old approximate path still runs (its mesh-fallback note is printed)"
frhcheck F_toobig "Object [0-9]* (mesh) layer" "...and the result is a mesh object (the plate was not left unchanged or half-built)"
frhcheck F_exactno "mesh fallback (exact B-rep trim unavailable here" "Exact=No keeps the approximate mesh fillet"
# A vertical box edge of the same holed solid (Pappus: (1 - pi/4)*r^2*4 for the 4-high plate): r=1 -> 0.8584, r=0.5 -> 0.2146
# (the earlier behaviour: 'could not build a watertight result' / an approximate mesh)
frhcheck E_corner "1 corner edge(s) of object 3 (a prism with a cylindrical hole) replaced with an exact fillet" "a box edge on the solid that also has the hole is an exact cylindrical corner fillet"
frhcheck E_corner "8 faces, 18 edges, closed solid" "...8 faces, 18 edges, closed solid"
frhcheck E_corner "(polysurface)" "...a polysurface"
frhcheck E_corner "Object 3: valid" "...passes Check"
frhvol E_corner 114.7 115.2 "corner fillet r=1 Volume = 115.726 - 0.8584 = 114.868"
frhcheck E_corner2 "2 corner edge(s) of object 3 (a prism with a cylindrical hole) replaced with an exact fillet" "two corners (r=1, r=0.5) in one run"
frhcheck E_corner2 "9 faces, 21 edges, closed solid" "...9 faces, 21 edges, closed solid"
frhcheck E_corner2 "Object 3: valid" "...passes Check"
frhvol E_corner2 114.5 115.0 "two-corner Volume = 115.726 - 0.8584 - 0.2146 = 114.653"
frhcheck E_corner_rim "upper radius 0.5; exact torus patch on the concave hole wall, 1 exact cylindrical corner fillet(s), 9 faces, closed solid" "a corner edge and the hole's upper rim in one run become one exact solid"
frhcheck E_corner_rim "Object 3: valid" "...passes Check"
frhvol E_corner_rim 114.1 114.65 "corner + rim Volume = 115.726 - 0.8584 - 0.5433 = 114.325"
frhcheck E_corner_toobig "exact cylinder-rim fillet not used (the corner fillet would run into the hole)" "a corner radius longer than the plate's edge is refused with the reason"
frhcheck E_corner_toobig "7 faces, [0-9]* edges, closed solid" "...and the solid is left unchanged (7 faces), never replaced by a wrong result"
frhcheck E_corner_wedge "exact cylinder-rim fillet not used (the rounded outline no longer encloses the hole)" "a corner rounding that cuts the hole out of the plate is refused with the reason (every arc sample clears the hole, so only the enclosure test catches it)"
frhcheck E_corner_wedge "7 faces, [0-9]* edges, closed solid" "...and the solid is left unchanged (7 faces), never replaced by a wrong result"
frhcheck R_rot "upper radius 0.4; exact torus patch on the concave hole wall, 8 faces, closed solid" "an off-centre hole in a plate rotated 30 degrees about z: the polygon is rebuilt from the side planes, still exact"
frhcheck R_rot "Object 3: valid" "...passes Check"
frhvol R_rot 115.2 115.6 "rotated off-centre plate rim fillet r=0.4 Volume = 115.726 - 0.3428 = 115.383"
# Blind holes (the pocket's 8-face Boolean result becomes 9 exact faces: 4 sides, closed end, open end, wall, floor, torus/cone)
frhcheck B_top "hole rim(s) of object 3 replaced with an exact fillet (upper radius 1; exact torus patch on the concave hole wall, 9 faces, closed solid)" "FilletEdge of a BLIND hole's rim is an exact torus fillet (before: the approximate mesh fillet)"
frhcheck B_top "9 faces, 17 edges, closed solid" "...9 faces, 17 edges, closed solid"
frhcheck B_top "Object 3: valid" "...passes Check"
frhvol B_top 120.25 120.75 "blind-hole rim fillet Volume = 144 - pi*1.5^2*3 - 2.3238 = 120.470"
frhcheck B_bottom "exact fillet (upper radius 1; exact torus patch on the concave hole wall, 9 faces, closed solid)" "a blind hole opening at the BOTTOM face is handled too (axis flipped to run closed end -> open end)"
frhcheck B_bottom "Object 3: valid" "...passes Check"
frhvol B_bottom 127.3 127.8 "bottom-opening blind hole Volume = 144 - pi*1.5^2*2 - 2.3238 = 127.539"
frhcheck B_chamfer "ChamferEdge: edge [0-9]* of object 3 replaced with an exact chamfer (radius 1; exact cone on the cylinder rim" "ChamferEdge of a blind hole's rim is an exact cone"
frhcheck B_chamfer "Object 3: valid" "...passes Check"
frhvol B_chamfer 116.85 117.35 "blind-hole chamfer Volume = 122.794 - 5.7596 = 117.034"
frhcheck control_box "FilletEdge: edge 10 of object 1 replaced with an exact fillet (radius 1)" "control: a plain box edge is still the kernel's exact planar fillet"
frhvol control_box 143.0 143.3 "control: box edge fillet Volume = 144 - (1 - pi/4)*1*4 = 143.142"
if grep -q "^FAIL" <<<"$FRH_OUT"; then echo "FAIL frh script reported an in-script FAIL"; fail=1; fi
frhcheck_gl() { if grep -q "gl_error=0" <<<"$FRH_OUT"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
frhcheck_gl "frh script ran without OpenGL errors"

# ---------------------------------------------------------------------------
# SCP_: Sweep1 / Sweep2 "Cap" option and the exact closed circular rail (scp_sweepcap_script.txt).
# Cap=Yes (default No, so every earlier pin holds) turns a CLOSED PLANAR cross section's sweep into a closed B-rep solid
# with the kernel's own capping (Brep::AssembleSweptBody, the capping Pipe / Brep::Sweep1 cap=true use), from the
# single-section Sweep1/Sweep2 exact path (a section anywhere along the rail included) and the multi-section Sweep1
# wall; an open section, or a fallback construction, keeps the surface and prints why. A closed rail that is an exact
# planar circle is a surface of revolution (the rotation-minimizing frames of a circle have no torsion), built by the
# kernel's Brep::Revolve and MEASURED against the revolved section; Cap=Yes there gives the closed torus-like solid.
# Every figure is compared with its analytic value: cylinder pi r^2 L, cone frustum pi h/3 (r0^2 + r0 r1 + r1^2),
# torus 2 pi^2 R r^2 and area 4 pi^2 R r. The mesh-derived figures (Volume/Area/BoundingBox) use ranges (Windows
# tessellates slightly differently); the kernel's exact figures are tight.
# ---------------------------------------------------------------------------
scp_ok() { echo "ok   $1"; }
scp_bad() { echo "FAIL $1"; fail=1; }
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SCP_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/scp_sweepcap_script.txt" 2>&1)" || { echo "$SCP_OUT" | tail -40; echo "FAIL SCP_run: sweep cap script exited non-zero"; fail=1; SCP_OUT=""; }
else
  SCP_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/scp_sweepcap_script.txt" 2>&1)" || { echo "$SCP_OUT" | tail -40; echo "FAIL SCP_run: sweep cap script exited non-zero"; fail=1; SCP_OUT=""; }
fi
if grep -q "^FAIL" <<<"$SCP_OUT"; then scp_bad "SCP_script: an @expect line of the script failed"; else scp_ok "SCP_script: every @expect_objects line of the script held"; fi
# The output of the n-th Sweep1/Sweep2 command (up to the next one); the last case is cut at the end of the output.
scp_case() { awk -v n="$1" '/Command: Sweep[12]/ { c++ } c == n' <<<"$SCP_OUT"; }
scp_in() { awk -v v="${1:-}" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }'; }
# $1 = case output, $2 unused, checked: the number after "exact volume " in [$3, $4]
scp_exactvol() {
  local v
  v="$({ grep -o "exact volume [0-9.e+-]*" <<<"$1" || true; } | head -1 | awk '{print $3}')"
  if scp_in "$v" "$3" "$4"; then scp_ok "$5 (kernel exact volume $v in $3..$4)"; else scp_bad "$5 (exact volume '$v' not in $3..$4)"; fi
}
scp_meshvol() {
  local v
  v="$({ grep -o "^history: Volume = [0-9.e+-]*" <<<"$1" || true; } | head -1 | awk '{print $4}')"
  if scp_in "$v" "$2" "$3"; then scp_ok "$4 (the Volume command reads $v in $2..$3; its display mesh is coarser than the exact figure)"; else scp_bad "$4 (Volume '$v' not in $2..$3)"; fi
}
scp_has() { if grep -qF -- "$2" <<<"$1"; then scp_ok "$3"; else scp_bad "$3"; near "$1" "$2"; fi; }
scp_hasnot() { if grep -qF -- "$2" <<<"$1"; then scp_bad "$3"; near "$1" "$2"; else scp_ok "$3"; fi; }
scp_solid() {
  if grep -q "(polysurface)" <<<"$1" && grep -q "closed solid" <<<"$1" && grep -q "Object [0-9]*: valid" <<<"$1"; then scp_ok "$2: a polysurface, closed solid, passes Check"; else scp_bad "$2: not a valid closed polysurface solid"; near "$1" "closed solid"; fi
}
# $1 = case, $2 = "x0lo x0hi y0lo y0hi z0lo z0hi x1lo x1hi y1lo y1hi z1lo z1hi"
scp_bbox() {
  local line
  line="$({ grep -o "Bounding box min [^ ]* max [^ ]*" <<<"$1" || true; } | head -1)"
  if [ -n "$line" ] && awk -v r="$2" '{ split($4, a, ","); split($6, b, ","); split(r, q, " ");
        ok = (a[1] >= q[1] && a[1] <= q[2] && a[2] >= q[3] && a[2] <= q[4] && a[3] >= q[5] && a[3] <= q[6] &&
              b[1] >= q[7] && b[1] <= q[8] && b[2] >= q[9] && b[2] <= q[10] && b[3] >= q[11] && b[3] <= q[12]); exit !ok }' <<<"$line"; then
    scp_ok "$3 ($line)"
  else
    scp_bad "$3 (box '$line' outside $2)"
  fi
}
SCP_1="$(scp_case 1)"; SCP_2="$(scp_case 2)"; SCP_3="$(scp_case 3)"; SCP_4="$(scp_case 4)"; SCP_5="$(scp_case 5)"
SCP_6="$(scp_case 6)"; SCP_7="$(scp_case 7)"; SCP_8="$(scp_case 8)"; SCP_9="$(scp_case 9)"; SCP_10="$(scp_case 10)"; SCP_11="$(scp_case 11)"; SCP_12="$(scp_case 12)"
# 1: Sweep1 Cap=Yes, circle r = 2, rail 10 -> cylinder, pi r^2 L = 125.6637
scp_has "$SCP_1" "Sweep1: Cap=Yes - closed B-rep solid with 3 faces (wall + two planar end caps)" "SCP_1: Sweep1 Cap=Yes caps the circle's sweep with two planar end caps (3 faces)"
scp_exactvol "$SCP_1" x 125.6617 125.6657 "SCP_1: cylinder volume pi*2^2*10 = 125.6637"
scp_meshvol "$SCP_1" 124.0 126.5 "SCP_1: Volume of the closed solid"
scp_solid "$SCP_1" "SCP_1"
scp_bbox "$SCP_1" "-2.05 -1.95 -2.05 -1.95 -0.01 0.01 1.95 2.05 1.95 2.05 9.99 10.01" "SCP_1: box is the r = 2 circle's extent and z = 0..10"
# 2: the default is unchanged: an uncapped surface
scp_hasnot "$SCP_2" "Cap=Yes" "SCP_2: without the option no capping happens or is mentioned"
scp_has "$SCP_2" "(surface)" "SCP_2: the default result is still a plain surface"
scp_has "$SCP_2" "is not closed" "SCP_2: ...which has no volume (not closed)"
# 3: section half way along the rail
scp_has "$SCP_3" "the section sits 50.0% along the rail; the rail was split there and both sides swept from the section and joined" "SCP_3: the circle at 50% of the rail takes the split-and-join path"
scp_exactvol "$SCP_3" x 125.6617 125.6657 "SCP_3: capped joined sweep has the same cylinder volume 125.6637"
scp_solid "$SCP_3" "SCP_3"
scp_bbox "$SCP_3" "-2.05 -1.95 -2.05 -1.95 -0.01 0.01 1.95 2.05 1.95 2.05 9.99 10.01" "SCP_3: the joined, capped solid spans z = 0..10"
# 4: Sweep2 cone frustum, pi h/3 (r0^2 + r0 r1 + r1^2) = 70 pi / 3 = 73.3038
scp_has "$SCP_4" "Sweep2: Cap=Yes - closed B-rep solid with 3 faces (wall + two planar end caps)" "SCP_4: Sweep2 Cap=Yes caps the two-rail sweep"
scp_exactvol "$SCP_4" x 73.302 73.306 "SCP_4: cone frustum volume pi*10/3*(4+2+1) = 73.3038"
scp_meshvol "$SCP_4" 72.0 74.5 "SCP_4: Volume of the closed frustum"
scp_solid "$SCP_4" "SCP_4"
# 5: multi-section Sweep1 (Brep::Sweep1Sections wall) capped: the same frustum
scp_has "$SCP_5" "Sweep1: exact kernel multi-section sweep (2 sections, " "SCP_5: two circles reach the kernel's Brep::Sweep1Sections"
scp_has "$SCP_5" "Sweep1: Cap=Yes - closed B-rep solid with 3 faces" "SCP_5: ...and its wall is capped"
scp_exactvol "$SCP_5" x 73.302 73.306 "SCP_5: frustum volume 73.3038"
scp_solid "$SCP_5" "SCP_5"
# 6: an open section cannot be capped: refused with the reason, the surface is kept
scp_has "$SCP_6" "Sweep1: Cap=Yes not applied (the cross section is not closed); the uncapped surface is kept" "SCP_6: an open arc section is refused with that reason"
scp_has "$SCP_6" "(surface)" "SCP_6: ...and the swept surface is kept"
# 11: a bow-tie section closes topologically but is not a simple loop: refused with the reason, the surface is kept
scp_has "$SCP_11" "Sweep1: Cap=Yes not applied (the cross section crosses itself); the uncapped surface is kept" "SCP_11: a self-crossing (bow-tie) section is refused with that reason"
scp_has "$SCP_11" "(surface)" "SCP_11: ...and the swept surface is kept"
# 12: a concave but simple L section still caps: area 5 * length 10 = 50
scp_has "$SCP_12" "Sweep1: Cap=Yes - closed B-rep solid" "SCP_12: a concave simple L section is still capped"
scp_exactvol "$SCP_12" x 49.99 50.01 "SCP_12: exact volume 5 * 10 = 50"
scp_solid "$SCP_12" "SCP_12"
# 7: torus from a circle section on a circle rail, Cap=No -> surface of revolution
scp_has "$SCP_7" "the rail is an exact circle, so the sweep is the section revolved once about the rail's axis" "SCP_7: the closed circular rail is an exact surface of revolution, not the 32-station skin"
SCP_DEV="$({ grep -o "from the revolved section [0-9.e+-]*" <<<"$SCP_7" || true; } | head -1 | awk '{print $5}')"
if scp_in "$SCP_DEV" 0 1e-12; then scp_ok "SCP_7: measured distance of 2145 wall points from the revolved section $SCP_DEV <= 1e-12"; else scp_bad "SCP_7: measured revolve deviation '$SCP_DEV' not in 0..1e-12"; fi
SCP_D="$({ grep -o "Closest point [^ ]* distance [0-9.e+-]*" <<<"$SCP_7" || true; } | awk '{print $NF}')"
SCP_DN="$(grep -c . <<<"$SCP_D" || true)"
if [ "$SCP_DN" = "5" ] && awk '{ if ($1 + 0 >= 1e-6) bad = 1 } END { exit bad }' <<<"$SCP_D"; then scp_ok "SCP_7: 5 points of the EXACT torus (R = 10, r = 1, off the 32-station grid) are within 1e-6 of the surface (the old skin missed by 3e-5; got: $(echo $SCP_D))"; else scp_bad "SCP_7: expected 5 distances below 1e-6, got $SCP_DN: $(echo $SCP_D)"; fi
SCP_A="$({ grep -o "Area = [0-9.e+-]*" <<<"$SCP_7" || true; } | head -1 | awk '{print $3}')"
if scp_in "$SCP_A" 390 397; then scp_ok "SCP_7: torus area $SCP_A matches 4 pi^2 R r = 394.78 to the display mesh"; else scp_bad "SCP_7: area '$SCP_A' not near 394.78"; fi
if grep -q "Object [0-9]*: valid" <<<"$SCP_7"; then scp_ok "SCP_7: the torus surface passes Check"; else scp_bad "SCP_7: Check did not report valid"; fi
# 8: Cap=Yes on the closed rail: a closed one-face torus solid, 2 pi^2 R r^2 = 197.3921
scp_has "$SCP_8" "closed B-rep solid with 1 face (the closed rail has no ends" "SCP_8: a closed rail has no ends: the wall closed both ways bounds the solid (1 face)"
scp_exactvol "$SCP_8" x 197.390 197.395 "SCP_8: torus volume 2 pi^2 * 10 * 1^2 = 197.3921"
scp_meshvol "$SCP_8" 185 199 "SCP_8: Volume of the torus solid"
scp_solid "$SCP_8" "SCP_8"
# 9: control - an ellipse rail is not a circle: the kernel's ordinary sweep, unchanged
scp_has "$SCP_9" "Sweep1: the section is at the rail start" "SCP_9: an elliptical closed rail still takes the kernel's ordinary Brep::Sweep1"
scp_hasnot "$SCP_9" "revolved once" "SCP_9: ...and is not mistaken for a circle"
SCP_A9="$({ grep -o "Area = [0-9.e+-]*" <<<"$SCP_9" || true; } | head -1 | awk '{print $3}')"
if scp_in "$SCP_A9" 300 340; then scp_ok "SCP_9: ellipse-rail sweep area $SCP_A9 in 300..340 (control; measured 319.9 when written)"; else scp_bad "SCP_9: area '$SCP_A9' not in 300..340"; fi
# 10: History On + Cap=Yes: moving the section rebuilds the capped solid
SCP_N10="$(grep -c "Cap=Yes - closed B-rep solid" <<<"$SCP_10" || true)"
if [ "$SCP_N10" = "2" ]; then scp_ok "SCP_10: the capped solid was built and then rebuilt from its recorded Cap=Yes when the section moved"; else scp_bad "SCP_10: Cap=Yes solid built $SCP_N10 time(s), expected 2"; fi
scp_has "$SCP_10" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (3)" "SCP_10: the section move re-evaluated the sweep with no UpdateHistory"
scp_solid "$SCP_10" "SCP_10 (after the rebuild)"
scp_bbox "$SCP_10" "-1.05 -0.95 -2.05 -1.95 -0.01 0.01 2.95 3.05 1.95 2.05 9.99 10.01" "SCP_10: the rebuilt solid followed the section 1 unit in +x"
SCP_TOTAL="$(grep -c "Cap=Yes - closed B-rep solid" <<<"$SCP_OUT" || true)"
if [ "$SCP_TOTAL" = "8" ]; then scp_ok "SCP_count: 8 capped solids in the whole run (cases 1, 3, 4, 5, 8, 12 and 10 twice; the bow-tie case 11 is refused)"; else scp_bad "SCP_count: $SCP_TOTAL capped solids, expected 8"; fi

# HSO: exact Shell / OffsetSrf of a right prism with a cylindrical THROUGH-HOLE - the exact
# Boolean result of a box minus a cylinder (hso_script.txt; prism_solid.h RecognizeHole /
# OffsetHoleSolid). Before, the sewn cap (a polyline keyhole loop) was not recognised as a
# prism and Shell / OffsetSrf printed 'exact B-rep shell not used' and became meshes. The plan is
# read from the exact faces (cylinder, the two end planes, the side planes' ring) like the
# FRH_ hole-rim fillet: outer polygon offset by d, hole radius R - d (concentric), caps moved by d;
# the shell cavity is the same prism inset by t with the hole widened to R + t. Expected volumes
# are closed forms (box 10 x 10 x 10, hole R = 2):
#   solid 1000 - 40 pi = 874.34; Shell 0.5: 874.34 - (81 - 6.25 pi) * 9 = 322.06;
#   OffsetSrf +1: (144 - pi) * 12 = 1690.30; -1: (64 - 9 pi) * 8 = 285.82;
#   Solid=Yes +1: 1690.30 - 874.34 = 815.96, -1: 874.34 - 285.82 = 588.52.
# Volumes are read from the display mesh, so they are range-checked.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HSO_OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/hso_script.txt" 2>&1)" || { echo "$HSO_OUT"; echo "FAIL: hso script exited non-zero"; exit 1; }
else
  HSO_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/hso_script.txt" 2>&1)" || { echo "$HSO_OUT"; echo "FAIL: hso script exited non-zero"; exit 1; }
fi
hsoblock() { awk -v name="$1" '$0 ~ ("Unknown command: HSOBEGIN_" name "$") { on = 1; next } on && /Unknown command: HSOBEGIN_|Unknown command: HSOEND/ { exit } on { print }' <<<"$HSO_OUT"; }
hsocheck() { local blk; blk="$(hsoblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; { grep -E "^history: (Shell|Offset|Object|  [0-9]|Volume|!)" <<<"$blk" || true; } | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
hsovol() {
  local blk v; blk="$(hsoblock "$1")"
  v="$({ grep -E "^history: Volume = " <<<"$blk" || true; } | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/')"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
hsocheck shell "Shell: thickness 0.5, closed, exact B-rep, volume" "HSO_shell: Shell of a box with a Boolean through-hole is an exact B-rep (before: 'exact B-rep shell not used (the cap boundary is not one clean closed loop', mesh)"
hsovol shell 318 326 "HSO_shell: Volume = 874.34 - (81 - 6.25 pi) * 9 = 322.06"
hsocheck shell "Object [0-9]*: valid" "HSO_shell: ...Check valid"
hsocheck offset_out "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "HSO_offset_out: OffsetSrf +1 is exact (hole radius 2 -> 1)"
hsovol offset_out 1684 1697 "HSO_offset_out: Volume = (144 - pi) * 12 = 1690.30"
hsocheck offset_out "Object [0-9]*: valid" "HSO_offset_out: ...Check valid"
hsocheck offset_in "OffsetSrf: distance -1, 1 object(s), 1 exact B-rep" "HSO_offset_in: OffsetSrf -1 is exact (hole radius 2 -> 3)"
hsovol offset_in 283 288 "HSO_offset_in: Volume = (64 - 9 pi) * 8 = 285.82"
hsocheck offset_in "Object [0-9]*: valid" "HSO_offset_in: ...Check valid"
hsocheck offset_solid "solid, 1 exact B-rep" "HSO_offset_solid: Solid=Yes +1 (hollow wall between the plate and its offset) is exact"
hsovol offset_solid 812 820 "HSO_offset_solid: Volume = 1690.30 - 874.34 = 815.96"
hsocheck offset_solid "Object [0-9]*: valid" "HSO_offset_solid: ...Check valid"
hsocheck offset_solid_in "solid, 1 exact B-rep" "HSO_offset_solid_in: Solid=Yes -1 is exact"
hsovol offset_solid_in 585 592 "HSO_offset_solid_in: Volume = 874.34 - 285.82 = 588.52"
hsocheck offset_solid_in "Object [0-9]*: valid" "HSO_offset_solid_in: ...Check valid"
hsocheck offset_vanish "exact B-rep offset not used (the hole would vanish at that offset" "HSO_declined: OffsetSrf +2 (hole radius 2 - 2 = 0) is refused WITH the reason"
hsocheck offset_wall "exact B-rep offset not used (the hole would reach the outer wall at that offset" "HSO_declined: OffsetSrf -3 (hole radius 5 against an outer half-width 2) is refused WITH the reason"
hsocheck shell_wall "exact B-rep shell not used (the hole would reach the outer wall at that offset" "HSO_declined: Shell 3 (cavity hole radius 5 against an inset half-width 2) is refused WITH the reason"
hsocheck shell_collapse "exact B-rep shell not used (the prism would collapse between its caps at that offset" "HSO_declined: Shell 5 of a 10-high plate (2 * 5 >= 10) is refused WITH the reason"
hsocheck rect "Shell: thickness 1, closed, exact B-rep, volume" "HSO_rect: Shell of an off-centre hole (7,5) R2 in a 20 x 12 x 8 plate is exact"
hsovol rect 906 913 "HSO_rect: Volume = (240 - 4 pi) * 8 - (180 - 9 pi) * 6 = 909.7"
hsocheck rect "Object [0-9]*: valid" "HSO_rect: ...Check valid"
hsocheck rect_offset "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "HSO_rect_offset: OffsetSrf +1 of the off-centre hole plate is exact"
hsovol rect_offset 3035 3062 "HSO_rect_offset: Volume = (22 * 14 - pi) * 10 = 3048.6"
hsocheck rect_offset "Object [0-9]*: valid" "HSO_rect_offset: ...Check valid"
hsocheck tilted_shell "Shell: thickness 0.5, closed, exact B-rep, volume" "HSO_tilted: the plate rotated 37 degrees about (1,2,3) shells exactly"
hsovol tilted_shell 318 326 "HSO_tilted: Volume is unchanged by the rotation (322.06)"
hsocheck tilted_shell "Object [0-9]*: valid" "HSO_tilted: ...Check valid"
hsocheck tilted_offset "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "HSO_tilted_offset: the rotated plate offsets exactly"
hsovol tilted_offset 1684 1697 "HSO_tilted_offset: Volume is unchanged by the rotation (1690.30)"
hsocheck chain "Shell: thickness 0.5, closed, exact B-rep, volume" "HSO_chain: Shell of the exact OffsetSrf result is exact again (the exact plate is recognised too)"
hsovol chain 433 441 "HSO_chain: Volume = 1690.30 - (121 - 2.25 pi) * 11 = 437.1"
hsocheck chain "Object [0-9]*: valid" "HSO_chain: ...Check valid"
# --- both rims of ONE hole, and fillet + chamfer mixed on one hole (6 x 6 x 4 plate, hole R 1.5: V0 = 144 - 4.5 pi = 115.726;
#     chamfer w x c removes pi w c (R + c/3), fillet r removes 2 pi r^2 (R + r/2 - (pi/4)(R + r) + r/3))
hsocheck C_both "(radius 1; exact cone on the cylinder rim" "HSO_C_both: ChamferEdge of the upper rim is an exact cone..."
hsocheck C_both "(radius 0.5; exact cone on the cylinder rim" "HSO_C_both: ...and the SECOND pick of the same run (lower rim, next to the first cone) is an exact cone too (before: the classifier saw the cone and fell back)"
hsocheck C_both "9 faces, 19 edges, closed solid" "HSO_C_both: ...one closed solid of 9 exact faces"
hsovol C_both 108.3 109.0 "HSO_C_both: Volume = 115.726 - 5.7596 - 1.3090 = 108.657"
hsocheck C_both "Object 3: valid" "HSO_C_both: ...Check valid"
hsocheck M_fc "upper radius 1; exact torus patch" "HSO_M_fc: FilletEdge of the upper rim is exact..."
hsocheck M_fc "(radius 0.5; exact cone on the cylinder rim" "HSO_M_fc: ...then ChamferEdge of the lower rim keeps the torus and adds an exact cone"
hsocheck M_fc "9 faces, 19 edges, closed solid" "HSO_M_fc: ...9 exact faces, closed"
hsovol M_fc 111.8 112.4 "HSO_M_fc: Volume = 115.726 - 2.3238 - 1.3090 = 112.093"
hsocheck M_fc "Object 3: valid" "HSO_M_fc: ...Check valid"
hsocheck M_cf "(radius 1; exact cone on the cylinder rim" "HSO_M_cf: ChamferEdge of the upper rim is an exact cone..."
hsocheck M_cf "upper chamfer 1 x 1, lower radius 0.5; exact torus patches" "HSO_M_cf: ...then FilletEdge of the lower rim keeps the cone and adds an exact torus"
hsovol M_cf 109.1 109.8 "HSO_M_cf: Volume = 115.726 - 5.7596 - 0.5433 = 109.423"
hsocheck M_cf "Object 3: valid" "HSO_M_cf: ...Check valid"
hsocheck F_two_runs "upper radius 1, lower radius 0.5; exact torus patches" "HSO_F_two_runs: two separate FilletEdge runs, one per rim, end in one exact solid with both torus patches"
hsovol F_two_runs 112.6 113.2 "HSO_F_two_runs: Volume = 115.726 - 2.3238 - 0.5433 = 112.859"
hsocheck F_two_runs "Object 3: valid" "HSO_F_two_runs: ...Check valid"
# --- a cylindrical BOSS on a plate (BooleanUnion of a 10 x 10 x 4 box and a cylinder R 2, 4 high, resting on its top face):
#     V0 = 400 + 16 pi = 450.265. The base blend is CONCAVE and ADDS material; before, the boss was read as a blind hole and its
#     top-rim fillet silently turned the boss into a hole (Volume 749.1), the base fillet failed ('could not build a watertight result').
hsocheck BOSS_base "FilletEdge: boss of object 3 replaced with an exact fillet (base radius 0.5; exact torus patch at the boss, 9 faces, closed solid)" "HSO_BOSS_base: the BASE of a boss gets an exact fillet torus (concave, material added)"
hsovol BOSS_base 450.6 451.3 "HSO_BOSS_base: Volume = 450.265 + 2 pi (2*0.25*(1 - pi/4) + 0.125*(5/6 - pi/4)) = 450.977"
hsocheck BOSS_base "9 faces, 17 edges, closed solid" "HSO_BOSS_base: ...a closed solid of 9 exact faces"
hsocheck BOSS_base "Object 3: valid" "HSO_BOSS_base: ...Check valid"
hsocheck BOSS_top "FilletEdge: boss of object 3 replaced with an exact fillet (top radius 0.5; exact torus patch at the boss, 9 faces, closed solid)" "HSO_BOSS_top: the TOP rim of a boss is an exact convex torus fillet (before: read as a blind hole, Volume 749.1; now exact)"
hsovol BOSS_top 449.3 449.9 "HSO_BOSS_top: Volume = 450.265 - 2 pi (2*0.25*(1 - pi/4) - 0.125*(5/6 - pi/4)) = 449.629"
hsocheck BOSS_top "Object 3: valid" "HSO_BOSS_top: ...Check valid"
hsocheck BOSS_both "(base radius 0.5, top radius 0.5; exact torus patches at the boss, 10 faces, closed solid)" "HSO_BOSS_both: base and top rim picked in one run become one exact solid"
hsovol BOSS_both 450.0 450.6 "HSO_BOSS_both: Volume = 450.265 + 0.7118 - 0.6365 = 450.340"
hsocheck BOSS_both "Object 3: valid" "HSO_BOSS_both: ...Check valid"
hsocheck BOSS_chamfer_base "ChamferEdge: edge [0-9]* of object 3 replaced with an exact chamfer (radius 0.5; exact cone" "HSO_BOSS_chamfer_base: ChamferEdge of the boss base is an exact cone"
hsovol BOSS_chamfer_base 451.6 452.3 "HSO_BOSS_chamfer_base: Volume = 450.265 + pi*0.25*(2 + 0.5/3) = 451.967"
hsocheck BOSS_chamfer_base "9 faces, 17 edges, closed solid" "HSO_BOSS_chamfer_base: ...9 exact faces"
hsocheck BOSS_chamfer_base "Object 3: valid" "HSO_BOSS_chamfer_base: ...Check valid"
hsocheck BOSS_chamfer_top "ChamferEdge: edge [0-9]* of object 3 replaced with an exact chamfer (radius 0.5; exact cone" "HSO_BOSS_chamfer_top: ChamferEdge of the boss top rim is an exact cone"
hsovol BOSS_chamfer_top 448.5 449.1 "HSO_BOSS_chamfer_top: Volume = 450.265 - pi*0.25*(2 - 0.5/3) = 448.825"
hsocheck BOSS_chamfer_top "Object 3: valid" "HSO_BOSS_chamfer_top: ...Check valid"
hsocheck BOSS_seq_c "ChamferEdge: edge [0-9]* of object 3 replaced with an exact chamfer (radius 0.5; exact cone" "HSO_BOSS_seq_c: two separate ChamferEdge runs (base, then top) on one boss: both are exact cones (before: the second fell back to a mesh)"
hsovol BOSS_seq_c 450.2 450.8 "HSO_BOSS_seq_c: Volume = 450.265 + 1.7017 - 1.4399 = 450.527"
hsocheck BOSS_seq_c "10 faces, 19 edges, closed solid" "HSO_BOSS_seq_c: ...one closed solid of 10 exact faces"
hsocheck BOSS_seq_c "Object 3: valid" "HSO_BOSS_seq_c: ...Check valid"
hsocheck BOSS_seq_f "(base radius 0.5, top radius 0.5; exact torus patches at the boss, 10 faces, closed solid)" "HSO_BOSS_seq_f: two separate FilletEdge runs (base, then top) on one boss end in one exact solid with both tori"
hsovol BOSS_seq_f 450.0 450.6 "HSO_BOSS_seq_f: Volume = 450.265 + 0.7118 - 0.6365 = 450.340"
hsocheck BOSS_seq_f "Object 3: valid" "HSO_BOSS_seq_f: ...Check valid"
hsocheck BOSS_mixed "ChamferEdge: edge [0-9]* of object 3 replaced with an exact chamfer (radius 0.5; exact cone" "HSO_BOSS_mixed: fillet on the base, then a chamfer on the top rim of the same boss is exact"
hsovol BOSS_mixed 449.2 449.9 "HSO_BOSS_mixed: Volume = 450.265 + 0.7118 - 1.4399 = 449.537"
hsocheck BOSS_mixed "10 faces, 19 edges, closed solid" "HSO_BOSS_mixed: ...10 exact faces, closed"
hsocheck BOSS_mixed "Object 3: valid" "HSO_BOSS_mixed: ...Check valid"
hsocheck BOSS_toobig "exact cylinder-rim fillet not used (the base blend would run off the plate)" "HSO_BOSS_toobig: a base radius 3 (R + 3 = 5 reaches the plate edge) is refused WITH the reason"
if grep -q "^FAIL" <<<"$HSO_OUT"; then echo "FAIL hso script reported an in-script FAIL"; fail=1; fi

# ---------------------------------------------------------------------------
# TS4_: ToSubD of a torus and of right prisms (tosubd4_script.txt). A torus used
# to go through the dense grid tessellation (an 18432-face triangle cage at the
# default 0.001 tolerance); an extruded L, or a box with FilletEdge-rounded
# vertical edges, through the dense chord-tolerance path (thousands of
# triangles, usually unverified). Now the torus gets the face's own N x M quad
# grid and a right prism one quad ring per profile column plus ear-clipped flat
# caps; both are interpolated onto the exact surface and the Catmull-Clark limit
# surface is MEASURED against it (a cage is only accepted within the document
# tolerance, and a prism ladder that verifies only marginally must be confirmed
# by its finer neighbour, else the cage is refused with the reason printed and
# the dense path is used). The two-adjacent-rounded-edges box is the regression:
# a line tangent at one end and sharp at the other used to end in a sliver column
# next to the sharp corner, whose interpolating crease overshot the corner (every
# finer rung 0.13-0.24, the coarsest verified at 0.00096 by luck). Ranges rather
# than exact numbers (tessellated Volumes and deviations depend on the platform's
# float evaluation). Eight solids, in script order: torus R5 r2, torus R6 r2,
# torus R20 r1, extruded L, box with 4 rounded edges, 2 adjacent, 2 opposite and
# 1 rounded edge.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  TS4="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/tosubd4_script.txt" 2>&1)" || { echo "$TS4"; echo "FAIL: tosubd4 script exited non-zero"; exit 1; }
else
  TS4="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/tosubd4_script.txt" 2>&1)" || { echo "$TS4"; echo "FAIL: tosubd4 script exited non-zero"; exit 1; }
fi
ts4check() { if grep -q -- "$1" <<<"$TS4"; then echo "ok   $2"; else echo "FAIL $2"; near "$TS4" "$1"; fail=1; fi; }
# in range: ts4range VALUE LO HI DESC
ts4range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t TS4_TOSUBD < <(grep -F "history: ToSubD: created" <<<"$TS4" || true)
mapfile -t TS4_LIST < <(grep -E "^history:   [0-9]+ faces, [0-9]+ edges, [0-9]+ vertices, [0-9]+ creases" <<<"$TS4" || true)
mapfile -t TS4_VOL < <(grep -o "Volume = [0-9.e+-]*" <<<"$TS4" | awk '{print $3}' || true)
if [ "${#TS4_TOSUBD[@]}" -eq 8 ] && [ "${#TS4_LIST[@]}" -eq 8 ]; then
  echo "ok   tosubd4 script printed 8 ToSubD lines and 8 SubD List lines"
  ts4dev() { sed -E 's/.*worst measured deviation ([0-9.]+)\).*/\1/' <<<"${TS4_TOSUBD[$1]}"; }
  ts4faces() { sed -E 's/^history: +([0-9]+) faces, .*/\1/' <<<"${TS4_LIST[$1]}"; }
  ts4vef() { sed -E 's/^history: +([0-9]+) faces, ([0-9]+) edges, ([0-9]+) vertices.*/\3 \2 \1/' <<<"${TS4_LIST[$1]}"; }
  ts4name=("torus R=5 r=2" "torus R=6 r=2" "torus R=20 r=1" "extruded L" "box with 4 rounded edges" "box with 2 ADJACENT rounded edges (regression)" "box with 2 opposite rounded edges" "box with 1 rounded edge")
  ts4kind=(torus torus torus prism prism prism prism prism)
  ts4flo=(400 400 400 20 300 300 200 150)
  ts4fhi=(1100 1100 1100 40 1500 1500 1500 1500)
  for i in 0 1 2 3 4 5 6 7; do
    if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.0[0-9]*)" <<<"${TS4_TOSUBD[$i]}"; then
      echo "ok   ToSubD of the ${ts4name[$i]} is verified within the document tolerance"
      ts4range "$(ts4dev "$i")" 0 0.001 "...worst measured deviation of the ${ts4name[$i]}"
    else
      echo "FAIL ToSubD of the ${ts4name[$i]} is not verified: ${TS4_TOSUBD[$i]}"; fail=1
    fi
    if [ "${ts4kind[$i]}" = torus ]; then ts4want="analytic torus cage ("; else ts4want="analytic right-prism cage ("; fi
    if grep -qF -- "$ts4want" <<<"${TS4_TOSUBD[$i]}"; then
      echo "ok   ...the ${ts4name[$i]} reports its analytic cage"
    else
      echo "FAIL the ${ts4name[$i]} does not report '$ts4want': ${TS4_TOSUBD[$i]}"; fail=1
    fi
    ts4range "$(ts4faces "$i")" "${ts4flo[$i]}" "${ts4fhi[$i]}" "...cage face count of the ${ts4name[$i]} (the dense cage was thousands of triangles; the torus 18432)"
    read -r ts4v ts4e ts4f <<<"$(ts4vef "$i")"
    if [ "${ts4kind[$i]}" = torus ]; then ts4chi=0; else ts4chi=2; fi
    if [ "$((ts4v - ts4e + ts4f))" -eq "$ts4chi" ]; then echo "ok   ...Euler characteristic of the ${ts4name[$i]} is $ts4chi ($ts4v - $ts4e + $ts4f)"; else echo "FAIL Euler characteristic of the ${ts4name[$i]} is $((ts4v - ts4e + ts4f)), expected $ts4chi"; fail=1; fi
  done
  # The 2-adjacent-edges box now converges; its accepted deviation must sit comfortably inside the tolerance (not a lucky marginal rung).
  ts4range "$(ts4dev 5)" 0 0.0008 "...the 2-adjacent-edges deviation is comfortably inside the tolerance (before the fix the coarsest rung verified at 0.00096 and every finer one failed at 0.13-0.24)"
  ts4range "$(ts4dev 3)" 0 0.0001 "...the extruded L (straight edges only) is exact"
  # Volumes in script order: torus net x3 (cage, +1, +2 SubDivide rounds), L net x3, box Brep, box net x3, 2-adjacent Brep.
  if [ "${#TS4_VOL[@]}" -eq 11 ]; then
    ts4range "${TS4_VOL[0]}" 395 420 "torus R=5 r=2 control-net Volume (an interpolated cage's net overshoots the exact 394.78)"
    ts4range "${TS4_VOL[2]}" 393 398 "...and after two SubDivide rounds the net is back near 2 pi^2 R r^2 = 394.78"
    ts4range "${TS4_VOL[3]}" 383 385 "extruded L control-net Volume = area 64 x height 6 = 384 (a prism cage's net is exact)"
    ts4range "${TS4_VOL[6]}" 594 596 "box with 4 rounded edges: Brep Volume = 6 x (100 - 4 (1 - pi/4)) = 594.85"
    ts4range "${TS4_VOL[10]}" 588 591 "box with 2 adjacent rounded edges: Brep Volume = 6 x (100 - 2 (4 - pi)) = 589.70"
  else
    echo "FAIL tosubd4 script printed ${#TS4_VOL[@]} Volume lines (expected 11)"; fail=1
  fi
else
  echo "FAIL tosubd4 script printed ${#TS4_TOSUBD[@]} ToSubD / ${#TS4_LIST[@]} List lines (expected 8 / 8)"; fail=1
fi
ts4check "gl_error=0" "tosubd4 script ran without OpenGL errors"

# ---------------------------------------------------------------------------
# TUTV_: record EVERY tutorial to an mp4 and probe each one with ffprobe (non-zero
# duration and frame count). The TUT_ section above records and deeply verifies only
# tutorial 04 into a scratch directory that is deleted; this one keeps the videos so
# CI can upload them as a workflow artifact. Runs only when DINO8_TUTORIAL_VIDEO_DIR
# names an output directory (CI sets it); otherwise one skip line. The videos are
# silent stills-per-command renderings with caption files, not narrated and not
# published anywhere (docs/TUTORIALS.md). Nothing here is committed.
TUTV_DIR="${DINO8_TUTORIAL_VIDEO_DIR:-}"
if [ -z "$TUTV_DIR" ]; then
  echo "skip TUTV_*: set DINO8_TUTORIAL_VIDEO_DIR=DIR to record every tutorial into DIR and probe each video"
elif [ "$(uname -s)" != "Linux" ] || ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL TUTV_: DINO8_TUTORIAL_VIDEO_DIR is set but this needs Linux with ffmpeg, ffprobe and python3"; fail=1
else
  mkdir -p "$TUTV_DIR"
  TUTV_N=0
  for TUTV_PATH in "$HERE"/../tutorials/[0-9][0-9]-*/; do
    TUTV_NAME="$(basename "$TUTV_PATH")"
    TUTV_N=$((TUTV_N + 1))
    TUTV_REC="$(timeout 900 python3 "$HERE/../tutorials/record.py" --bin "$BIN" --id "$TUTV_NAME" --out "$TUTV_DIR" 2>&1)" || { echo "$TUTV_REC" | tail -20; echo "FAIL TUTV_$TUTV_NAME: recorder exited non-zero"; fail=1; continue; }
    TUTV_VID="$TUTV_DIR/$TUTV_NAME/$TUTV_NAME.mp4"
    TUTV_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TUTV_VID" 2>/dev/null || true)"
    TUTV_FR="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$TUTV_VID" 2>/dev/null || true)"
    if [ -n "$TUTV_DUR" ] && [ -n "$TUTV_FR" ] && [ "$TUTV_FR" -gt 0 ] 2>/dev/null && python3 -c "import sys; sys.exit(0 if float('$TUTV_DUR') > 0 else 1)" 2>/dev/null; then
      echo "ok   TUTV_$TUTV_NAME: ffprobe: $TUTV_FR frames, $TUTV_DUR s ($(stat -c %s "$TUTV_VID") bytes)"
    else
      echo "FAIL TUTV_$TUTV_NAME: ffprobe found no video, or zero duration / frames (duration '$TUTV_DUR', frames '$TUTV_FR')"; fail=1
    fi
  done
  if [ "$TUTV_N" -eq 10 ]; then echo "ok   TUTV_count: all 10 tutorials were recorded and probed"; else echo "FAIL TUTV_count: expected 10 tutorials, found $TUTV_N"; fail=1; fi
fi

# ---------------------------------------------------------------------------
# KWR: kernel capabilities wired into the app (kwr_script.txt).
#  - OffsetSrf of a SURFACE object now calls NurbsSurface::Offset: the exact rational closed form for a
#    plane / sphere / cylinder / cone / torus (the old direct OffsetRefit call always returned a non-rational fit),
#    the tolerance-controlled refit otherwise, and the command output states which path ran and the deviation
#    measured against S(u,v) + d*N(u,v). An analytic surface whose offset folds through its axis is refused.
#    UpdateHistory re-runs the same function.
#  - ChamferEdge Distance/Angle on a plain capped cylinder / cone frustum (used to be refused, "has no
#    cylinder-rim construction") and FilletEdge on a cone-frustum rim (used to fall to the approximate mesh
#    fillet) now call kernel::ChamferCapRimAngle / FilletCapRim(s); a solid the kernel classifier refuses falls
#    through with the printed reason. Convention for the closed rim circle (it has no loop direction, so no
#    "face 1"): Distance is measured ACROSS THE CAP and Angle from the cap plane.
# Closed forms (all checked here): cylinder surface area 2*pi*r*h; tapered-cone surface offset area
# pi*(R0+R1+2cos(phi))*h/cos(phi) with the 10 degree draft; Brep sphere offset volume 4/3*pi*6^3; and, for every
# chamfer / fillet, Pappus V = V0 - 2*pi*rho*A with A the (r,z) corner region cut away at the rim and rho its centroid
# radius (chamfer triangle: corner C, cap point at the distance, wall point at distance*sin(a)/sin(theta+a) with
# theta the rim's interior profile angle; fillet: corner minus the rolling-ball arc segment, tangent length
# r/tan(theta/2)). Volumes are read from the display mesh (measured 0.05-0.2% low here), so the ranges are
# +-0.6%; face/edge counts and "closed solid" are topological and exact. Windows tessellates slightly
# differently, hence ranges everywhere.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  KWRO="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/kwr_script.txt" 2>&1)" || { echo "$KWRO"; echo "FAIL: kwr script exited non-zero"; exit 1; }
else
  KWRO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/kwr_script.txt" 2>&1)" || { echo "$KWRO"; echo "FAIL: kwr script exited non-zero"; exit 1; }
fi
kwrblock() { awk -v name="$1" '$0 ~ ("Unknown command: KWRBEGIN_" name "$") { on = 1; next } on && /Unknown command: KWRBEGIN_/ { exit } on { print }' <<<"$KWRO"; }
kwrcheck() { local blk; blk="$(kwrblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (OffsetSrf|ChamferEdge|FilletEdge|!|Object|  [0-9]|Volume|Area)" <<<"$blk" | head -8 | sed 's/^/     actual:   /' || true; fail=1; fi; }
kwrnot() { local blk; blk="$(kwrblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "FAIL $3"; echo "     unexpected: $2"; fail=1; else echo "ok   $3"; fi; }
# kwrnum NAME LABEL N MIN MAX DESC: the N-th "history: <LABEL> = V" value of the case lies in [MIN, MAX]
kwrnum() {
  local blk v; blk="$(kwrblock "$1")"
  v="$(grep -E "^history: $2 = " <<<"$blk" | sed -n "${3}p" | sed -E 's/^history: [A-Za-z ]+ = ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$4" -v hi="$5" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $6 ($2 $v in [$4, $5])"; else echo "FAIL $6 ($2 '${v:-none}' not in [$4, $5])"; fail=1; fi
}
# kwrdev NAME N MAX DESC: the N-th printed "measured deviation from the true offset locus X" is below MAX
kwrdev() {
  local blk v; blk="$(kwrblock "$1")"
  v="$(grep -E "measured deviation from the true offset locus " <<<"$blk" | sed -n "${2}p" | sed -E 's/.*true offset locus ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v hi="$3" 'BEGIN { exit !(v + 0 <= hi) }'; then echo "ok   $4 (measured deviation $v <= $3)"; else echo "FAIL $4 (measured deviation '${v:-none}' not <= $3)"; fail=1; fi
}
# kwrbbz NAME ZMIN_LO ZMIN_HI ZMAX_LO ZMAX_HI DESC: the case's "Bounding box min x,y,z max x,y,z" z extents
kwrbbz() {
  local blk l zmin zmax; blk="$(kwrblock "$1")"
  l="$(grep -E "^history: Bounding box min " <<<"$blk" | tail -1 || true)"
  zmin="$(sed -E 's/.*min [-0-9.e+]+,[-0-9.e+]+,([-0-9.e+]+) max.*/\1/' <<<"$l")"
  zmax="$(sed -E 's/.*max [-0-9.e+]+,[-0-9.e+]+,([-0-9.e+]+).*/\1/' <<<"$l")"
  if [ -n "$l" ] && awk -v a="$zmin" -v b="$zmax" -v a0="$2" -v a1="$3" -v b0="$4" -v b1="$5" 'BEGIN { exit !(a >= a0 && a <= a1 && b >= b0 && b <= b1) }'; then echo "ok   $6 (z extent $zmin .. $zmax)"; else echo "FAIL $6 (z extent '$zmin' .. '$zmax' outside [$2,$3] .. [$4,$5])"; fail=1; fi
}
# --- OffsetSrf of a cylinder SURFACE: exact analytic, measured
kwrcheck O_cyl "OffsetSrf: object 2 - exact analytic offset (closed-form rational surface on the input's own parametrization)" "KWR_O_cyl: OffsetSrf of a cylinder surface states the exact analytic path (before: the non-rational OffsetRefit fit, nothing stated)"
kwrdev O_cyl 1 1e-9 "KWR_O_cyl: +1 offset measured against S + d*N: deviation at rounding level"
kwrdev O_cyl 2 1e-9 "KWR_O_cyl: -1 offset measured deviation at rounding level"
kwrnum O_cyl Area 1 199.6 202.5 "KWR_O_cyl: +1 -> radius 4: Area = 2*pi*4*8 = 201.06"
kwrnum O_cyl Area 2 99.8 101.3 "KWR_O_cyl: -1 -> radius 2: Area = 2*pi*2*8 = 100.53"
kwrcheck O_cyl "OffsetSrf: object 2 not offset - recognised plane/sphere/cylinder/cone/torus: the exact offset was refused" "KWR_O_cyl: -3 (radius 0) is refused WITH the kernel's reason (before: the first-order fallback built a degraded surface)"
kwrcheck O_cyl "OffsetSrf: distance -3, 0 object(s)" "KWR_O_cyl: ...and no object is made for the refused distance"
kwrcheck O_cyl "4 object(s) selected" "KWR_O_cyl: circle, cylinder and the two good offsets remain (4 objects)"
# --- OffsetSrf of a tapered-cone SURFACE
kwrcheck O_cone "exact analytic offset (closed-form rational surface on the input's own parametrization)" "KWR_O_cone: the tapered cone surface takes the exact analytic offset"
kwrdev O_cone 1 1e-9 "KWR_O_cone: measured deviation at rounding level"
kwrnum O_cone Area 1 216.9 220.0 "KWR_O_cone: offset area pi*(R0+R1+2cos10)*8/cos10 = 218.43"
kwrbbz O_cone 0.165 0.182 8.165 8.182 "KWR_O_cone: the offset cone is raised by d*sin(10deg) = 0.1736 at both ends (z 0.1736 .. 8.1736)"
# --- control: Brep sphere stays on the exact B-rep path
kwrcheck O_sphere "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "KWR_O_sphere: the Brep sphere offset is still the exact B-rep"
kwrnum O_sphere Volume 1 899.4 910.2 "KWR_O_sphere: Volume = 4/3*pi*6^3 = 904.78"
kwrcheck O_sphere "Object 2: valid" "KWR_O_sphere: Check valid"
# --- history: UpdateHistory re-runs the same function
kwrnum O_hist Area 1 199.6 202.5 "KWR_O_hist: before: offset cylinder (r 4, h 8) Area = 201.06"
kwrnum O_hist Area 2 349.4 354.3 "KWR_O_hist: after Scale 2 of the circle + UpdateHistory: radius 6 + 1, Area = 2*pi*7*8 = 351.86"
kwrcheck O_hist "UpdateHistory: 2 object(s) re-evaluated" "KWR_O_hist: UpdateHistory rebuilt the extrusion and its offset"
# --- ChamferEdge Distance/Angle on a plain capped cylinder
kwrcheck C_cyl45 "exact kernel cap-rim bevel (cone), distance 2 across the cap, 45 degrees from the cap plane" "KWR_C_cyl45: Distance/Angle on the cylinder rim is now an exact kernel bevel (before: refused)"
kwrcheck C_cyl45 "4 faces, 7 edges, closed solid" "KWR_C_cyl45: 4 faces (wall, cone bevel, two caps), closed solid"
kwrnum C_cyl45 Volume 1 1507.3 1525.4 "KWR_C_cyl45: Volume = pi*25*20 - 2*pi*(13/3)*2 = 1516.34"
kwrcheck C_cyl45 "Object 1: valid" "KWR_C_cyl45: Check valid"
kwrcheck C_cyl30 "30 degrees from the cap plane" "KWR_C_cyl30: bottom rim at 30 degrees"
kwrnum C_cyl30 Volume 1 1530.1 1548.6 "KWR_C_cyl30: wall distance 2*sin30/sin120 = 1.1547, Volume = 1570.80 - 31.44 = 1539.36"
kwrcheck C_cyl30 "4 faces, 7 edges, closed solid" "KWR_C_cyl30: 4 faces, closed solid"
kwrcheck C_cyl30 "Object 1: valid" "KWR_C_cyl30: Check valid"
# --- cone frustum: obtuse top rim, acute bottom rim
kwrcheck C_tc_top30 "exact kernel cap-rim bevel (cone), distance 1 across the cap, 30 degrees from the cap plane" "KWR_C_tc_top30: Distance/Angle on the frustum's obtuse top rim is an exact kernel bevel"
kwrnum C_tc_top30 Volume 1 504.5 510.6 "KWR_C_tc_top30: Pappus Volume = 513.13 - 5.557 = 507.57"
kwrcheck C_tc_top30 "4 faces, 7 edges, closed solid" "KWR_C_tc_top30: 4 faces, closed solid"
kwrcheck C_tc_top30 "Object 1: valid" "KWR_C_tc_top30: Check valid"
kwrcheck C_tc_bot60 "60 degrees from the cap plane" "KWR_C_tc_bot60: Distance/Angle on the frustum's acute bottom rim"
kwrnum C_tc_bot60 Volume 1 491.6 497.6 "KWR_C_tc_bot60: Pappus Volume = 513.13 - 18.513 = 494.61 (wall distance 1.3119)"
kwrcheck C_tc_bot60 "4 faces, 7 edges, closed solid" "KWR_C_tc_bot60: 4 faces, closed solid"
kwrcheck C_tc_bot60 "Object 1: valid" "KWR_C_tc_bot60: Check valid"
# --- control: Distance1/Distance2 keeps the app's own exact revolved bevel
kwrcheck C_tc_dist "distance1 1, distance2 2; exact cone on the cylinder rim, distance1 along the wall and distance2 across the cap" "KWR_C_tc_dist: control, Distance1/Distance2 on the frustum is unchanged (app's own exact bevel)"
kwrnot C_tc_dist "kernel cap-rim" "KWR_C_tc_dist: ...and does not go through the kernel cap-rim path"
# --- refusals fall through with the reason, solid untouched
kwrcheck C_cone_refused "kernel cap-rim attempt: dino8::kernel::Brep::MixedFaces" "KWR_C_cone_refused: a full apex cone is refused WITH the kernel classifier's reason and falls through"
kwrnum C_cone_refused Volume 1 259.0 264.2 "KWR_C_cone_refused: the cone is untouched, Volume = pi*25*10/3 = 261.8"
kwrcheck C_hole_refused "kernel cap-rim attempt: dino8::kernel::ChamferCapRimAngle: " "KWR_C_hole_refused: a hole plate is refused WITH the kernel classifier's reason (not a plain capped cylinder)"
kwrnum C_hole_refused Volume 1 115.1 116.4 "KWR_C_hole_refused: the plate is untouched, Volume = 144 - pi*2.25*4 = 115.73"
# --- FilletEdge on a cone frustum
kwrcheck F_tc_both "exact kernel torus patches tangent to the cap and the wall, 5 faces, closed solid" "KWR_F_tc_both: both frustum rims in one FilletCapRims call (before: the approximate mesh fillet)"
kwrcheck F_tc_both "5 faces, 9 edges, closed solid" "KWR_F_tc_both: 5 faces, closed solid"
kwrnum F_tc_both Volume 1 497.9 503.9 "KWR_F_tc_both: Pappus Volume = 513.13 - 2.390 - 9.837 = 500.90"
kwrcheck F_tc_both "Object 1: valid" "KWR_F_tc_both: Check valid"
kwrcheck F_tc_top "exact kernel torus patch tangent to the cap and the wall, 4 faces, closed solid" "KWR_F_tc_top: the obtuse top rim alone"
kwrnum F_tc_top Volume 1 507.7 513.8 "KWR_F_tc_top: Pappus Volume = 513.13 - 2.390 = 510.74"
kwrcheck F_tc_top "Object 1: valid" "KWR_F_tc_top: Check valid"
kwrcheck F_tc_bot "4 faces, 7 edges, closed solid" "KWR_F_tc_bot: the acute bottom rim alone, 4 faces, closed solid"
kwrnum F_tc_bot Volume 1 500.3 506.3 "KWR_F_tc_bot: Pappus Volume = 513.13 - 9.837 = 503.29"
kwrcheck F_tc_bot "Object 1: valid" "KWR_F_tc_bot: Check valid"
kwrcheck F_tc_big "exact kernel cap-rim fillet not used (dino8::kernel::FilletCapRim: a blend would consume the whole cap" "KWR_F_tc_big: a radius that consumes the small cap is refused WITH the kernel's reason and the old path runs"
# --- control: the plain cylinder keeps the app's own exact torus fillet
kwrcheck F_cyl "cylinder rim(s) of object 1 replaced with an exact fillet (top radius 1; exact quarter-torus patch" "KWR_F_cyl: control, the plain cylinder fillet is still the app's own exact torus"
kwrnot F_cyl "kernel torus" "KWR_F_cyl: ...not the kernel cap-rim path"
kwrnum F_cyl Volume 1 1555.0 1573.7 "KWR_F_cyl: Pappus Volume = 1570.80 - 6.44 = 1564.36"

# SBL_: sealed exact Booleans (sbl_script.txt, sbl_script_fb.txt). The exact general-Boolean path now tries
# kernel::SealGeneralBooleanResult (BooleanCombineGeneralSealed's sewing half) FIRST: a result that seals is
# ON_Brep::IsValid + IsSolid with REAL inner loops (no keyhole slits) and carries an exact divergence-theorem
# volume checked against the operands' bounds; Check is asserted valid on these results for the first time. A
# refusal falls back to the previous sewing path unchanged (the far-from-origin case below, and the sealed-off
# control run). Every volume/area is read against a closed form; display Volume comes from the closed display mesh.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SBL_OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/sbl_script.txt" 2>&1)" || { echo "$SBL_OUT"; echo "FAIL: SBL_ script exited non-zero"; exit 1; }
  SBL_FB="$(DINO8_NO_SEALED_BOOLEAN=1 timeout 900 "$BIN" --smoke 60 --script "$HERE/sbl_script_fb.txt" 2>&1)" || { echo "$SBL_FB"; echo "FAIL: SBL_ fallback script exited non-zero"; exit 1; }
else
  SBL_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/sbl_script.txt" 2>&1)" || { echo "$SBL_OUT"; echo "FAIL: SBL_ script exited non-zero"; exit 1; }
  SBL_FB="$(DINO8_NO_SEALED_BOOLEAN=1 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/sbl_script_fb.txt" 2>&1)" || { echo "$SBL_FB"; echo "FAIL: SBL_ fallback script exited non-zero"; exit 1; }
fi
sblblock() { awk -v name="$1" '$0 ~ ("Unknown command: SBLBEGIN_" name "$") { on = 1; next } on && /Unknown command: SBLBEGIN_|Unknown command: SBLEND/ { exit } on { print }' <<<"${2:-$SBL_OUT}"; }
# sblcheck NAME PATTERN DESC [OUTPUT]: the case's block must contain PATTERN (a grep regex)
sblcheck() { local blk; blk="$(sblblock "$1" "${4:-$SBL_OUT}")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   SBL_$1: $3"; else echo "FAIL SBL_$1: $3"; echo "     expected: $2"; { grep -E "^history: (Boolean|Shell|Object|  [0-9]|Volume|Area|!)" <<<"$blk" || true; } | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
# sblnot NAME PATTERN DESC: the case's block must NOT contain PATTERN
sblnot() { local blk; blk="$(sblblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "FAIL SBL_$1: $3"; fail=1; else echo "ok   SBL_$1: $3"; fi; }
# sblnum NAME REGEX MIN MAX DESC: the first number following REGEX (a grep -oE regex ending right before the number) in the block lies in [MIN, MAX]
sblnum() {
  local blk v; blk="$(sblblock "$1")"
  v="$({ grep -oE -- "$2[-0-9.eE+]+" <<<"$blk" || true; } | head -1 | sed -E "s/^$2//")"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   SBL_$1: $5 (measured $v in [$3, $4])"; else echo "FAIL SBL_$1: $5 (measured '${v:-none}' not in [$3, $4])"; fail=1; fi
}
SBL_SEAL="sealed: valid B-rep with real inner loops, exact volume"
# --- box 10^3 minus a through-hole cylinder r2: V = 874.34, A = 700.53; two keyholes (one per end face) opened into real inner loops
sblcheck cut_through "7 face(s), $SBL_SEAL" "box minus a through-hole cylinder takes the SEALED path (7 faces)"
sblcheck cut_through "2 keyhole(s) opened" "...both end faces' keyhole slits were opened into real inner loops"
sblcheck cut_through "^history: Object 3: valid$" "...Check reports the Boolean result a VALID B-rep (before: ON_Brep.m_T[..].m_type = seam but m_iso is not N/E/W/S_iso)"
sblcheck cut_through "7 faces, [0-9]* edges, closed solid" "...List reports a closed solid"
sblnum cut_through "exact volume " 873.7 875.0 "exact kernel volume = 1000 - pi*2^2*10 = 874.34"
sblnum cut_through "^history: Volume = " 872.5 876.5 "display Volume (closed display mesh) = 874.34"
sblnum cut_through "^history: Area = " 698 703 "Area = 600 - 2*pi*4 + 2*pi*2*10 = 700.53"
sblcheck cut_through "mesh cross-check" "...the independent mesh-boolean cross-check still ran"
# --- union with a piercing cylinder: 10 faces, 1000 + pi*4*10 = 1125.66
sblcheck union_pierce "10 face(s), $SBL_SEAL" "box + piercing cylinder: sealed, 10 faces"
sblcheck union_pierce "2 keyhole(s) opened" "...2 keyholes opened"
sblcheck union_pierce "^history: Object 3: valid$" "...Check valid"
sblnum union_pierce "exact volume " 1123.5 1127.5 "exact volume = 1000 + pi*4*10 = 1125.66"
sblnum union_pierce "^history: Volume = " 1122 1128 "display Volume = 1125.66"
# --- intersection with the piercing cylinder: 3 faces, no keyhole, pi*4*10 = 125.66
sblcheck intersect_pierce "3 face(s), $SBL_SEAL" "box ^ piercing cylinder: sealed, 3 faces"
sblcheck intersect_pierce "0 keyhole(s) opened" "...no keyhole to open"
sblcheck intersect_pierce "^history: Object 3: valid$" "...Check valid"
sblnum intersect_pierce "exact volume " 124.6 126.6 "exact volume = pi*4*10 = 125.66"
# --- blind hole (1 keyhole, the open end) and boss
sblcheck blind "8 face(s), $SBL_SEAL" "blind hole: sealed, 8 faces"
sblcheck blind "1 keyhole(s) opened" "...1 keyhole opened (the open end only)"
sblcheck blind "^history: Object 3: valid$" "...Check valid"
sblnum blind "exact volume " 936.2 938.2 "exact volume = 1000 - pi*4*5 = 937.17"
sblcheck boss "8 face(s), $SBL_SEAL" "boss: sealed, 8 faces"
sblcheck boss "^history: Object 3: valid$" "...Check valid"
sblnum boss "exact volume " 1139.8 1142.9 "exact volume = 1000 + pi*9*5 = 1141.37"
sblnum boss "^history: Volume = " 1139 1144 "display Volume = 1141.37"
# --- cylinder-only solids: the cylinder wall is ONE untrimmed analytic face (integrated on its whole domain)
sblcheck tube "4 face(s), $SBL_SEAL" "tube (cylinder minus coaxial cylinder): sealed, 4 faces"
sblcheck tube "^history: Object 3: valid$" "...Check valid"
sblnum tube "exact volume " 653 666 "exact volume = pi*(25-4)*10 = 659.73 (polyline edges: <1% quadrature error)"
sblnum tube "^history: Volume = " 655 664 "display Volume = 659.73"
sblcheck stack "5 face(s), $SBL_SEAL" "stacked cylinders: sealed, 5 faces"
sblcheck stack "^history: Object 3: valid$" "...Check valid"
sblnum stack "exact volume " 323.5 329.5 "exact volume = pi*9*8 + pi*4*8 = 326.73"
# --- two holes in one Boolean, and a second hole cut in the result of the first
sblcheck two_holes "8 face(s), $SBL_SEAL" "two holes in ONE Boolean: sealed, 8 faces"
sblcheck two_holes "4 keyhole(s) opened" "...4 keyholes opened (2 per end face)"
sblcheck two_holes "^history: Object 4: valid$" "...Check valid"
sblnum two_holes "exact volume " 857 860.5 "exact volume = 1000 - 2*pi*2.25*10 = 858.62"
sblnum two_holes "^history: Volume = " 856.5 861 "display Volume = 858.62"
sblcheck sequential "7 face(s), $SBL_SEAL" "sequential Booleans: the first hole is sealed"
sblcheck sequential "re-evaluated from the recorded original operands.*$SBL_SEAL" "...the second hole is re-evaluated from the recorded operands (GeneralRecipe) and sealed"
sblcheck sequential "^history: Object 5: valid$" "...Check valid on the second result"
sblnum sequential "^history: Volume = " 856.5 861 "display Volume = 858.62"
# --- the exact Shell reads the sealed result's end faces (real inner loops) as a plate with a through-hole
sblcheck shell "$SBL_SEAL" "shell case: the base Boolean is sealed"
sblcheck shell "Shell: thickness 0.5, closed, exact B-rep, volume" "Shell of the sealed result is still the EXACT prism-with-hole path"
sblnum shell "Shell: thickness 0.5, closed, exact B-rep, volume " 320 324 "shell volume = 874.34 - (729 - pi*2.5^2*9) = 322.0"
# --- declined case: unchanged previous behaviour (mesh boolean, with the reason)
sblcheck far_decline "exact B-rep boolean declined (the engine's result has gaps between faces" "a hole 100000 units from the origin still declines with the engine's reason"
sblnot far_decline "$SBL_SEAL" "...and nothing claims a sealed result"
sblnum far_decline "^history: Volume = " 873 877 "...and the mesh result has Volume 874.9"
# --- control: sealed path switched off -> the previous sewn keyhole-slit result, bit for bit the old message
sblcheck fb_cut_through "7 face(s), sewn into a closed solid (tolerance 0.01855), volume 874.8" "DINO8_NO_SEALED_BOOLEAN=1 gives the previous sewn result" "$SBL_FB"
sblcheck fb_cut_through "INVALID - ON_Brep.m_T" "...which is the keyhole-slit structure Check rejects (why the sealed path exists)" "$SBL_FB"
sblcheck fb_cut_through "closed solid" "...yet a closed solid" "$SBL_FB"

# ---------------------------------------------------------------------------
# RVR_: exact fillet / chamfer of ONE rim of a polygonal solid of revolution (rvr_script.txt).
# FilletEdge / ChamferEdge now end their exact attempts with kernel::FilletRevolveRim / ChamferRevolveRim (cmd_fillet.cpp
# TryRevolveRimFillet / TryRevolveRimChamfer), tried ONLY after the capped-cylinder / frustum kernel paths and the app's
# own cylinder / hole classifiers declined. The fixture is the app's own chamfered cylinder: radius 5, height 4, top rim
# chamfered 1 x 1 -> a 4-face solid of revolution with the (rho, z) profile (0,0) (5,0) (5,3) (4,4) (0,4) that FilletCapRim
# refuses (not a plain capped cylinder / frustum). Closed forms are the Green integral V = pi * closed-integral rho^2 dz of
# the blended profile (the circular arc integrated in 20000 steps, tangent length t = r / tan(theta/2)); the chamfer
# triangle is checked against Pappus:
#   V0 = 100 pi = 314.159   V1 (chamfer 1 x 1) = 299.498
#   fillet r=3 on the 135-degree bevel / top-cap rim (setback 1.2426)  -> 294.723
#   fillet r=1.5 on the 90-degree wall / bottom rim                     -> 285.346
#   chamfer 1 (wall) x 0.5 (bottom cap)                                 -> 291.906
# Volume is read from the display mesh (measured 0.07-0.11% low here, 4 significant digits), so each window is the closed
# form +- 1.0 (0.35%): narrower than every removed volume (4.8 / 14.2 / 7.6 against V1), so an unchanged solid cannot pass.
# Face / edge counts and "closed solid" are topological and exact. The kernel result itself (exact torus / cone faces,
# Brep Check, ball radius, tangency, volume to 1e-6) is pinned by revolve_rim_tests in dino8-kernel/tests/test_basic.cpp.
# Scope of this app wiring: the app can only BUILD revolve solids of this family by chamfering a cylinder (the Revolve
# command makes one face, Booleans make sewn polyline solids the kernel classifier rightly refuses), so a countersunk
# plate or a stepped-shaft inside corner is covered by the kernel tests, not here.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RVRO="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/rvr_script.txt" 2>&1)" || { echo "$RVRO"; echo "FAIL: rvr script exited non-zero"; exit 1; }
else
  RVRO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/rvr_script.txt" 2>&1)" || { echo "$RVRO"; echo "FAIL: rvr script exited non-zero"; exit 1; }
fi
rvrblock() { awk -v name="$1" '$0 ~ ("Unknown command: RVRBEGIN_" name "$") { on = 1; next } on && /Unknown command: RVRBEGIN_/ { exit } on { print }' <<<"$RVRO"; }
rvrcheck() { local blk; blk="$(rvrblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (FilletEdge|ChamferEdge|!|Object|  [0-9]|Volume)" <<<"$blk" | head -8 | sed 's/^/     actual:   /' || true; fail=1; fi; }
rvrnot() { local blk; blk="$(rvrblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "FAIL $3"; echo "     unexpected: $2"; fail=1; else echo "ok   $3"; fi; }
# rvrnum NAME MIN MAX DESC: the case's last "Volume = V" lies in [MIN, MAX]
rvrnum() {
  local blk v; blk="$(rvrblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# rvrobjs NAME N DESC: the case's List shows exactly N objects
rvrobjs() {
  local blk n; blk="$(rvrblock "$1")"
  n="$(grep -cE "^history: Object [0-9]+ \(" <<<"$blk" || true)"
  if [ "$n" = "$2" ]; then echo "ok   $3 ($n object(s))"; else echo "FAIL $3 ('$n' object(s), expected $2)"; fail=1; fi
}
# --- fixture: the chamfered cylinder (control: the app's own bevel, not the kernel revolve path)
rvrcheck base "4 faces, 7 edges, closed solid" "RVR_base: fixture = chamfered cylinder, 4 faces, closed solid"
rvrcheck base "Object 1: valid" "RVR_base: fixture Check valid"
rvrnum base 298.0 301.0 "RVR_base: fixture V1 = 100 pi - 2 pi (5 - 1/3)(0.5) = 299.498"
rvrnot base "revolve-rim" "RVR_base: ...no revolve-rim path involved"
# --- fillet of the 135-degree bevel / cap rim
rvrcheck F_bevelcap "exact kernel cap-rim fillet not used (dino8::kernel::FilletCapRim: not a plain capped cylinder or cone frustum" "RVR_F_bevelcap: the cap-rim path declines first, with its reason (existing message, unchanged)"
rvrcheck F_bevelcap "rim of solid-of-revolution object 1 replaced with an exact fillet (radius 3; exact kernel torus patch tangent to both faces at the rim, 5 faces, closed solid)" "RVR_F_bevelcap: then FilletRevolveRim makes an exact torus fillet (before: mesh fallback)"
rvrcheck F_bevelcap "5 faces, 9 edges, closed solid" "RVR_F_bevelcap: 5 faces (input + 1), 9 edges, closed solid"
rvrcheck F_bevelcap "Object 1: valid" "RVR_F_bevelcap: Check valid"
rvrobjs F_bevelcap 1 "RVR_F_bevelcap: replaced in place, no mesh object left behind"
rvrnum F_bevelcap 293.7 295.7 "RVR_F_bevelcap: Green volume = 294.723 (r=3, tangent length 1.2426)"
# --- fillet of the 90-degree wall / bottom rim
rvrcheck F_bottom "replaced with an exact fillet (radius 1.5; exact kernel torus patch tangent to both faces at the rim, 5 faces, closed solid)" "RVR_F_bottom: exact torus fillet on the wall / bottom rim"
rvrcheck F_bottom "5 faces, 9 edges, closed solid" "RVR_F_bottom: 5 faces, 9 edges, closed solid"
rvrcheck F_bottom "Object 1: valid" "RVR_F_bottom: Check valid"
rvrobjs F_bottom 1 "RVR_F_bottom: one object"
rvrnum F_bottom 284.3 286.3 "RVR_F_bottom: Green volume = 285.346 (r=1.5)"
# --- chamfer of the wall / bottom rim
rvrcheck C_bottom "replaced with an exact chamfer (distance1 1, distance2 0.5; exact kernel revolve-rim bevel (cone / plane), distance1 along the wall and distance2 across the planar face)" "RVR_C_bottom: exact kernel bevel, distance1 along the wall, distance2 across the cap"
rvrcheck C_bottom "5 faces, 9 edges, closed solid" "RVR_C_bottom: 5 faces, 9 edges, closed solid"
rvrcheck C_bottom "Object 1: valid" "RVR_C_bottom: Check valid"
rvrobjs C_bottom 1 "RVR_C_bottom: one object"
rvrnum C_bottom 290.9 292.9 "RVR_C_bottom: Green volume = 291.906 (wall 1, cap 0.5)"
# --- refusals carry the kernel's reason
rvrcheck F_toobig "exact kernel revolve-rim fillet not used (dino8::kernel::FilletRevolveRim: the blend would consume a whole adjacent face (setbacks 1.656854 and 1.656854 must be strictly less than the profile lengths 1.414214 and 4.000000))" "RVR_F_toobig: r=4 on the 1.414-long bevel is refused WITH the kernel's reason (setback 4/tan(67.5) = 1.6569)"
rvrcheck F_toobig "4 faces, 7 edges, closed solid" "RVR_F_toobig: ...and the solid is left unchanged (4 faces)"
rvrnot F_toobig "rim of solid-of-revolution object 1 replaced" "RVR_F_toobig: ...no exact revolve-rim fillet is claimed"
rvrcheck F_blended "exact kernel revolve-rim fillet not used (dino8::kernel::FilletRevolveRim: a face is not a plane, cylinder or cone - not a polygonal solid of revolution)" "RVR_F_blended: a solid that already carries the torus blend is refused WITH the kernel's reason"
rvrcheck F_two "a rim of this solid of revolution is already staged in this FilletEdge run; the exact kernel revolve-rim fillet blends one rim per run" "RVR_F_two: a second rim in the same run is refused with the one-rim-per-run explanation"
rvrcheck F_two "replaced with an exact fillet (radius 1.5; exact kernel torus patch" "RVR_F_two: ...the first rim is still applied exactly"
rvrnum F_two 284.3 286.3 "RVR_F_two: only the first fillet is in the solid, Volume = 285.346"
rvrcheck F_two "5 faces, 9 edges, closed solid" "RVR_F_two: 5 faces, closed solid"
# --- negative controls: the old exact paths are unchanged and never reach the revolve path
rvrcheck ctl_cyl "cylinder rim(s) of object 1 replaced with an exact fillet (top radius 1; exact quarter-torus patch, 4 faces, closed solid)" "RVR_ctl_cyl: plain cylinder rim fillet still gives the app's pinned message"
rvrnot ctl_cyl "revolve-rim" "RVR_ctl_cyl: ...and never reaches the revolve path"
rvrnum ctl_cyl 306.7 308.7 "RVR_ctl_cyl: Pappus Volume = 314.159 - 2 pi (r^2 (R - r/2) - (pi r^2/4)(R - r) - r^3/3) = 307.718"
rvrcheck ctl_cyl "Object 1: valid" "RVR_ctl_cyl: Check valid"
rvrcheck ctl_cyl_chamfer "replaced with an exact chamfer (radius 1; exact cone on the cylinder rim, distance1 along the wall and distance2 across the cap)" "RVR_ctl_cyl_chamfer: plain cylinder chamfer still gives the app's pinned message"
rvrnot ctl_cyl_chamfer "revolve-rim" "RVR_ctl_cyl_chamfer: ...and never reaches the revolve path"
rvrcheck ctl_tcone "cap rim(s) of object 1 replaced with an exact fillet (radius 1; exact kernel torus patch tangent to the cap and the wall, 4 faces, closed solid)" "RVR_ctl_tcone: cone frustum rim still takes the kernel cap-rim path"
rvrnot ctl_tcone "revolve-rim" "RVR_ctl_tcone: ...and never reaches the revolve path"
rvrnum ctl_tcone 507.7 513.8 "RVR_ctl_tcone: Pappus Volume = 513.13 - 2.390 = 510.74"
rvrcheck ctl_box "edge 5 of object 1 replaced with an exact fillet (radius 1)" "RVR_ctl_box: a box edge is still the kernel's exact planar fillet"
rvrnot ctl_box "revolve-rim" "RVR_ctl_box: ...with no revolve-rim message for an ordinary open edge"
if grep -q "gl_error=0" <<<"$RVRO"; then echo "ok   RVR script ran without OpenGL errors"; else echo "FAIL RVR script ran without OpenGL errors"; fail=1; fi

exit $fail
