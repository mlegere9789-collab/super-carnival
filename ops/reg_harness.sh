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
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-ae1115806603edb25/dino8-app/tests
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

# ---------------------------------------------------------------------------
# SX: exact curved-solid QC (solidsx_script.txt) - the audit/closure of the
# "Solid editing with B-rep results (booleans, fillet, shell, offset)" bullet:
# Boolean of curved solids (General engine, sewn closed and cross-checked
# against the mesh boolean), exact Shell/OffsetSrf/Pipe(closed rail) and the
# exact torus fillet of a plain cylinder's rim. Every case is bracketed by an
# SXBEGIN_<name> marker; sxblock slices the app output into that case.
# Volumes are read from the display mesh (chord 0.005), so the ranges below
# carry that tessellation error (up to ~1% on a torus, ~3% on a thin pipe).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SXOUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/solidsx_script.txt" 2>&1)" || { echo "$SXOUT"; echo "FAIL: solidsx script exited non-zero"; exit 1; }
else
  SXOUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/solidsx_script.txt" 2>&1)" || { echo "$SXOUT"; echo "FAIL: solidsx script exited non-zero"; exit 1; }
fi
sxblock() { awk -v name="$1" '$0 ~ ("Unknown command: SXBEGIN_" name "$") { on = 1; next } on && /Unknown command: SXBEGIN_|Unknown command: SXEND/ { exit } on { print }' <<<"$SXOUT"; }
sxcheck() { local blk; blk="$(sxblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Boolean|Shell|Offset|Pipe|FilletEdge|Object|  [0-9]|Volume|!)" <<<"$blk" | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
# sxvol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
sxvol() {
  local blk v; blk="$(sxblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/')"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- Booleans of curved solids: exact, sewn closed, volume = closed form
sxcheck B_box_minus_cyl "BooleanDifference: exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "box minus a through-hole cylinder is the General engine's result sewn into a closed solid (before: an 'open' polysurface that Volume refused)"
sxcheck B_box_minus_cyl "(polysurface)" "...and stays a polysurface (not a mesh)"
sxcheck B_box_minus_cyl "faces, [0-9]* edges, closed solid" "...List reports it as a closed solid (before: 188 edges, open)"
sxvol B_box_minus_cyl 873.5 875.5 "box minus a through-hole cylinder: Volume = 1000 - pi*2^2*10 = 874.34 (before: 'Object 3 is not closed', Volume 0)"
sxcheck B_box_minus_cyl "mesh cross-check" "...every accepted exact result prints its independent mesh-boolean cross-check volume"
sxcheck B_box_minus_cyl "Area = " "...and Area works on it"
sxcheck B_box_minus_blind "8 face(s), sewn into a closed solid" "blind hole: exact, closed"
sxvol B_box_minus_blind 936.2 938.2 "blind hole Volume = 1000 - pi*4*5 = 937.17"
sxcheck B_box_plus_boss "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sewn into a closed solid" "boss: exact, closed"
sxvol B_box_plus_boss 1139.5 1143 "cylindrical boss Volume = 1000 + pi*9*5 = 1141.37"
sxcheck B_tube "4 face(s), sewn into a closed solid" "tube (cylinder minus coaxial cylinder): exact, closed"
sxvol B_tube 656 662 "tube Volume = pi*(25-4)*10 = 659.73"
sxcheck B_cyl_stack "5 face(s), sewn into a closed solid" "stacked cylinders union: exact, closed"
sxvol B_cyl_stack 343 347.5 "stacked cylinders Volume = pi*9*10 + pi*4*5 = 345.58"
sxcheck B_cyl_minus_sphere "4 face(s), sewn into a closed solid" "cylinder minus a dome-cutting sphere: exact, closed"
sxvol B_cyl_minus_sphere 649 653.5 "dome cut Volume = 250*pi - 2/3*pi*64 = 651.36"
sxcheck B_two_holes_at_once "8 face(s), sewn into a closed solid" "two holes cut in one Boolean (cutters selected together): exact, closed"
sxvol B_two_holes_at_once 857.5 860.5 "two holes Volume = 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_small "closed solid" "the same hole at 1/10 size is still exact and closed"
sxvol B_scale_small 0.870 0.880 "1/10-size hole Volume = 1 - pi*0.04*1 = 0.8743"
# --- Declined with a reason; the result is a closed mesh (never an open polysurface)
sxcheck B_sphere_plus_box "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "box + sphere is now an exact B-rep (before: declined 'the sewn result does not tessellate to a closed mesh' because the display mesh's keyhole-corridor gaps were only closeable by a weld that also fused the sphere's pole fan; the mesher now re-welds only boundary vertices)"
sxcheck B_sphere_plus_box "(polysurface)" "...and the result is a polysurface, not a mesh"
sxvol B_sphere_plus_box 1130 1136 "box + sphere exact result is a closed solid with Volume = 1000 + 2/3*pi*64 = 1134.04"
sxcheck B_cyl_offaxis "exact B-rep boolean declined (dino8::kernel::BooleanCombineGeneral: an edge is claimed by 3 or more fragment loops" "off-axis cylinder union: the engine's own refusal is printed as the reason"
sxcheck B_chain "re-evaluated from the recorded original operands (the base and 2 tool(s) in one pass" "a second SEQUENTIAL hole is now exact (before: declined 'gaps between faces that sewing could not close'): re-evaluated as base minus both cutters in one pass"
sxcheck B_chain "(polysurface)" "...and the result is a polysurface, not a mesh"
sxvol B_chain 857 861 "...and its Volume is 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_large "7 face(s), sewn into a closed solid" "100x-size hole is now exact and closed (before: declined 'exact B-rep boolean declined' because the uniform re-weld could not close the display mesh; the boundary-only re-weld does)"
sxvol B_scale_large 870000000 879000000 "100x-size hole Volume = 1e9 - pi*200^2*1000 = 874336294"
sxcheck B_far_from_origin "exact B-rep boolean declined" "a hole 100000 units from the origin: declined with a reason"
sxcheck B_meshalias "MeshBooleanDifference: [0-9]* faces, volume" "old behaviour stays reachable: MeshBooleanDifference always returns the mesh"
sxcheck B_then_shell "Shell: thickness 0.5, closed, [A-Za-z, -]*volume" "Shell of the sewn Boolean result now works (before: 'Object 3 is not a closed solid; skipped'; exact B-rep since HSO_, so the 'exact B-rep, ' words are optional here)"
sxcheck B_then_shell "Shell: thickness 0.5, closed, exact B-rep, volume" "...and that shell is now an exact B-rep (prism-with-hole construction, HSO_; before: 'exact B-rep shell not used (' with the reason, a mesh)"
# --- Shell
sxcheck S_box_closed "Shell: thickness 1, closed, exact B-rep, volume 488" "control: closed box shell is exact (1000 - 8^3)"
sxcheck S_box_open "Shell: thickness 1, open (1 face(s) removed), exact B-rep, volume 424" "box with the top face removed is now an exact B-rep (kernel ShellConvexPlanar with removed_faces; before: a mesh)"
sxcheck S_box_open "(polysurface)" "...a polysurface"
sxcheck S_box_open "14 faces, 28 edges, closed solid" "...14 faces (5 outer + 5 inner + 4 rim) and 28 edges, a closed solid"
sxcheck S_box_perface "1 face(s) at their own thickness, closed, exact B-rep, volume 616" "per-face thickness (top 3, others 1) is exact: 1000 - 8*8*6 = 616 (before: a mesh)"
sxcheck S_box_exactno "Shell: thickness 1, closed, volume 488" "old behaviour reachable: Exact=No gives the mesh construction"
sxcheck S_box_exactno "(mesh)" "...a mesh"
sxcheck S_sphere "Shell: thickness 1, closed, exact B-rep" "whole sphere shell is exact (concentric reversed inner sphere)"
sxcheck S_sphere "2 faces, 2 edges, closed solid" "...2 faces, closed solid"
sxvol S_sphere 253.5 256.5 "sphere shell Volume = 4/3*pi*(125-64) = 255.5"
sxcheck S_torus "Shell: thickness 1, closed, exact B-rep" "whole torus shell is exact"
sxvol S_torus 970 990 "torus shell Volume = 2*pi^2*10*(9-4) = 986.96 (display mesh reads low on a torus)"
sxcheck S_cyl_closed "Shell: thickness 1, closed, exact B-rep" "plain cylinder closed hollow shell is exact (before: a 14208-triangle mesh)"
sxcheck S_cyl_closed "6 faces, 6 edges, closed solid" "...6 faces (outer 3 + inner 3), closed solid"
sxvol S_cyl_closed 381 385 "hollow cylinder Volume = pi*(250-128) = 383.27"
sxcheck S_cyl_open "open (1 face(s) removed), exact B-rep" "cylinder with the top cap removed is an exact cup (before: a mesh)"
sxcheck S_cyl_open "5 faces, 9 edges, closed solid" "...5 faces (outer wall, base disc, inner wall, floor, rim annulus), closed solid"
sxvol S_cyl_open 331 335 "cup Volume = pi*(250-16*9) = 333.01"
sxcheck S_cyl_open_bottom "open (1 face(s) removed), exact B-rep" "removing the bottom cap works too"
sxcheck S_L_nonconvex "Shell: thickness 1, closed, exact B-rep, volume 1056" "non-convex L-shaped extrusion is now an exact B-rep shell (right-prism construction; before: 'exact B-rep shell not used', mesh): 8*300 - 6*224 = 1056"
sxvol S_L_nonconvex 1050 1062 "...and its measured Volume agrees"
# --- OffsetSrf
sxcheck O_sphere "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "sphere offset is exact (before: a 4700-triangle mesh)"
sxcheck O_sphere "1 faces, 1 edges, closed solid" "...one closed spherical face"
sxvol O_sphere 902 906 "offset sphere Volume = 4/3*pi*216 = 904.78"
sxcheck O_torus "1 exact B-rep" "torus offset is exact"
sxvol O_torus 3110 3170 "offset torus Volume = 2*pi^2*10*16 = 3158.3 (display mesh)"
sxcheck O_cyl "3 faces, 3 edges, closed solid" "plain cylinder offset is an exact 3-face cylinder"
sxvol O_cyl 1353 1359 "offset cylinder Volume = pi*36*12 = 1357.17"
sxcheck O_box_solid "OffsetSrf: distance 1, 1 object(s), solid, 1 exact B-rep" "Solid=Yes on a box is exact (before: a mesh)"
sxcheck O_box_solid "(polysurface)" "...a polysurface"
sxvol O_box_solid 727.5 728.5 "box Solid=Yes Volume = 12^3 - 10^3 = 728"
sxcheck O_sphere_solid "solid, 1 exact B-rep" "sphere Solid=Yes is exact"
sxvol O_sphere_solid 379 383 "sphere Solid=Yes Volume = 4/3*pi*(216-125) = 381.2"
sxcheck O_sphere_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
sxcheck O_L_nonconvex "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "non-convex L extrusion offset is now exact (right-prism construction; before: 'exact B-rep offset not used', mesh)"
sxvol O_L_nonconvex 3830 3850 "...Volume = (20+2)*(10+2)... = 384*10 = 3840 (profile area 300 + 80 + 4 = 384, height 8 + 2)"
# --- Pipe on a closed rail
sxcheck P_closed "Pipe: radius 1, 1 pipe(s) (exact closed B-rep tube)" "Pipe on a closed circular rail is the kernel's exact closed tube (before: a 1152-triangle mesh)"
sxcheck P_closed "(polysurface)" "...a polysurface"
sxcheck P_closed "closed solid" "...a closed solid"
sxvol P_closed 186 200 "closed-rail pipe Volume ~ 2*pi^2*10*1 = 197.39 (display mesh; the Torus primitive reads 191.2 under the same mesher)"
# --- Fillet of a plain cylinder's rim
sxcheck F_cyl_top "cylinder rim(s) of object 1 replaced with an exact fillet (top radius 1; exact quarter-torus patch, 4 faces, closed solid)" "cylinder top-rim fillet is an exact quarter torus (before: a mesh whose volume INCREASED to 1594)"
sxcheck F_cyl_top "4 faces, 7 edges, closed solid" "...4 faces (wall, torus, 2 discs) and 7 edges, closed solid"
sxvol F_cyl_top 1561 1566 "top-rim fillet Volume = 25*pi*20 - 6.44 = 1564.36 (before 1594)"
sxcheck F_cyl_both "top radius 1, bottom radius 2; exact quarter-torus patches, 5 faces, closed solid" "both rims in one run become one exact solid"
sxvol F_cyl_both 1536 1542 "both-rim fillet Volume = 1539.80"
sxvol F_cyl_bottom 1543 1549 "bottom-rim fillet (radius 2) Volume = 1546.24"
sxcheck F_cyl_exactno "mesh fallback (exact B-rep trim unavailable here" "old behaviour reachable: Exact=No keeps the approximate mesh fillet"
sxcheck F_cyl_toobig "exact cylinder-rim fillet not used (the radius is not smaller than the cylinder radius)" "a radius larger than the cylinder: exact refused with the reason, fallback runs"
sxcheck F_box_control "FilletEdge: edge 10 of object 1 replaced with an exact fillet" "control: a box edge is still the kernel's exact planar fillet"
sxvol F_box_control 990.5 992.3 "box edge fillet Volume = 991.4"
if grep -q "^FAIL" <<<"$SXOUT"; then echo "FAIL solidsx script reported an in-script FAIL"; fail=1; fi

# ---------------------------------------------------------------------------
# Viewport display: per-object display modes + view-dependent adaptive
# tessellation (PARITY_MAP.md "Viewport display, rendering & visualization":
# "Per-object display mode override" and "View-dependent adaptive
# tessellation"). tests/viewport_lod_script.txt runs both against the real
# app: part 1 zooms one sphere through several levels and reads back what
# each viewport's last frame drew (LodStats); part 2 cycles one box through
# every per-object mode in Rendered/Shaded/Wireframe viewports and captures
# bitmaps, then queries (ObjectDisplayModes) and round-trips through .3dm.
# ---------------------------------------------------------------------------
mkdir -p "$TMPW/vpl"
sed "s|@TMP@|$TMPW/vpl|g" "$HERE/viewport_lod_script.txt" > "$TMPW/viewport_lod_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  VPL="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/viewport_lod_script.txt" 2>&1)" || { echo "$VPL"; echo "FAIL: viewport_lod script exited non-zero"; exit 1; }
else
  VPL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/viewport_lod_script.txt" 2>&1)" || { echo "$VPL"; echo "FAIL: viewport_lod script exited non-zero"; exit 1; }
fi
vplcheck() { if grep -q "$1" <<<"$VPL"; then echo "ok   $2"; else echo "FAIL $2"; near "$VPL" "$1"; fail=1; fi; }
# vplval SECTION VIEWPORT FIELD: FIELD of the "LodStats: viewport VIEWPORT object" line in the SECTION-th LodStats call.
vplval() {
  awk -v n="$1" -v v="$2" -v f="$3" '
    /LodStats: adaptive=/ { k++ }
    k == n && index($0, "LodStats: viewport " v " object ") { if (match($0, f "=[-0-9.e+]+")) { s = substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); print s; exit } }' <<<"$VPL"
}
# vplhdr SECTION FIELD: FIELD of the SECTION-th "LodStats: adaptive=" header line.
vplhdr() {
  awk -v n="$1" -v f="$2" '
    /LodStats: adaptive=/ { k++; if (k == n) { if (match($0, f "=[a-z0-9]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPL"
}
vplnum() { # DESC EXPR : EXPR is an awk expression over already-substituted numbers
  local r; r="$(awk "BEGIN { print ($2) ? \"yes\" : \"no\" }")"
  if [ "$r" = yes ]; then echo "ok   $1"; else echo "FAIL $1 [$2]"; fail=1; fi
}
vplcheck "^ok   expect_objects 2" "viewport_lod script left exactly the two boxes"
vplcheck "gl_error=0" "viewport_lod script ran without OpenGL errors"
VP_P0="$(vplval 1 Perspective tris)"; VP_P3="$(vplval 2 Perspective tris)"; VP_P9="$(vplval 3 Perspective tris)"; VP_PB="$(vplval 4 Perspective tris)"
VP_T0="$(vplval 1 Top tris)"; VP_T3="$(vplval 2 Top tris)"; VP_T9="$(vplval 3 Top tris)"
echo "     Perspective triangles at zoom 0 / 3 / 9 / back to 3 steps: $VP_P0 / $VP_P3 / $VP_P9 / $VP_PB;  Top (never zoomed): $VP_T0 / $VP_T3 / $VP_T9"
vplnum "zooming the Perspective viewport in 3 steps re-tessellates the sphere finer (more triangles than at zoom 0)" "$VP_P3 > $VP_P0"
vplnum "...and 9 steps in is denser still, more than 3x the zoom-0 triangle count" "$VP_P9 > 3 * $VP_P0 && $VP_P9 > $VP_P3"
vplnum "the Top viewport, never zoomed, keeps its own level through all of it (each viewport has its OWN LOD, not one shared finest value)" "$VP_T0 == $VP_T3 && $VP_T3 == $VP_T9 && $VP_T0 < $VP_P9"
vplnum "zooming back out to the 3-step zoom restores exactly that zoom's mesh (same triangle count as before)" "$VP_PB == $VP_P3"
VP_E0="$(vplval 1 Perspective nominal_err_px)"; VP_E9="$(vplval 3 Perspective nominal_err_px)"
echo "     NOMINAL on-screen chord error (tolerance / pixel size; the mesher really leaves ~2.1x this, see test_adaptive_display) Perspective: $VP_E0 px at zoom 0, $VP_E9 px at zoom 9"
vplnum "the screen-space error stays ~0.5 px even 9 zoom steps in (past the old 0.2x clamp, where it grew to ~1.8 px and beyond)" "$VP_E9 < 0.6 && $VP_E9 > 0.4"
vplnum "9 zoom steps in is past the OLD clamp (lod_scale < 0.2) yet the scale still keeps refining" "$(vplval 3 Perspective surface_tol) < 0.05 * 0.2 * 0.9"
vplnum "the multi-level cache swapped levels instead of re-tessellating every time: stash_hits counter > 0" "$(vplhdr 6 stash_hits) > 0"
vplcheck "LodStats: object 1 polysurface stashed_levels=[1-3] budget_floor=0$" "LodStats reports the stashed levels and no budget floor for a modest sphere"
vplcheck "LodStats: adaptive=off" "AdaptiveTessellation Off is reported by LodStats"
VP_OFF_TRIS="$(awk '/LodStats: adaptive=/ { k++ } k == 5 && /LodStats: viewport [A-Za-z]+ object / && match($0, /tris=[0-9]+/) { print substr($0, RSTART + 5, RLENGTH - 5) }' <<<"$VPL" | sort -u | tr '\n' ' ')"
echo "     adaptive OFF: distinct triangle counts across the four viewports: $VP_OFF_TRIS"
vplnum "adaptive OFF: all four viewports draw one identical fixed-tolerance mesh (a single distinct triangle count)" "$(wc -w <<<"$VP_OFF_TRIS") == 1"
vplnum "adaptive OFF: the tolerances are exactly the Options values (surface 0.05, curve 0.02)" "$(vplval 5 Perspective surface_tol) == 0.05 && $(vplval 5 Perspective curve_tol) == 0.02"
vplnum "adaptive ON again: Perspective (zoomed) is finer than the fixed-tolerance mesh it just had" "$(vplval 6 Perspective tris) > $(vplval 5 Perspective tris)"
vplnum "switching adaptive off does not itself count as a zoom-driven re-tessellation (rebuilds counter unchanged)" "$(vplhdr 5 rebuilds) == $(vplhdr 4 rebuilds)"

# Part 2: per-object modes, pixel level + query + .3dm round trip.
python3 - "$TMPW/vpl" <<'PY' && echo "ok   per-object display modes carry their FULL style: Wireframe stays visible in a Rendered viewport, Pen/Arctic/Technical/Artistic/Rendered each draw their own edge colour (and no wires for Rendered) over their own fill, Box A never changes" || { echo "FAIL per-object display mode pixel check"; fail=1; }
import struct, sys
d = sys.argv[1]
def read_bmp(name):
    b = open(f'{d}/{name}.bmp', 'rb').read()
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', b[2:30])
    assert hdr == 40 and planes == 1 and bpp == 24, (name, hdr, planes, bpp)
    row = (w * 3 + 3) & ~3
    px = b[off:]
    def get(x, y):
        r = h - 1 - y
        i = r * row + x * 3
        return px[i + 2], px[i + 1], px[i]
    return w, h, get
w, h, rb = read_bmp('r_base')
y = h // 2 + 40   # a row inside both boxes, off the X axis line
blue = [x for x in range(w) if rb(x, y)[2] > rb(x, y)[0] + 80]
bx0, bx1 = blue[0], blue[-1]; cx = (bx0 + bx1) // 2
red = [x for x in range(w) if rb(x, y)[0] > rb(x, y)[2] + 80 and rb(x, y)[0] > 150]
ax = (red[0] + red[-1]) // 2
def probe(name):
    _, _, g = read_bmp(name)
    return dict(edge=g(bx0, y), fill=g(cx, y), A=g(ax, y), out=g(bx0 - 3, y))
r_base, r_wire = probe('r_base'), probe('r_wire')
s = {n: probe(n) for n in ('s_base', 's_pen', 's_arctic', 's_technical', 's_artistic', 's_rendered')}
for k, v in list(s.items()) + [('r_base', r_base), ('r_wire', r_wire)]:
    print(f'{k:12s} edge={v["edge"]} fill={v["fill"]} A={v["A"]}')
# Box A (never overridden) is identical across captures of the same viewport mode.
assert r_wire['A'] == r_base['A'], 'Box A changed in the Rendered viewport'
for n, v in s.items(): assert v['A'] == s['s_base']['A'], f'Box A changed in {n}'
# Wireframe override in a RENDERED viewport (edges and isocurves both off there): used to vanish entirely.
assert r_wire['fill'] == r_wire['out'], 'Wireframe override still filled in a Rendered viewport'
assert r_wire['edge'] != r_wire['out'] and r_wire['edge'][2] > r_wire['edge'][0] + 80, f'Wireframe override has no visible blue outline in a Rendered viewport: {r_wire}'
# Pen: black edge, unlit flat white fill.   Arctic: grey (150) edge, lit white fill.
assert s['s_pen']['edge'] == (0, 0, 0) and s['s_pen']['fill'] == (245, 245, 245), s['s_pen']
assert s['s_arctic']['edge'] == (150, 150, 150) and all(c < 245 and c > 200 for c in s['s_arctic']['fill']), s['s_arctic']
# Technical vs Artistic: same lit flat grey fill, different line work.
assert s['s_technical']['edge'] == (20, 20, 20), s['s_technical']
assert s['s_artistic']['edge'] == (60, 50, 40), s['s_artistic']
assert s['s_technical']['fill'] == s['s_artistic']['fill'] and abs(s['s_technical']['fill'][0] - s['s_technical']['fill'][2]) < 12, 'Technical/Artistic fills differ or are not grey'
assert s['s_technical']['fill'] != s['s_base']['fill'], 'Technical fill equals the plain blue object fill'
# Rendered override in a Shaded viewport: no wires at all (edge == fill == the Rendered look), unlike Shaded's darker outline.
assert s['s_rendered']['edge'] == s['s_rendered']['fill'] == r_base['fill'], s['s_rendered']
assert s['s_base']['edge'] != s['s_base']['fill'], 'plain Shaded object lost its outline'
PY
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Rendered" "ObjectDisplayModes reports the Rendered override by name"
vplcheck "ObjectDisplayModes: 1 of 2 object(s) carry a per-object display mode Rendered=1" "...and the per-mode tally"
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Technical" "ObjectDisplayModes reports Technical (a mode that used to be refused)"
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = UseViewport" "ObjectDisplayModes All also lists the objects that follow the viewport"
# RayTraced used to be refused here ("a whole-frame path-traced image"); it is now a real per-object mode
# (tests/viewport_close_script.txt, section "viewport close" at the end of this file proves it on pixels).
if grep -q "RayTraced is a whole-frame path-traced image" <<<"$VPL"; then echo "FAIL the old RayTraced per-object refusal is still printed"; fail=1; else echo "ok   RayTraced is no longer refused as a per-object display mode"; fi
vplcheck "SetObjectDisplayMode: unknown mode 'Bogus' - nothing changed" "an unknown mode name is refused and changes nothing"
VP_QT="$(grep -c 'ObjectDisplayModes: 1 of 2 object(s) carry a per-object display mode Technical=1' <<<"$VPL")"
vplnum "Technical survives the refused RayTraced/Bogus attempts and a Save/New/Open round trip through .3dm (query shows it 4 times: before, All, after RayTraced, after reopen)" "$VP_QT == 4"
VP_TV="$(grep -c 'ObjectDisplayModes: object [0-9]* polysurface = Technical (viewport [A-Za-z]*)' <<<"$VPL")"
vplnum "SetObjectDisplayMode defaults to the ACTIVE viewport only (Rhino's scope): every Technical query line carries '(viewport NAME)', and it survives the .3dm round trip (4 lines)" "$VP_TV == 4"

# Part 3: scope, pixel level. Pen pinned to Top only must leave Front untouched (byte-identical bitmap); Pen All reaches Front too.
python3 - "$TMPW/vpl" <<'PY' && echo "ok   per-VIEWPORT scope: Pen set in Top changes Top but leaves Front's whole bitmap byte-identical; 'Pen All' then changes Front too, and Top keeps it" || { echo "FAIL per-viewport scope pixel check"; fail=1; }
import struct, sys
d = sys.argv[1]
def load(name):
    b = open(f'{d}/{name}.bmp', 'rb').read()
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', b[2:30])
    row = (w * 3 + 3) & ~3
    px = b[off:]
    def get(x, y):
        r = h - 1 - y
        i = r * row + x * 3
        return px[i + 2], px[i + 1], px[i]
    return w, h, px, get
def diff_centre(a, b):
    w, h, pa, ga = a; _, _, pb, gb = b
    pts = [(x, y) for y in range(h) for x in range(w) if sum(abs(p - q) for p, q in zip(ga(x, y), gb(x, y))) > 15]
    assert pts, 'captures do not differ'
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return (min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2
t_base, t_pen, t_all = load('t_base'), load('t_pen'), load('t_all')
f_base, f_scoped, f_all = load('f_base'), load('f_scoped'), load('f_all')
cx, cy = diff_centre(t_base, t_pen)
print('Top: B centre', (cx, cy), 'base', t_base[3](cx, cy), 'pen', t_pen[3](cx, cy), 'after Pen All', t_all[3](cx, cy))
assert t_pen[3](cx, cy) == (245, 245, 245), 'Pen not applied in Top'
assert t_base[3](cx, cy) != (245, 245, 245)
assert f_base[2] == f_scoped[2], 'Front changed although Pen was pinned to Top only'
fx, fy = diff_centre(f_base, f_all)
print('Front: B centre', (fx, fy), 'base', f_base[3](fx, fy), 'scoped', f_scoped[3](fx, fy), 'Pen All', f_all[3](fx, fy))
assert f_all[3](fx, fy) == (245, 245, 245), 'Pen All did not reach Front'
assert f_scoped[3](fx, fy) == f_base[3](fx, fy)
assert t_all[3](cx, cy) == (245, 245, 245), 'Top lost Pen after Pen All'
PY
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Pen (viewport Top)" "a viewport-scoped override is listed with its viewport"
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Pen$" "Pen All is listed as an all-viewports override (no viewport suffix)"
vplcheck "ClearAllObjectDisplayModes: 1 object(s) reset to the viewport display mode" "ClearAllObjectDisplayModes (Rhino's command, extended to the display-mode overrides) removes them and reports how many objects"
vplcheck "ObjectDisplayModes: 0 of 2 object(s) carry a per-object display mode$" "...and the query then shows none"



# ---------------------------------------------------------------------------
# Named macro OBJECTS (cmd_macros.cpp, app/MacroLibrary.h) - PARITY_MAP.md's
# "VBA-style macro recorder and editor" item: a saved macro is a recorded,
# editable object with properties (name, description, tags, parameters,
# structured steps, created/modified), not ';'-separated text. Three real app
# processes against PRIVATE config directories (so the library starts empty
# and the persisted state is exactly what these scripts wrote):
#   A  macro_objects_script.txt          save/list/show/edit/run-with-args/
#                                        errors/prompt/duplicate/rename/delete/
#                                        export-import/binding/in-process reload
#   B  macro_objects_persist_script.txt  same config dir, NEW process: the
#                                        library, alias and toolbar button
#                                        survived the restart
#   C  macro_objects_migrate_script.txt  a settings.json from before macro
#                                        objects (macros map + macro_text)
#   D  the Macro Editor panel is opened and rendered (no crash); its widgets
#      cannot be driven headlessly - see the PARITY_MAP.md note.
mo_exec() {  # mo_exec <config home> <script>
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    XDG_CONFIG_HOME="$1" APPDATA="$1" timeout 900 "$BIN" --smoke 100 --script "$2" 2>&1
  else
    XDG_CONFIG_HOME="$1" APPDATA="$1" timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$2" 2>&1
  fi
}
mo_chk() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
mo_cnt() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$4" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $4)"; near "$1" "$2"; fail=1; fi; }
# The lines a command printed: everything after its exact "Command: ..." echo
# line up to the next "Command:" line; $3 picks the Nth occurrence.
mo_block() { sed "s/^history: //" <<<"$1" | awk -v n="$3" -v cmd="Command: $2" '$0==cmd{c++; on=(c==n); next} /^Command:/{on=0} on'; }
if [ "$IS_WINDOWS" = 1 ]; then MO_SETTINGS_SUB="Dino8"; else MO_SETTINGS_SUB="dino8"; fi
MO_DIR="$TMP/mo"; mkdir -p "$MO_DIR"
if command -v cygpath >/dev/null 2>&1; then MO_DIRW="$(cygpath -m "$MO_DIR")"; else MO_DIRW="$MO_DIR"; fi
printf '%s\n' '{"format": "something-else", "version": 1, "macros": []}' > "$MO_DIR/bad_format.json"
printf '%s\n' '{"format": "dino8-macro-library", "version": 99, "macros": []}' > "$MO_DIR/future.json"
printf '%s\n' 'this is { not json' > "$MO_DIR/garbage.json"
MO_CFG_A="$TMP/mo_cfg_a"; mkdir -p "$MO_CFG_A"
sed "s#@MODIR@#$MO_DIRW#g" "$HERE/macro_objects_script.txt" > "$TMPW/mo_a.txt"
sed "s#@MODIR@#$MO_DIRW#g" "$HERE/macro_objects_persist_script.txt" > "$TMPW/mo_b.txt"
sed "s#@MODIR@#$MO_DIRW#g" "$HERE/macro_objects_migrate_script.txt" > "$TMPW/mo_c.txt"
MO_A="$(mo_exec "$MO_CFG_A" "$TMPW/mo_a.txt")" || { echo "$MO_A"; echo "FAIL: macro-objects script A exited non-zero"; exit 1; }
grep -E "^(ok|FAIL)" <<<"$MO_A" || true
if grep -q "^FAIL" <<<"$MO_A"; then fail=1; fi
grep -q "^smoke:" <<<"$MO_A" || { echo "$MO_A"; echo "FAIL: macro-objects script A produced no smoke line"; fail=1; }

# -- SaveMacro from the recorder, then structured EditMacro ----------------
mo_chk "$MO_A" "Saved macro 'cube': 1 step(s), no parameters" "SaveMacro turns the recorder buffer (one recorded Box line) into a named macro object with one structured step"
mo_chk "$MO_A" "EditMacro 'cube': replaced step 1 (was: Box 0,0,0 2,2,0 2) with: Box 0,0,0 {size},{size},0 {size} (1 step(s)); new parameter(s): {size}" "EditMacro Replace 1 swaps the recorded numbers for {size} and auto-declares the parameter"
mo_chk "$MO_A" "EditMacro 'cube': inserted step 2: SelNone (4 step(s))" "EditMacro Insert 2 puts a new step at position 2 (the macro now has 4 steps)"
mo_chk "$MO_A" "EditMacro 'cube': deleted step 5 (was: ZoomExtents) (4 step(s))" "EditMacro Delete 5 removes exactly that step"
MO_SHOW1="$(mo_block "$MO_A" "ShowMacro cube" 1)"
mo_chk "$MO_SHOW1" "  Description: Draws a cube and reads its volume" "ShowMacro: the description given to SaveMacro"
mo_chk "$MO_SHOW1" "  Tags: geometry, demo" "ShowMacro: the tags given to SaveMacro"
mo_chk "$MO_SHOW1" "    {size}  required" "ShowMacro: {size} is a declared, required parameter"
mo_chk "$MO_SHOW1" "    1: Box 0,0,0 {size},{size},0 {size}" "ShowMacro: step 1 is the edited Box line with its placeholders"
mo_chk "$MO_SHOW1" "    2: SelNone" "ShowMacro: step 2 is the inserted SelNone"
mo_chk "$MO_SHOW1" "    4: Volume" "ShowMacro: step 4 is Volume (the deleted ZoomExtents is gone)"
mo_chk "$MO_A" "Macro library: 1 macro(s)" "ListMacros counts the library"
mo_chk "$MO_A" "  cube  [4 step(s); params {size}; tags geometry, demo]  Draws a cube and reads its volume" "ListMacros row: name, step count, parameters, tags, description"
MO_T_CREATED1="$(grep -F '  Created: ' <<<"$MO_SHOW1" | head -1 || true)"
if grep -Eq '^  Created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$' <<<"$MO_T_CREATED1"; then echo "ok   Created is an ISO-8601 UTC timestamp ($MO_T_CREATED1)"; else echo "FAIL Created is not an ISO-8601 timestamp: $MO_T_CREATED1"; fail=1; fi

# -- run with arguments: Volume reads size^3 -------------------------------
mo_chk "$MO_A" "RunMacro 'cube': running 4 step(s) with size=2" "RunMacro size=2 substitutes {size} in all steps"
mo_cnt "$MO_A" "Volume = 8 cubic" "RunMacro cube size=2 draws a 2-edge box whose Volume reads 2^3 = 8 (once here; again after the rename below)" 2
mo_cnt "$MO_A" "Volume = 125 cubic" "RunMacro cube size=5: Volume reads 5^3 = 125 (a different argument gives a different measured result; the second is the by-name-bound alias cube5 below)" 2
mo_cnt "$MO_A" "Volume = 27 cubic" "RunMacro cube with NO argument uses the parameter's default (3): Volume reads 3^3 = 27 (again for the bound alias after the macro is edited)" 2
mo_chk "$MO_A" "Volume = 64 cubic" "RunMacro cube 4 (bare value fills the next parameter): Volume reads 4^3 = 64"
mo_chk "$MO_A" "EditMacro 'cube': parameter {size}=3, prompt \"Edge length\"" "EditMacro Param sets a default and a prompt"
MO_SHOW2="$(mo_block "$MO_A" "ShowMacro cube" 2)"
mo_chk "$MO_SHOW2" "    {size}  default \"3\", prompt \"Edge length\"" "ShowMacro reflects the default and prompt"
MO_T_CREATED2="$(grep -F '  Created: ' <<<"$MO_SHOW2" | head -1 || true)"
MO_T_MOD1="$(grep -F '  Modified: ' <<<"$MO_SHOW1" | head -1 || true)"
MO_T_MOD2="$(grep -F '  Modified: ' <<<"$MO_SHOW2" | head -1 || true)"
if [ "$MO_T_CREATED1" = "$MO_T_CREATED2" ] && [[ "$MO_T_MOD2" > "$MO_T_MOD1" ]]; then echo "ok   an edit leaves Created alone and strictly advances Modified ($MO_T_MOD1 -> $MO_T_MOD2)"; else echo "FAIL Created/Modified did not behave: [$MO_T_CREATED1|$MO_T_CREATED2] [$MO_T_MOD1|$MO_T_MOD2]"; fail=1; fi

# -- bad calls change/run nothing -------------------------------------------
mo_chk "$MO_A" "RunMacro: macro 'cube' has no parameter 'bogus' (parameters: size)" "an unknown key=value is refused and names the real parameters"
mo_chk "$MO_A" "RunMacro: too many values for macro 'cube' (1 parameter(s): size)" "too many bare values are refused"
mo_chk "$MO_A" "RunMacro: no saved macro named 'nosuch'" "RunMacro of an unknown macro warns"
mo_chk "$MO_A" "EditMacro: step number 99 is out of range (macro 'cube' has 4 step(s); valid here: 1..4)" "Delete 99 is refused with the valid range"
mo_chk "$MO_A" "EditMacro: step number 9 is out of range (macro 'cube' has 4 step(s); valid here: 1..5)" "Insert 9 is refused (valid insert positions are 1..steps+1)"
mo_chk "$MO_A" "EditMacro: no macro named 'nosuch'" "EditMacro of an unknown macro warns"
mo_chk "$MO_A" "SaveMacro: a macro named 'cube' already exists" "SaveMacro will not silently replace an existing macro"
mo_chk "$MO_A" "Replaced the steps of macro 'spare': 1 step(s), no parameters" "SaveMacro Overwrite=Yes replaces the steps"
MO_SPARE="$(mo_block "$MO_A" "ShowMacro spare" 1)"
mo_chk "$MO_SPARE" "    1: SelNone" "...and the new step list is what ShowMacro reads back"

# -- a required parameter is prompted for -----------------------------------
mo_chk "$MO_A" "RunMacro 'tall': needs a value for {h}" "RunMacro with a required parameter and no value prompts for it"
mo_chk "$MO_A" "RunMacro 'tall': running 4 step(s) with h=7" "the value typed at the prompt (7) is substituted"
mo_chk "$MO_A" "Volume = 7 cubic" "...and the box it drew has Volume 1*1*7 = 7"
mo_chk "$MO_A" "RunMacro: cancelled - no value given for {h}; nothing was run" "Enter at the prompt cancels the run without running any step"
mo_chk "$MO_A" "Volume = 9 cubic" "RunMacro tall h=9 (no prompt) draws the 1*1*9 box: Volume 9"

# -- the recorder does not record what a macro runs ---------------------------
mo_chk "$MO_A" "  RunMacro cube size=11" "with the recorder On, the typed RunMacro line is recorded"
mo_cnt "$MO_A" "  Box 0,0,0 11,11,0 11" "...but the Box line the macro ran is NOT also recorded (0 lines in the buffer dump)" 0
mo_chk "$MO_A" "Volume = 1331 cubic" "...although the macro did run (11^3 = 1331)"

# -- duplicate / rename / delete ----------------------------------------------
mo_chk "$MO_A" "Duplicated macro 'cube' as 'cube2'" "DuplicateMacro copies a macro"
mo_chk "$MO_A" "Renamed macro 'cube2' to 'cube_b' (0 alias binding(s) updated)" "RenameMacro renames"
mo_chk "$MO_A" "RenameMacro: a macro named 'cube' already exists" "RenameMacro refuses a clashing name"
mo_chk "$MO_A" "RenameMacro: no macro named 'nosuch'" "RenameMacro of an unknown macro warns"
MO_SHOW_B="$(mo_block "$MO_A" "ShowMacro cube_b" 1)"
mo_chk "$MO_SHOW_B" "  Description: the copy" "the duplicate's own description was edited..."
mo_chk "$MO_SHOW_B" "    1: Box 0,0,0 {size},{size},0 {size}" "...and it carries the original's steps"
MO_SHOW3="$(mo_block "$MO_A" "ShowMacro cube" 3)"
mo_chk "$MO_SHOW3" "  Description: Draws a cube and reads its volume" "editing the copy did not change the original"
mo_chk "$MO_A" "Macro library: 1 macro(s) shown of" "ListMacros Tag=copy filters to the tagged macro"
mo_chk "$MO_A" "Deleted macro 'cube_b'" "DeleteMacro removes it"
mo_chk "$MO_A" "ShowMacro: no macro named 'cube_b'" "...and ShowMacro then warns"
mo_chk "$MO_A" "DeleteMacro: no macro named 'cube_b'" "deleting it twice warns"

# -- quotes and braces in steps -----------------------------------------------
MO_QUOTED="$(mo_block "$MO_A" "ShowMacro quoted" 1)"
mo_chk "$MO_QUOTED" '    2: Echo "hello"' '\q in EditMacro text is stored as a literal double quote'
mo_chk "$MO_QUOTED" "    3: = print('\\{lit}')" "\\{ keeps a brace literal"
mo_chk "$MO_QUOTED" "Parameters (0):" "...and an escaped brace is not mistaken for a parameter"

# -- recursion guard ------------------------------------------------------------
mo_chk "$MO_A" "Command nesting too deep (a macro or alias that runs itself?)" "a macro that runs itself is stopped by the nesting guard instead of overflowing the stack"

# -- export / import round trip --------------------------------------------------
if [ -f "$MO_DIR/cube.json" ] && grep -qF '"format": "dino8-macro-library"' "$MO_DIR/cube.json" && grep -qF '"version": 1' "$MO_DIR/cube.json"; then echo "ok   ExportMacro wrote a file tagged format dino8-macro-library, version 1"; else echo "FAIL ExportMacro did not write a versioned library file"; fail=1; fi
if command -v python3 >/dev/null 2>&1; then
  MO_PY="$(python3 -I - "$MO_DIR/cube.json" "$MO_DIR/library.json" <<'PYEOF'
import json, sys
one = json.load(open(sys.argv[1], encoding="utf-8"))
lib = json.load(open(sys.argv[2], encoding="utf-8"))
m = one["macros"][0]
print("one:", one["format"], one["version"], len(one["macros"]), m["name"], len(m["steps"]), m["steps"][0], [p["name"] for p in m["parameters"]], m["parameters"][0]["default"], m["tags"])
print("lib:", lib["format"], lib["version"], sorted(x["name"] for x in lib["macros"]))
PYEOF
)" || MO_PY="python failed"
  mo_chk "$MO_PY" "one: dino8-macro-library 1 1 cube 4 Box 0,0,0 {size},{size},0 {size} ['size'] 3 ['geometry', 'demo']" "an independent JSON parser reads the exported macro: name, 4 steps, the {size} parameter with default 3, tags"
  mo_chk "$MO_PY" "lib: dino8-macro-library 1 ['cube', 'loopy', 'quoted', 'tall']" "ExportMacro * wrote the whole library (4 macros) in one versioned file"
fi
MO_SHOW5="$(mo_block "$MO_A" "ShowMacro cube" 4)"
MO_SHOW6="$(mo_block "$MO_A" "ShowMacro cube" 5)"
if [ -n "$MO_SHOW5" ] && [ "$MO_SHOW5" = "$MO_SHOW6" ]; then echo "ok   Export -> Delete -> Import round trip: ShowMacro is byte-identical (steps, parameters, tags, description, created AND modified times)"; else echo "FAIL the export/import round trip changed the macro"; echo "--- before"; echo "$MO_SHOW5"; echo "--- after"; echo "$MO_SHOW6"; fail=1; fi
mo_chk "$MO_A" "1 renamed to avoid a name clash" "ImportMacro of a clashing name renames it (default Conflict=Rename)"
mo_chk "$MO_A" "0 added (0 renamed to avoid a name clash), 0 replaced, 1 skipped" "ImportMacro Conflict=Skip skips it"
mo_chk "$MO_A" "0 added (0 renamed to avoid a name clash), 1 replaced, 0 skipped" "ImportMacro Conflict=Replace replaces it"
mo_chk "$MO_A" "  cube (2)  [4 step(s)" "the renamed import is in the library as 'cube (2)'"
mo_chk "$MO_A" "ImportMacro: cannot read $MO_DIRW/missing.json" "ImportMacro of a missing file warns"
mo_chk "$MO_A" "not a Dino 8 macro library file" "ImportMacro refuses a file of another format"
mo_chk "$MO_A" "written by a newer Dino 8 (macro format version 99; this build reads up to 1)" "ImportMacro refuses a file written by a newer version"
mo_chk "$MO_A" "is not valid JSON" "ImportMacro refuses garbage"

# -- binding by NAME to an alias and a toolbar button -----------------------------
mo_chk "$MO_A" "Bound macro 'cube' to alias 'cubea' (-> RunMacro \"cube\")" "BindMacro creates an alias that names the macro, not its text"
mo_chk "$MO_A" "added 'cubea' to the Standard toolbar" "BindMacro Toolbar=Yes adds a toolbar button"
mo_chk "$MO_A" "BindMacro: 'box' is a command name; pick a different alias" "BindMacro will not shadow a real command"
mo_chk "$MO_A" "Bound macro 'cube' to alias 'cube5' (-> RunMacro \"cube\" size=5)" "BindMacro Args= bakes arguments into the binding"
mo_chk "$MO_A" "Volume = 216 cubic" "the alias takes run-time arguments: 'cubea size=6' -> Volume 6^3 = 216"
mo_chk "$MO_A" "Area = 54 square" "after EditMacro Append Area the SAME alias (cubea size=3) runs the edited macro: the box's Area 6*3^2 = 54 (bindings are by name, so edits flow through)"
mo_chk "$MO_A" "Area = 24 square" "after RenameMacro cube cubic the alias still works (cubea size=2 -> Area 6*2^2 = 24, Volume 8 again)"
mo_chk "$MO_A" "Renamed macro 'cube' to 'cubic' (2 alias binding(s) updated)" "RenameMacro re-points both bound aliases"
MO_SHOW_BOUND="$(mo_block "$MO_A" "ShowMacro cubic" 1)"
mo_chk "$MO_SHOW_BOUND" "cubea (alias + toolbar button)" "ShowMacro lists the alias with its toolbar button"
mo_chk "$MO_SHOW_BOUND" "cube5 (alias)" "...and the second alias"
if grep '"toolbar":' "$MO_DIR/opts_bound.json" | grep -qF '"cubea"'; then echo "ok   OptionsExport: the bound alias is a button in the saved toolbar"; else echo "FAIL the toolbar array does not contain the bound alias"; fail=1; fi
if grep -qF '"cubea": "RunMacro \"cubic\""' "$MO_DIR/opts_bound.json"; then echo "ok   OptionsExport: the alias target follows the rename (RunMacro \"cubic\")"; else echo "FAIL the alias target did not follow the rename"; grep -F '"cubea"' "$MO_DIR/opts_bound.json" | head -3; fail=1; fi
mo_chk "$MO_A" "also removed the alias/toolbar binding(s): doomedalias" "DeleteMacro on a bound macro removes its alias..."
mo_chk "$MO_A" "Unknown command: doomedalias" "...so the dead alias is gone"
if grep '"toolbar":' "$MO_DIR/opts_after.json" | grep -qF '"doomedalias"'; then echo "FAIL the deleted macro's toolbar button is still in the toolbar"; fail=1; else echo "ok   ...and its toolbar button is gone from the saved toolbar"; fi
if grep '"toolbar":' "$MO_DIR/opts_after.json" | grep -qF '"cubea"'; then echo "ok   ...while the other macro's toolbar button is untouched"; else echo "FAIL the surviving toolbar button disappeared"; fail=1; fi
mo_chk "$MO_A" "Unbound alias 'cube5' from macro 'cubic'" "UnbindMacro removes just the alias"
mo_chk "$MO_A" "UnbindMacro: 'cube5' is not an alias bound to a macro" "...and a second UnbindMacro warns"
# In-process settings reload: OptionsImport restores a deleted macro.
MO_TEMP_SHOW="$(mo_block "$MO_A" "ShowMacro temp" 2)"
mo_chk "$MO_TEMP_SHOW" "Macro 'temp'" "OptionsExport -> DeleteMacro -> OptionsImport brings the deleted macro back (settings reload restores the library)"
mo_chk "$(mo_block "$MO_A" "ShowMacro temp" 1)" "ShowMacro: no macro named 'temp'" "...it really was gone in between"

# -- the older commands are the same store -------------------------------------------
mo_chk "$MO_A" "Saved macro 'oldstyle'" "the older MacroSave still works"
mo_chk "$MO_A" "  oldstyle  [1 step(s)]" "...and its macro shows up in ListMacros as an object"
mo_chk "$MO_A" "  Circle 0,0,0 3" "...MacroLoad puts it back in the plain-text editor buffer"

# -- B: persistence across a restart ----------------------------------------------------
MO_B="$(mo_exec "$MO_CFG_A" "$TMPW/mo_b.txt")" || { echo "$MO_B"; echo "FAIL: macro-objects script B exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$MO_B" || { echo "$MO_B"; echo "FAIL: macro-objects script B produced no smoke line"; fail=1; }
mo_chk "$MO_B" "  cubic  [5 step(s); params {size}=3; tags geometry, demo]  Draws a cube and reads its volume" "NEW PROCESS: the macro (renamed, edited, with its default) is in the library"
MO_B_SHOW="$(mo_block "$MO_B" "ShowMacro cubic" 1)"
mo_chk "$MO_B_SHOW" "    5: Area" "NEW PROCESS: the structured steps persisted, including the edit"
mo_chk "$MO_B_SHOW" "    {size}  default \"3\", prompt \"Edge length\"" "NEW PROCESS: the parameter default and prompt persisted"
mo_chk "$MO_B_SHOW" "cubea (alias + toolbar button)" "NEW PROCESS: the by-name alias binding and its toolbar button persisted"
mo_chk "$MO_B" "Volume = 343 cubic" "NEW PROCESS: the persisted alias runs the persisted macro: cubea size=7 -> Volume 7^3 = 343"
MO_B_CREATED="$(grep -F '  Created: ' <<<"$MO_B_SHOW" | head -1 || true)"
MO_A_CREATED="$(grep -F '  Created: ' <<<"$(mo_block "$MO_A" "ShowMacro cubic" 1)" | head -1 || true)"
if [ -n "$MO_B_CREATED" ] && [ "$MO_B_CREATED" = "$MO_A_CREATED" ]; then echo "ok   NEW PROCESS: Created survived the restart exactly ($MO_B_CREATED)"; else echo "FAIL Created changed across the restart: [$MO_A_CREATED] [$MO_B_CREATED]"; fail=1; fi
if grep -qF '"macro_library"' "$MO_CFG_A/$MO_SETTINGS_SUB/settings.json" && ! grep -qF '"macros": {' "$MO_CFG_A/$MO_SETTINGS_SUB/settings.json"; then echo "ok   settings.json carries the library under \"macro_library\" (and no longer writes the old \"macros\" text map)"; else echo "FAIL settings.json does not carry the macro library"; fail=1; fi

# -- C: migration of a pre-objects settings file -------------------------------------------
MO_CFG_C="$TMP/mo_cfg_c"; mkdir -p "$MO_CFG_C/$MO_SETTINGS_SUB"
printf '%s\n' '{"macro_text": "Line 0,0,0 4,0,0\nCircle 10,0,0 2\n", "macros": {"oldone": "Box 0,0,0 3,3,0 3;SelLast;Volume"}}' > "$MO_CFG_C/$MO_SETTINGS_SUB/settings.json"
MO_C="$(mo_exec "$MO_CFG_C" "$TMPW/mo_c.txt")" || { echo "$MO_C"; echo "FAIL: macro-objects script C exited non-zero"; exit 1; }
grep -E "^(ok|FAIL)" <<<"$MO_C" || true
if grep -q "^FAIL" <<<"$MO_C"; then fail=1; fi
grep -q "^smoke:" <<<"$MO_C" || { echo "$MO_C"; echo "FAIL: macro-objects script C produced no smoke line"; fail=1; }
mo_chk "$MO_C" "  Scratch  [2 step(s)]  Migrated from the Macro Editor's single text buffer" "MIGRATION: the old single macro_text buffer became a macro named 'Scratch' with 2 steps"
mo_chk "$MO_C" "  oldone  [3 step(s)]  Migrated from a saved macro (MacroSave)" "MIGRATION: an old saved ';'-text macro became an object, split into 3 steps"
mo_chk "$MO_C" "    2: Circle 10,0,0 2" "MIGRATION: Scratch's steps are the buffer's lines"
mo_chk "$MO_C" "Volume = 27 cubic" "MIGRATION: the migrated 'oldone' runs (Box 3x3x3 -> Volume 27)"
mo_chk "$MO_C" "  Line 0,0,0 4,0,0" "the plain-text editor buffer still holds the old text (RecordMacro dumps it)"
mo_chk "$MO_C" "  SelLast" "MacroLoad oldone puts the migrated macro's steps back into the plain-text editor buffer"
if grep -qF '"macro_text"' "$MO_DIR/opts_migrated.json" && grep -qF '"macro_library"' "$MO_DIR/opts_migrated.json" && ! grep -qF '"macros": {' "$MO_DIR/opts_migrated.json"; then echo "ok   after migration the settings carry both macro_text (the editor buffer) and macro_library"; else echo "FAIL migrated settings lack macro_text/macro_library"; fail=1; fi

# -- D: the panel renders (widgets themselves cannot be driven headlessly) --------------------
printf 'MacroEditor\nShowMacro cubic\n' > "$TMPW/mo_d.txt"
MO_D="$(mo_exec "$MO_CFG_A" "$TMPW/mo_d.txt")" || { echo "$MO_D"; echo "FAIL: macro-objects script D (panel) exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$MO_D" && echo "ok   the Macro Editor panel, with the library populated, renders for 100 frames without crashing or an ImGui assertion" || { echo "$MO_D"; echo "FAIL: macro editor panel run produced no smoke line"; fail=1; }

# Registry-based construction history (cmd_history.cpp / history_rebuild.h):
# one dispatch table re-executes every recorded construction through
# UpdateHistory in dependency order - Extrude/ExtrudeSrf/ExtrudeCrvTapered/
# ExtrudeCrvAlongCrv/PlanarSrf/NetworkSrf (3-4 curves)/EdgeSrf/Offset/OffsetSrf/
# RailRevolve and the four booleans, on top of the older ones. See
# tests/history_registry_script.txt: every UpdateHistory is followed by a
# MEASURED Volume/Area/Length, never just an object count.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HRG="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_registry_script.txt" 2>&1)" || { echo "$HRG"; echo "FAIL: history-registry script exited non-zero"; exit 1; }
else
  HRG="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_registry_script.txt" 2>&1)" || { echo "$HRG"; echo "FAIL: history-registry script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HRG"
if grep -q "^FAIL" <<<"$HRG"; then fail=1; fi
grep -q "^smoke:" <<<"$HRG" || { echo "$HRG"; echo "FAIL: history-registry script produced no smoke line"; fail=1; }
hrgcheck() { if grep -qF -- "$1" <<<"$HRG"; then echo "ok   $2"; else echo "FAIL $2"; near "$HRG" "$1"; fail=1; fi; }
HRGSEQ="$(grep -oE '^history: (Volume = [0-9.]+|Area = [0-9.]+|Curve [0-9]+ length = [0-9.]+|UpdateHistory: [0-9]+ object\(s\) re-evaluated|BooleanUnion: exact)' <<<"$HRG" | sed 's/^history: //' | tr '\n' '|' | sed -E 's/Volume = 224\.[56]\|/Volume = 224.6|/g; s/Volume = 180[12]\|/Volume = 1802|/g')"
HRGWANT="Volume = 250|Volume = 500|UpdateHistory: 2 object(s) re-evaluated|Volume = 500|Volume = 500|Volume = 500|BooleanUnion: exact|Volume = 1500|UpdateHistory: 3 object(s) re-evaluated|Volume = 1700|Volume = 500|UpdateHistory: 3 object(s) re-evaluated|Volume = 700|Volume = 1500|UpdateHistory: 3 object(s) re-evaluated|Volume = 1700|Volume = 250|UpdateHistory: 0 object(s) re-evaluated|Volume = 250|BooleanUnion: exact|Volume = 1500|UpdateHistory: 1 object(s) re-evaluated|Volume = 4000|Volume = 1000|Volume = 500|UpdateHistory: 2 object(s) re-evaluated|Volume = 2000|Area = 400|Volume = 1436|UpdateHistory: 1 object(s) re-evaluated|Volume = 6009|Area = 50|UpdateHistory: 1 object(s) re-evaluated|Area = 100|Area = 100|UpdateHistory: 1 object(s) re-evaluated|Area = 400|Area = 50|UpdateHistory: 1 object(s) re-evaluated|Area = 200|Curve 50 length = 18.85|Volume = 112.9|UpdateHistory: 2 object(s) re-evaluated|Curve 50 length = 50.27|Volume = 803.8|Volume = 1728|UpdateHistory: 2 object(s) re-evaluated|Volume = 5808|Volume = 224.6|UpdateHistory: 1 object(s) re-evaluated|Volume = 1802|Volume = 1802|BooleanUnion: exact|Volume = 2368|UpdateHistory: 2 object(s) re-evaluated|Volume = 2128|"
if [ "$HRGSEQ" = "$HRGWANT" ]; then echo "ok   history-registry: every measured value before/after each UpdateHistory is the analytic one (curve->Extrude->BooleanIntersection 250->500 after moving the curve; ->BooleanUnion 1500->1700; BooleanDifference 500->700; Boolean2Objects 1500->1700; root deleted keeps 250; PlanarSrf->ExtrudeSrf 500->2000 and area 100->400; ExtrudeCrvTapered 1436->6009; ExtrudeCrvAlongCrv 50->100; NetworkSrf 4 curves 100->400; EdgeSrf 3 curves 50->200; Offset length 18.85->50.27 and its extrusion 112.9->803.8; Extrude->OffsetSrf 1728->5808; RailRevolve 224.6->1802 = the fresh construction; exact Box->OffsetSrf->BooleanUnion 2368->2128)"; else echo "FAIL history-registry measured sequence differs"; echo "got:  $HRGSEQ"; echo "want: $HRGWANT"; fail=1; fi
hrgcheck "object 4: BooleanIntersection <- 2,3" "the History report lists the boolean with its two recorded operand ids (the operands are hidden sources, not deleted)"
hrgcheck "object 10: BooleanUnion <- 8,9" "...and a 3-deep curve -> Extrude -> BooleanUnion chain is listed with each link's sources"
hrgcheck "object 63: OffsetSrf <- 61" "...and OffsetSrf records its source solid"
hrgcheck "object 64: BooleanUnion <- 62,63" "...and the exact-B-rep boolean records both operands"
hrgcheck "! UpdateHistory: object 22 (Extrude) kept as it was: source object 21 no longer exists" "deleting the root curve: the extrusion is not rebuilt and the printed reason names the missing source"
hrgcheck "! UpdateHistory: object 24 (BooleanIntersection) kept as it was: it depends on object 22, which was not rebuilt (source object 21 no longer exists)" "...and the boolean built from it is skipped with the upstream reason instead of being rebuilt from a half-updated chain"
hrgcheck "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry, 2 skipped" "...and the summary counts both as skipped"
hrgcheck "History recording: off. 0 object(s) with live construction history" "History Off: a boolean made while Off recorded nothing"
hrgcheck "BooleanUnion: exact B-rep boolean (no tessellation), 14 face(s)" "...and (History Off) it still deletes its operands: 24 objects, the expect_objects in the script"
hrgcheck "Object 64 (polysurface) layer Default" "the exact-boolean result is still a polysurface after UpdateHistory (it did not degrade to a mesh)"
hrgcheck "  36 faces, 72 edges, closed solid" "...with the new shape's own topology (42 faces before the box moved, 36 after) and still a closed solid"

# Automatic history propagation + EditHistory (cmd_history.cpp, Document::
# JoinPendingChange, tests/history_auto_script.txt): with History On, editing a
# SOURCE object (Move/Scale/Delete/Undo/Redo here, no UpdateHistory call in the
# A sections) rebuilds every recorded dependent in dependency order inside the
# same undo step; EditHistory re-runs a recorded construction with new options.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HAU="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_auto_script.txt" 2>&1)" || { echo "$HAU"; echo "FAIL: history-auto script exited non-zero"; exit 1; }
else
  HAU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_auto_script.txt" 2>&1)" || { echo "$HAU"; echo "FAIL: history-auto script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HAU" || true
if grep -q "^FAIL" <<<"$HAU"; then fail=1; fi
grep -q "^smoke:" <<<"$HAU" || { echo "$HAU"; echo "FAIL: history-auto script produced no smoke line"; fail=1; }
haucheck() { if grep -qF -- "$1" <<<"$HAU"; then echo "ok   $2"; else echo "FAIL $2"; near "$HAU" "$1"; fail=1; fi; }
haucheckre() { if grep -qE -- "$1" <<<"$HAU"; then echo "ok   $2"; else echo "FAIL $2"; near "$HAU" "$1"; fail=1; fi; }
haucount() { local n; n="$(grep -cF -- "$1" <<<"$HAU" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HAU" "$1"; fail=1; fi; }
HAUSEQ="$(grep -oE '^history: (! )?(Volume = [0-9.]+|Bounding box min [^ ]+ max [^ ]+|History: source object\(s\) [0-9,]+ changed - [0-9]+ dependent\(s\) re-evaluated( \([0-9,]+\))?|UpdateHistory: [0-9]+ object\(s\) re-evaluated)' <<<"$HAU" | sed 's/^history: //' | tr '\n' '|')"
HAUWANT="Volume = 1728|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)|Bounding box min 4,-1,-1 max 16,11,11|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)|Volume = 5808|Volume = 1728|Volume = 5808|Volume = 250|History: source object(s) 6 changed - 2 dependent(s) re-evaluated (7,9)|Volume = 500|Volume = 250|Volume = 500|! History: source object(s) 6 changed - 0 dependent(s) re-evaluated|Volume = 500|History: source object(s) 6 changed - 2 dependent(s) re-evaluated (7,9)|Volume = 250|Volume = 1000|Volume = 1000|UpdateHistory: 1 object(s) re-evaluated|Volume = 4000|Volume = 3168|Volume = 6048|Volume = 3168|Volume = 1728|Volume = 3168|"
if [ "$HAUSEQ" = "$HAUWANT" ]; then echo "ok   history-auto: with NO UpdateHistory call, Moving/Scaling a curve rebuilds its extrusion and the offset solid built from it (2-deep chain: offset solid box -1..11 -> 4..16 after Move, volume 1728 -> 5808 after Scale 2x, back to 1728 on Undo and 5808 on Redo - one undo step covers the curve AND both dependents); the same for curve -> Extrude -> BooleanIntersection (250 -> 500, Undo 250, Redo 500); Delete of the root curve keeps the old geometry and prints the reason; Undo of the Delete + Move rebuilds again (250); History Off propagates nothing (1000) until UpdateHistory (4000)"; else echo "FAIL history-auto measured sequence differs"; echo "got:  $HAUSEQ"; echo "want: $HAUWANT"; fail=1; fi
haucheck "! History: source object(s) 6 changed - 0 dependent(s) re-evaluated, 2 kept as they were: object 7 - source object 6 no longer exists; object 9 - it depends on object 7, which was not rebuilt (source object 6 no longer exists)" "failure case: deleting the root curve prints ONE summary line naming each kept object and its reason (the dependent of the failed extrusion is skipped with the upstream reason)"
haucheck "Automatic updates this session: 4 dependent rebuild(s), 0 kept as they were" "an unrelated edit (Move of a box nothing depends on) rebuilt nothing: still the 4 rebuilds from the two curve edits"
haucheck "Automatic updates this session: 8 dependent rebuild(s), 2 kept as they were" "...and the session totals at the end: 4 + 2 + 2 rebuilt, the 2 kept from the Delete"
haucount "History: source object(s)" 5 "exactly five automatic-update lines in the whole run (2 + 1 + the failed Delete + 1): no other edit, including the unrelated Move, the Hide/Show, selection and EditHistory, triggered one"
haucheck "EditHistory: object 13 (Extrude) <- 12 - editable parameters (EditHistory 13 name=value ...):" "EditHistory with no key=value lists the object's editable parameters"
haucheck "  distance = 10   - extrusion distance along the recorded direction (non-zero; negative flips the direction)" "...with the current value and the valid range"
haucheck "  bothsides = no   - extrude symmetrically to both sides of the curve [yes|no]" "...and choice options with their choices"
haucheck "EditHistory: object 13 (Extrude): distance 10 -> 20." "EditHistory distance=20 reports the change"
haucheck "  before: bbox 0,50,0 to 10,60,10, volume 1000" "...with the measured geometry before (10x10x10 prism, volume 1000)"
haucheck "  after:  bbox 0,50,0 to 10,60,20, volume 2000" "...and after (z 0..20, volume 2000)"
haucheck "  dependents re-evaluated: 14" "...and the offset solid built from the extrusion is re-evaluated in the same step"
haucheck "  after:  bbox 0,50,-20 to 10,60,20, volume 4000" "bothsides=yes: the extrusion becomes symmetric about the curve (z -20..20, volume 4000; the offset solid follows to 6048, see the sequence)"
haucheck "EditHistory: object 13 unchanged - distance: distance must be non-zero" "a zero distance is refused and changes nothing"
haucheck "EditHistory: object 13 unchanged - 'bogus' is not an editable parameter of Extrude (valid: distance, bothsides, solid)" "an unknown parameter is refused, listing the valid names"
haucheck "EditHistory: object 13 unchanged - bothsides: 'maybe' is not one of: yes, no" "a bad choice value is refused, listing the choices"
haucheck "EditHistory: object 12 has no recorded construction history" "EditHistory on an object with no history says so"
haucheck "EditHistory: object 99 does not exist" "EditHistory on a missing id says so"
haucount "  distance = 10   - extrusion distance along the recorded direction" 2 "after Undo the RECORD is restored with the geometry: the parameter listing reads distance=10 originally, and again after the second Undo (the listing of 20 sits between them)"
haucount "  distance = 20   - extrusion distance along the recorded direction" 1 "...and reads distance=20 after the first Undo (undoing only the bothsides edit)"
haucheck "ListHistory: 1 object(s) with construction history:" "ListHistory names the recorded objects"
haucheck "  object 14 (polysurface): OffsetSrf <- 13  [distance=1, solid=no]" "...with each record's sources and parameters (the offset of the extruded rectangle is now an exact right-prism B-rep, a polysurface; it used to be a mesh)"
haucheck "      input 13 (polysurface)" "ShowHistory also names each input object"
haucheck "  after:  bbox -10,-10,0 to 10,10,5, volume 1302" "tapered extrusion: draft 10 -> 20 degrees measurably narrows the solid (1436 -> 1302)"
haucheck "  after:  bbox -10,-10,0 to 10,10,10, volume 3140" "...distance 10 draft 0 is the straight cylinder pi*100*10 = 3141.6"
haucheck "EditHistory: object 16 unchanged - draft: draft must be between -90 and 90 degrees (exclusive)" "an out-of-range draft is refused"
haucheck "EditHistory: object 18 (Revolve): angle 360 -> 180." "revolve angle 360 -> 180"
haucheck "volume 224.6" "...from the full-revolve volume 224.6"
haucheckre "volume 112\.[1-4]" "...to half of it (112.1 on Linux, 112.3 on the Windows tessellation)"
haucheck "EditHistory: object 18 unchanged - angle: angle must be greater than 0 and at most 360 degrees" "an angle over 360 is refused"
haucheck "EditHistory: object 20 (Pipe): radius 1 -> 2." "pipe radius 1 -> 2"
haucheckre "volume 31\.2[89]" "...volume pi*1*10 = 31.4 (tessellated 31.29 on Linux, 31.28 on Windows)"
haucheck "volume 125.4" "...to pi*4*10 = 125.7 (tessellated 125.4)"
haucheck "EditHistory: object 20 unchanged - radius: radius must be positive" "a negative radius is refused"
haucheck "EditHistory: object 24 (Loft): style normal -> straight." "loft style Normal -> Straight"
haucheck "  before: bbox 0,0,300 to 10,10,302.9, area 120.4" "...Normal interpolates smoothly through the middle line (area 120.4, z peak 302.9)"
haucheck "  after:  bbox 0,0,300 to 10,10,303, area 116.6" "...Straight is the ruled loft 2 * 10 * sqrt(5^2+3^2) = 116.6"
haucheck "EditHistory: object 26 (Offset): distance -2 -> -1." "curve offset distance -2 -> -1"
haucheck "length 18.85" "...inward offset circle r=3 has length 18.85"
haucheck "length 25.13" "...r=4 has length 25.13"
haucheck "length 37.7" "...and distance +1 flips to the outside, r=6: length 37.7"
haucount "operand groups swapped" 2 "boolean swap=yes twice"
haucheck "  after:  bbox 10,150,0 to 12,160,10, volume 200" "BooleanDifference swap=yes: A-B (800) becomes B-A (200)"
haucheck "  after:  bbox 0,150,0 to 12,160,10, volume 1200" "operation=union: 800 + 400 - 200 = 1200"
haucheck "  after:  bbox 8,150,0 to 10,160,10, volume 200" "operation=intersection: the 2 x 10 x 10 overlap, volume 200"
haucheck "  object 30: BooleanDifference <- 28,29  [operation=intersection]" "the History report names each record's parameters: the edited boolean now reads operation=intersection"
haucheck "  object 24: Loft <- 21,22,23  [style=normal, cap=yes]" "...and the loft's style/cap"


# Automatic history propagation, part 2 (tests/history_auto2_script.txt): the
# other ways a source is edited (Rotate, Mirror Copy=No, ScaleNU, a boolean
# OPERAND moved directly) rebuild the dependents with no UpdateHistory, inside
# the same undo step; every claim is a measured Volume.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HA2="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_auto2_script.txt" 2>&1)" || { echo "$HA2"; echo "FAIL: history-auto2 script exited non-zero"; exit 1; }
else
  HA2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_auto2_script.txt" 2>&1)" || { echo "$HA2"; echo "FAIL: history-auto2 script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HA2" || true
if grep -q "^FAIL" <<<"$HA2"; then fail=1; fi
grep -q "^smoke:" <<<"$HA2" || { echo "$HA2"; echo "FAIL: history-auto2 script produced no smoke line"; fail=1; }
ha2check() { if grep -qF -- "$1" <<<"$HA2"; then echo "ok   $2"; else echo "FAIL $2"; near "$HA2" "$1"; fail=1; fi; }
ha2count() { local n; n="$(grep -cF -- "$1" <<<"$HA2" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HA2" "$1"; fail=1; fi; }
HA2SEQ="$(grep -oE '^history: (Volume = [0-9.]+|History: source object\(s\) [0-9,]+ changed - [0-9]+ dependent\(s\) re-evaluated( \([0-9,]+\))?)' <<<"$HA2" | sed 's/^history: //' | tr '\n' '|')"
HA2WANT="Volume = 500|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,4)|Volume = 457.1|Volume = 500|Volume = 457.1|Volume = 600|History: source object(s) 5 changed - 2 dependent(s) re-evaluated (6,8)|Volume = 400|Volume = 1000|History: source object(s) 9 changed - 1 dependent(s) re-evaluated (10)|Volume = 3000|Volume = 500|History: source object(s) 13 changed - 1 dependent(s) re-evaluated (14)|Volume = 200|Volume = 500|"
if [ "$HA2SEQ" = "$HA2WANT" ]; then echo "ok   history-auto2: with NO UpdateHistory call a Rotate of the source square rebuilds the extrusion AND the boolean built from it (overlap with a fixed box 500 -> 457.1 = 10*(50-4.289), the diamond clipped to the box), Undo restores 500 and Redo 457.1 in single steps; Mirror Copy=No across x=10 moves it 600 -> 400; ScaleNU 3,1,1 takes an extrusion 1000 -> 3000; moving a boolean's OPERAND (the box, not its curve) rebuilds the boolean 500 -> 200 and Undo gives 500"; else echo "FAIL history-auto2 measured sequence differs"; echo "got:  $HA2SEQ"; echo "want: $HA2WANT"; fail=1; fi
ha2count "History: source object(s)" 4 "exactly four automatic-update lines (Rotate, Mirror, ScaleNU, operand Move): Undo/Redo, Show, selection and Volume triggered none"
ha2check "Automatic updates this session: 6 dependent rebuild(s), 0 kept as they were" "...and the session total is 2 + 2 + 1 + 1 rebuilds, none kept"
ha2count "History rebuild of a boolean: exact B-rep boolean declined" 3 "a boolean rebuilt automatically prints the same engine-decline reason the live command printed (3 mesh-path rebuilds)"

# ---------------------------------------------------------------------------
# viewport close (PARITY_MAP.md app_display "Per-object display mode override" +
# "View-dependent adaptive tessellation"): per-object RayTraced composited with
# rasterized objects (pixels), face-level brep refinement (triangle counts and
# sagitta vs an exact cylinder/sphere, no rebuild thrash), curve/SubD/mesh deep zoom,
# and the adaptive on/off setting persisted in settings.json.
# tests/viewport_close_script.txt builds everything; the checks are below.
# ---------------------------------------------------------------------------
mkdir -p "$TMPW/vpc"
sed "s|@TMP@|$TMPW/vpc|g" "$HERE/viewport_close_script.txt" > "$TMPW/viewport_close_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  VPC="$(timeout 900 env DINO8_RT_FRAMES=1 "$BIN" --smoke 30 --script "$TMPW/viewport_close_script.txt" 2>&1)" || { echo "$VPC"; echo "FAIL: viewport_close script exited non-zero"; exit 1; }
else
  VPC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" env DINO8_RT_FRAMES=1 "$BIN" --smoke 30 --script "$TMPW/viewport_close_script.txt" 2>&1)" || { echo "$VPC"; echo "FAIL: viewport_close script exited non-zero"; exit 1; }
fi
vpccheck() { if grep -q "$1" <<<"$VPC"; then echo "ok   $2"; else echo "FAIL $2"; near "$VPC" "$1"; fail=1; fi; }
vpcnum() { # DESC EXPR : EXPR is an awk expression over already-substituted numbers
  local r; r="$(awk "BEGIN { print ($2) ? \"yes\" : \"no\" }")"
  if [ "$r" = yes ]; then echo "ok   $1"; else echo "FAIL $1 [$2]"; fail=1; fi
}
# vpchdr N FIELD: FIELD of the N-th "LodStats: adaptive=" header line.
vpchdr() {
  awk -v n="$1" -v f="$2" '
    /LodStats: adaptive=/ { k++; if (k == n) { if (match($0, f "=[a-z0-9]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPC"
}
# vpcval N VIEWPORT FIELD: FIELD of the first object line of viewport VIEWPORT in the N-th LodStats call.
vpcval() {
  awk -v n="$1" -v v="$2" -v f="$3" '
    /LodStats: adaptive=/ { k++ }
    k == n && index($0, "LodStats: viewport " v " object ") { if (match($0, f "=[-0-9.e+]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } }' <<<"$VPC"
}
# vpcsag N FIELD: FIELD of the N-th "LodSagitta:" line.
vpcsag() {
  awk -v n="$1" -v f="$2" '
    /^LodSagitta: / || /history: LodSagitta: / { k++; if (k == n) { if (match($0, f "=[-0-9.e+]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPC"
}
vpccheck "gl_error=0" "viewport_close script ran without OpenGL errors"

# ---- Part A: per-object RayTraced, pixel level --------------------------------
python3 - "$TMPW/vpc" <<'PY' && echo "ok   per-object display modes work in a RayTraced viewport and RayTraced works per object: rasterized objects are depth-composited with the traced frame in BOTH directions (sphere in front hides the Pen box; Pen box in front hides the sphere)" || { echo "FAIL per-object RayTraced pixel check"; fail=1; }
import struct, sys
d = sys.argv[1]
def load(name):
    b = open(f'{d}/{name}.bmp', 'rb').read()
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', b[2:30])
    assert hdr == 40 and planes == 1 and bpp == 24, (name, hdr, planes, bpp)
    row = (w * 3 + 3) & ~3
    px = b[off:]
    def get(x, y):
        r = h - 1 - y
        i = r * row + x * 3
        return px[i + 2], px[i + 1], px[i]
    return w, h, get
def white(p): return all(c >= 235 for c in p)
all_t, front, back = load('a_all_traced'), load('a_sphere_front'), load('a_sphere_back')
sh_base, sh_rt = load('a_shaded_base'), load('a_shaded_rtsphere')
w, h, gb = back
ws = [(x, y) for y in range(h) for x in range(w) if white(gb(x, y))]
assert ws, 'no Pen-white pixels in a_sphere_back: the rasterized Pen box is missing from the RayTraced viewport'
xs, ys = [p[0] for p in ws], [p[1] for p in ws]
x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
s = (x1 - x0) / 8.6            # pixels per world unit (box B is 8.6 wide)
bx = int(cx + 3.8 * s)         # a point on B outside the sphere's radius-3 silhouette
ax = int(cx - 30 * s)          # centre of box A (x=-15)
print(f'B white bbox x {x0}..{x1} y {y0}..{y1} centre ({cx},{cy}) scale {s:.2f} px/unit; probes: B-edge ({bx},{cy}) A ({ax},{cy})')
def show(tag, im, pts):
    print(f'{tag:18s}', ' '.join(f'{n}={im[2](*p)}' for n, p in pts.items()))
pts = {'Bcentre': (cx, cy), 'Bside': (bx, cy), 'A': (ax, cy)}
for tag, im in (('all_traced', all_t), ('sphere_front', front), ('sphere_back', back), ('shaded_base', sh_base), ('shaded_rtsphere', sh_rt)): show(tag, im, pts)
g = lambda im, p: im[2](*p)
# NOTE: this environment's software GL (xvfb/llvmpipe) shows the GPU trace's OWN pixels as the dark background even for a
# plain box (the pre-existing RayTraced viewport has no pixel assertion anywhere), so what is measured here is what the
# composite itself decides: which objects the rasterizer draws, and depth occlusion between rasterized and traced objects.
# 1. B -> Pen (rasterized, flat white) while the sphere in FRONT is traced: B is visible beside the sphere, and the TRACED sphere
#    (whose depth the composite wrote) hides B's centre - there the traced frame shows through instead of the flat white
assert white(g(front, (bx, cy))), f'Pen box not rasterized beside the sphere: {g(front, (bx, cy))}'
assert not white(g(front, (cx, cy))), f'traced sphere in front does not hide the rasterized box centre: {g(front, (cx, cy))}'
# 2. sphere BEHIND the Pen box: the rasterized box hides the traced sphere
assert white(g(back, (cx, cy))), f'rasterized Pen box does not hide the traced sphere behind it: {g(back, (cx, cy))}'
# 3. A (never overridden) is traced in a RayTraced viewport, so the rasterizer must NOT draw it: it is not its Shaded red
assert g(front, (ax, cy)) != g(sh_base, (ax, cy)) and not white(g(front, (ax, cy))), 'box A was rasterized in the RayTraced viewport'
# 4. Shaded viewport + sphere overridden to RayTraced: the sphere is no longer rasterized-green, A and B (still rasterized) are
#    byte-identical to the all-Shaded capture
assert g(sh_base, (cx, cy))[1] > g(sh_base, (cx, cy))[0] + 40, 'shaded base sphere is not green'
assert g(sh_rt, (cx, cy)) != g(sh_base, (cx, cy)) and not (g(sh_rt, (cx, cy))[1] > g(sh_rt, (cx, cy))[0] + 40), 'sphere still rasterized after the RayTraced override'
assert g(sh_base, (ax, cy)) == g(sh_rt, (ax, cy)), 'rasterized box A changed when only the sphere was overridden to RayTraced'
assert g(sh_base, (bx, cy)) == g(sh_rt, (bx, cy)), 'rasterized box B changed when only the sphere was overridden to RayTraced'
PY
vpccheck "ObjectDisplayModes: object [0-9]* polysurface = Pen (viewport Top)" "ObjectDisplayModes lists the Pen override in the RayTraced viewport"
vpccheck "ObjectDisplayModes: object [0-9]* polysurface = RayTraced (viewport Top)" "ObjectDisplayModes lists RayTraced as a per-object (per-viewport) mode"
vpccheck "SetObjectDisplayMode: 1 object(s) now always shown RayTraced" "SetObjectDisplayMode RayTraced is accepted (no longer refused)"
VPC_RT_RT="$(grep -c 'ObjectDisplayModes: object [0-9]* polysurface = RayTraced (viewport Top)' <<<"$VPC" || true)"
vpcnum "RayTraced survives Save/New/Open through the .3dm (listed before and after the round trip)" "$VPC_RT_RT == 2"
if grep -q "GpuRaytracer::Init failed" <<<"$VPC"; then echo "FAIL GpuRaytracer::Init failed in the viewport_close script"; fail=1; else echo "ok   GpuRaytracer::Init did not fail in the viewport_close script"; fi

# ---- Part B: face-level refinement (sphere R500 + cylinder R100 through it, Front view) ----
V_OLD_TRIS="$(vpcval 2 Front tris)"; V_NEW_TRIS="$(vpcval 3 Front tris)"
V_OLD_FF="$(vpcval 2 Front fine_faces)"; V_NEW_FF="$(vpcval 3 Front fine_faces)"; V_TOT="$(vpcval 3 Front total_faces)"
V_OLD_MAX="$(vpcsag 1 max_sagitta)"; V_NEW_MAX="$(vpcsag 2 max_sagitta)"
V_OLD_MEAN="$(vpcsag 1 mean_sagitta)"; V_NEW_MEAN="$(vpcsag 2 mean_sagitta)"
V_OLD_IN="$(vpcsag 1 in_region)"; V_NEW_IN="$(vpcsag 2 in_region)"
echo "     visible-corner deep zoom on the +Z cylinder tip: whole-object (old) $V_OLD_TRIS tris, $V_OLD_IN in view, max/mean sagitta $V_OLD_MAX / $V_OLD_MEAN;  face-level (new) $V_NEW_TRIS tris ($V_NEW_FF of $V_TOT faces fine), $V_NEW_IN in view, max/mean sagitta $V_NEW_MAX / $V_NEW_MEAN"
vpcnum "face-level: only the visible faces are fine (fine_faces < total_faces, >= 1); the old whole-object build has fine_faces=0 (all faces at one level)" "$V_NEW_FF >= 1 && $V_NEW_FF < $V_TOT && $V_OLD_FF == 0"
vpcnum "face-level: the whole mesh is much smaller than the whole-object build ($V_NEW_TRIS < $V_OLD_TRIS)" "$V_NEW_TRIS < $V_OLD_TRIS"
vpcnum "face-level: the visible corner is MORE accurate (max sagitta new $V_NEW_MAX <= old $V_OLD_MAX) with the same budget" "$V_NEW_MAX <= $V_OLD_MAX"
vpcnum "face-level: and has at least as many triangles in the visible region (new $V_NEW_IN >= old $V_OLD_IN)" "$V_NEW_IN >= $V_OLD_IN"
vpcnum "the per-object budget still holds in both builds (<= 150000 triangles + 10%)" "$V_NEW_TRIS <= 165000 && $V_OLD_TRIS <= 165000"
# no thrash: steady frames never rebuild; moving to another face is ONE rebuild; returning is a stash hit
R3="$(vpchdr 3 rebuilds)"; R4="$(vpchdr 4 rebuilds)"; R5="$(vpchdr 5 rebuilds)"; R6="$(vpchdr 6 rebuilds)"; R7="$(vpchdr 7 rebuilds)"; R8="$(vpchdr 8 rebuilds)"
H3="$(vpchdr 3 stash_hits)"; H7="$(vpchdr 7 stash_hits)"
echo "     rebuilds across the face-level steps: after build $R3, +10 frames $R4, other face $R5, +10 frames $R6, back $R7, +10 frames $R8;  stash_hits $H3 -> $H7"
vpcnum "no per-frame rebuild thrash: ten more frames at the same view rebuild nothing" "$R4 == $R3"
vpcnum "...also after moving the view to a different face and after returning" "$R6 == $R5 && $R8 == $R7"
vpcnum "moving to another face rebuilds (at most 2 levels), returning is served from the stash (rebuilds unchanged, stash_hits up)" "$R5 - $R4 <= 2 && $R7 == $R6 && $H7 > $H3"
vpcnum "the other face is the fine one there (sphere view: fine_faces >= 1 and < total)" "$(vpcval 5 Front fine_faces) >= 1 && $(vpcval 5 Front fine_faces) < $(vpcval 5 Front total_faces)"
echo "     sphere face in view (R500, one face, nothing to cull inside it): $(vpcval 5 Front tris) tris, max/mean sagitta in the 25x30 window $(vpcsag 3 max_sagitta) / $(vpcsag 3 mean_sagitta) (the face alone exhausts the budget; a face this big is not refined only where visible)"
vpcnum "the single visible face may use the whole budget (>100000 triangles, <= 165000) - the other four faces stay at their small off-screen cap" "$(vpcval 5 Front tris) > 100000 && $(vpcval 5 Front tris) <= 165000"

# measurement commands do not depend on the camera: BoundingBox/Volume/Area at zoom-extents and at the deepest zoom agree exactly
VPC_BBN="$(grep -ac 'Bounding box min' <<<"$VPC" || true)"; VPC_BBD="$(grep -a 'Bounding box min' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"
VPC_VOD="$(grep -a 'Volume = ' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"; VPC_ARD="$(grep -a 'Area = ' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"
vpcnum "BoundingBox, Volume and Area read the same at zoom-extents and at a 12-unit deep zoom with the face-level mesh built (each printed twice, one distinct value)" "$VPC_BBN == 2 && $VPC_BBD == 1 && $VPC_VOD == 1 && $VPC_ARD == 1"

# ---- Part D: curves, SubD, mesh ------------------------------------------------
C0_N="$(vpcsag 5 total)"; C0_S="$(vpcsag 5 max_sagitta)"; C1_N="$(vpcsag 6 total)"; C1_S="$(vpcsag 6 max_sagitta)"
echo "     circle R500: whole view $C0_N segments max sagitta $C0_S;  deep zoom (12-unit window) $C1_N segments max sagitta $C1_S"
vpcnum "curve: deep zoom re-samples the circle finer (more segments) and the chord error drops with the zoom" "$C1_N > $C0_N && $C1_S < $C0_S"
vpcnum "curve: at deep zoom the chord error is below half a pixel of that zoom ($(vpcval 9 Top surface_tol) units)" "$C1_S < $(vpcval 9 Top surface_tol)"
S0="$(vpcval 10 Top tris)"; S1="$(vpcval 11 Top tris)"
echo "     SubD box 1000: smooth display triangles at zoom-extents $S0, in a 4-unit window $S1"
vpcnum "SubD: smooth display is subdivided deeper on zoom (more triangles at deep zoom), within the 150000-triangle budget" "$S1 > $S0 && $S1 <= 165000"
M0="$(vpcval 12 Top tris)"; M1="$(vpcval 13 Top tris)"
M0S="$(vpcsag 7 max_sagitta)"; M1S="$(vpcsag 8 max_sagitta)"
echo "     MeshSphere R500 (528 faces): display triangles at extents $M0 and at deep zoom $M1; sagitta of the mesh itself vs the exact sphere $M0S / $M1S"
vpcnum "mesh: the display level IS the mesh (same triangle count at every zoom; nothing re-tessellated)" "$M0 == $M1"

# ---- Part C: the adaptive on/off setting persists in settings.json -------------
mkdir -p "$TMPW/vpc_persist"
printf 'AdaptiveTessellation Off\n' > "$TMPW/vpc_persist/off.txt"
printf 'LodStats\n' > "$TMPW/vpc_persist/status.txt"
printf 'AdaptiveTessellation On\n' > "$TMPW/vpc_persist/on.txt"
run_vpc_persist() {
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 300 "$BIN" --smoke 10 --script "$1" 2>&1
  else
    timeout 300 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 10 --script "$1" 2>&1
  fi
}
VPC_P1="$(run_vpc_persist "$TMPW/vpc_persist/off.txt")" || { echo "$VPC_P1"; echo "FAIL: persist-off launch exited non-zero"; fail=1; }
if grep -q '"adaptive_tessellation": false' "$CONFIG_DIR/settings.json"; then echo "ok   settings.json stores \"adaptive_tessellation\": false after AdaptiveTessellation Off"; else echo "FAIL settings.json has no adaptive_tessellation=false"; grep -n adaptive "$CONFIG_DIR/settings.json"; fail=1; fi
VPC_P2="$(run_vpc_persist "$TMPW/vpc_persist/status.txt")" || { echo "$VPC_P2"; echo "FAIL: persist-status launch exited non-zero"; fail=1; }
if grep -q "LodStats: adaptive=off" <<<"$VPC_P2"; then echo "ok   a fresh launch reads adaptive tessellation OFF back from settings.json (the toggle survives sessions)"; else echo "FAIL fresh launch did not restore adaptive=off"; near "$VPC_P2" "LodStats: adaptive"; fail=1; fi
VPC_P3="$(run_vpc_persist "$TMPW/vpc_persist/on.txt")" || { echo "$VPC_P3"; echo "FAIL: persist-on launch exited non-zero"; fail=1; }
if grep -q '"adaptive_tessellation": true' "$CONFIG_DIR/settings.json"; then echo "ok   turning it back On is persisted too (\"adaptive_tessellation\": true)"; else echo "FAIL settings.json has no adaptive_tessellation=true"; fail=1; fi

# SetObjectDisplayMode is an undo step (independent review found it mutated the
# object with no BeginChange): Undo returns the object to the viewport's own mode,
# Redo reapplies it. (display_mode_undo_script.txt)
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  DMU="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/display_mode_undo_script.txt" 2>&1)" || { echo "$DMU"; echo "FAIL: display-mode undo script exited non-zero"; exit 1; }
else
  DMU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/display_mode_undo_script.txt" 2>&1)" || { echo "$DMU"; echo "FAIL: display-mode undo script exited non-zero"; exit 1; }
fi
dmu_count() { grep -c -- "$1" <<<"$DMU" || true; }
[ "$(dmu_count 'ObjectDisplayModes: 1 of 1 object(s) carry a per-object display mode Pen=1')" = "2" ] \
  && echo "ok   SetObjectDisplayMode Pen was applied, and Redo applied it again (two reports of Pen=1)" \
  || { echo "FAIL SetObjectDisplayMode Pen / Redo did not report Pen=1 twice"; fail=1; }
[ "$(dmu_count 'ObjectDisplayModes: 0 of 1 object(s) carry a per-object display mode')" = "1" ] \
  && echo "ok   Undo reverted SetObjectDisplayMode: the object is back on the viewport's own mode" \
  || { echo "FAIL Undo did not revert SetObjectDisplayMode"; fail=1; }

# ---------------------------------------------------------------------------
# SATS: SubD app-toolset QC (subd_apptoolset_script.txt) - two app-level gaps
# of the SubD bullets, measured through the real app:
#  (1) SubD booleans: SplitByObject with a SubD target or cutter returns two
#      SubD pieces (creased seam) instead of two flat Meshes.
#  (2) SubD symmetry: Symmetry Mode=Radial / TwoPlane on NON-SubD objects
#      (used to be skipped / a single plain mirror) builds live image copies.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SATS="$(timeout 900 "$BIN" --smoke 300 --script "$HERE/subd_apptoolset_script.txt" 2>&1)" || { echo "$SATS"; echo "FAIL: subd app-toolset script exited non-zero"; exit 1; }
else
  SATS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 300 --script "$HERE/subd_apptoolset_script.txt" 2>&1)" || { echo "$SATS"; echo "FAIL: subd app-toolset script exited non-zero"; exit 1; }
fi
sats_check() { if grep -q -- "$1" <<<"$SATS"; then echo "ok   $2"; else echo "FAIL $2"; near "$SATS" "$1"; fail=1; fi; }
sats_absent() { if grep -q -- "$1" <<<"$SATS"; then echo "FAIL $2"; near "$SATS" "$1"; fail=1; else echo "ok   $2"; fi; }
sats_count() { local n; n="$(grep -c -- "$1" <<<"$SATS" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3 ($n)"; else echo "FAIL $3 (found '$n', expected $2)"; near "$SATS" "$1"; fail=1; fi; }
# (2a) Radial, Brep box, Count=4 about the Z axis: three rotated images (90/180/270 degrees)
sats_check "Symmetry: 3 live radial copies created" "Symmetry Mode=Radial Count=4 on a non-SubD Brep makes 3 live rotated copies (before: skipped, radial needed a SubD cage)"
sats_check "Bounding box: (-2, 8, 0) to (2, 12, 4)" "radial image 1 of the box (8..12, -2..2) is the exact 90 degree rotation (-2..2, 8..12)"
sats_check "Bounding box: (-12, -2, 0) to (-8, 2, 4)" "radial image 2 is the exact 180 degree rotation (-12..-8, -2..2)"
sats_check "Bounding box: (-2, -12, 0) to (2, -8, 4)" "radial image 3 is the exact 270 degree rotation (-2..2, -12..-8)"
sats_check "Bounding box: (-7, 8, 0) to (-3, 12, 4)" "moving the source +5 in y live-moved image 1 to (-7..-3, 8..12): a live link, not a one-time bake"
sats_check "Bounding box: (3, -12, 0) to (7, -8, 4)" "moving the source +5 in y live-moved image 3 to (3..7, -12..-8)"
sats_count "Bounding box: (-7, 8, 0) to (-3, 12, 4)" 2 "after RemoveSymmetry a further source move did NOT move image 1 (still (-7..-3, 8..12))"
sats_absent "Bounding box: (-12, 8, 0) to (-8, 12, 4)" "the freed image never followed the post-removal move"
sats_check "RemoveSymmetry: 3 live symmetry link(s) removed" "RemoveSymmetry on the source removed all 3 radial image links"
# (2b) TwoPlane, Brep box: reflections across plane 1, plane 2 and both
sats_check "Symmetry: 3 live two-plane copies created" "Symmetry Mode=TwoPlane on a non-SubD Brep makes 3 live copies (reflect plane 1, plane 2, both)"
sats_check "Bounding box: (46, 2, 0) to (48, 4, 3)" "two-plane image 1: reflection across x=50 of (52..54, 2..4)"
sats_check "Bounding box: (52, -4, 0) to (54, -2, 3)" "two-plane image 2: reflection across y=0"
sats_check "Bounding box: (46, -4, 0) to (48, -2, 3)" "two-plane image 3: both reflections"
sats_check "Bounding box: (46, -5, 0) to (48, -3, 3)" "moving the source +1 in y live-moved the double image to (46..48, -5..-3)"
# (2c) Radial on a curve, Count=3: 120 and 240 degrees
sats_check "Symmetry: 2 live radial copies created" "Symmetry Mode=Radial Count=3 on a Line makes 2 live copies"
sats_check "Bounding box: (-5, 8.66025, 0) to (-5, 8.66025, 5)" "the Line (10,0,0)-(10,0,5) rotated 120 degrees lands at (-5, 8.66025)"
sats_check "Bounding box: (-5, -8.66025, 0) to (-5, -8.66025, 5)" "rotated 240 degrees lands at (-5, -8.66025)"
# (1) SplitByObject with SubD operands
sats_check "SplitByObject: 1 solid(s) split into 2 piece(s) (SubD boolean: the pieces are editable SubDs, 1108 face(s) in all, 322 crease edge(s) on the cut seams)" "SplitByObject of a SubD box by an overlapping SubD box: 2 SubD pieces, 1108 faces, 322 seam crease edges"
sats_check "Object 14 (SubD) layer Default" "the inside piece is a SubD object (before: a Mesh)"
sats_check "469 faces, 823 edges, 356 vertices, 162 creases" "inside piece: 469 faces, 162 creases (Euler 356 - 823 + 469 = 2, one closed body)"
sats_check "639 faces, 1165 edges, 528 vertices, 160 creases" "outside piece: 639 faces, 160 creases (Euler 528 - 1165 + 639 = 2, one closed body)"
sats_check "SplitByObject: 1 solid(s) split into 2 piece(s) (SubD boolean: the pieces are editable SubDs, 67[56] face(s) in all, 144 crease edge(s) on the cut seams)" "a SubD cutter through a Brep box target also yields SubD pieces (675 or 676 faces - the mesh boolean under it tessellates one triangle differently on Windows - and 144 seam creases)"
sats_check "does not intersect the cutting object(s)" "a SubD cutter that misses the target splits nothing"
sats_check "Object 20 (SubD) layer Default name 'MissTarget'" "the missed SubD target is still there, unchanged"
sats_check "Object 21 (SubD) layer Default name 'MissCutter'" "the missing cutter is not consumed"
sats_absent "(mesh boolean; results are meshes)" "no SubD-involving split fell through to the Mesh pipeline"
mapfile -t SATS_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SATS" | awk '{print $3}')
if [ "${#SATS_VOLS[@]}" -ge 5 ]; then
  echo "ok   subd app-toolset script printed ${#SATS_VOLS[@]} volumes"
  if awk -v a="${SATS_VOLS[1]}" 'BEGIN{exit !(a>11.99 && a<12.01)}'; then echo "ok   the two-plane reflected Brep copy has positive volume ${SATS_VOLS[1]} (box 2x2x3 = 12)"; else echo "FAIL two-plane copy volume ${SATS_VOLS[1]}"; fail=1; fi
  # outside piece (Volume #4) = A - B, inside piece (#5) = A and B; together they are the smooth 4-cube blob (0.327 x 64 = 20.9, +- 3%)
  if awk -v o="${SATS_VOLS[3]}" -v i="${SATS_VOLS[4]}" 'BEGIN{t=o+i; exit !(o>12.3 && o<12.5 && i>8.7 && i<8.95 && t>20.3 && t<21.6)}'; then echo "ok   SplitByObject pieces: outside ${SATS_VOLS[3]} + inside ${SATS_VOLS[4]} = $(awk -v o="${SATS_VOLS[3]}" -v i="${SATS_VOLS[4]}" 'BEGIN{printf "%.3f", o+i}') (the whole SubD box blob ~20.9; BooleanDifference/Intersection of the same boxes gave 12.43 / 8.829)"; else echo "FAIL SplitByObject piece volumes outside ${SATS_VOLS[3]}, inside ${SATS_VOLS[4]}"; fail=1; fi
else
  echo "FAIL subd app-toolset script printed only ${#SATS_VOLS[@]} volumes (expected 5)"; fail=1
fi
sats_check "gl_error=0" "subd app-toolset script ran without OpenGL errors"
sats_check "smoke: frames=[0-9]* objects=17 " "subd app-toolset script produced the expected object count"

# Patch with HOLES (patch_holes_script.txt): a non-planar Patch used to trim the
# fitted surface only when EXACTLY ONE closed curve was selected; with several the
# result was the untrimmed rectangle-extent surface. Now the closed curve enclosing
# the most area is the outer loop (Brep::TrimmedPatchFace) and every other closed
# curve wholly inside it is an inner loop of the same face. Data: the saddle
# z = 0.06 (x^2 - y^2); outer ring r = 5 (closed cubic, 24 control points), hole
# rings on the same surface. The areas are tessellation-derived, so they are
# range-checked (Windows tessellates slightly differently); the topology counts
# (faces/edges) and the kernel-measured deviations are exact/numeric.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PHL_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/patch_holes_script.txt" 2>&1)" || { echo "$PHL_OUT"; echo "FAIL: patch-holes script exited non-zero"; exit 1; }
else
  PHL_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/patch_holes_script.txt" 2>&1)" || { echo "$PHL_OUT"; echo "FAIL: patch-holes script exited non-zero"; exit 1; }
fi
phl_check() { if grep -q "$1" <<<"$PHL_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$PHL_OUT" "$1"; fail=1; fi; }
phl_count() { local n; n="$(grep -c "$1" <<<"$PHL_OUT" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$PHL_OUT" "$1"; fail=1; fi; }
# nth "Area = X" value (1-based) as a bare number
phl_area() { { grep -o 'Area = [0-9.]* square' <<<"$PHL_OUT" || true; } | sed -n "${1}p" | sed 's/Area = //; s/ square//'; }
# awk range test: phl_in_range VALUE LO HI
phl_in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }'; }
if grep -q "^FAIL" <<<"$PHL_OUT"; then echo "FAIL patch-holes script printed a FAIL line"; fail=1; fi
phl_count "^ok   expect_objects 0 (got 0)" 8 "patch-holes script: every case cleaned up after itself (8 sections, none left an object behind)"
phl_count "Patch: non-planar data - kernel least-squares NURBS" 5 "all five Patch cases reached the kernel's least-squares fit (no-hole reference, one hole, hole ring alone, two holes, overlapping negative control)"
phl_check "trimmed by the closed curve; the face's edge is within [0-9.e-]* of the curve" "a single closed non-planar curve keeps the original single-loop wording and trim (the no-hole reference, and the hole ring patched alone)"
phl_check "(9 x 9 net, worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1.5) trimmed by the closed curve with 1 hole(s) cut by the other closed curve(s); the worst of the 2 trimmed edges is within [0-9.e-]* of its curve" "outer ring + one inner ring: the larger curve is the boundary, the smaller one a hole, 2 trimmed edges, fit within the 0.001 tolerance"
phl_check "with 2 hole(s) cut by the other closed curve(s); the worst of the 3 trimmed edges is within [0-9.e-]* of its curve" "outer ring + two inner rings: 2 holes, 3 trimmed edges"
# Numeric: every kernel-measured figure is within the document tolerance 0.001 (measured 0.00016 and 0.00041 here)
PHL_DEV1="$({ grep -o 'the worst of the 2 trimmed edges is within [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* within //')"
PHL_DEV2="$({ grep -o 'the worst of the 3 trimmed edges is within [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* within //')"
if phl_in_range "$PHL_DEV1" 0 0.001; then echo "ok   one-hole face: worst trimmed-edge-to-curve deviation $PHL_DEV1 <= 0.001 (measured by the kernel, 0.00016 when written)"; else echo "FAIL one-hole face deviation '$PHL_DEV1' not in 0..0.001"; fail=1; fi
if phl_in_range "$PHL_DEV2" 0 0.001; then echo "ok   two-hole face: worst trimmed-edge-to-curve deviation $PHL_DEV2 <= 0.001 (0.00041 when written)"; else echo "FAIL two-hole face deviation '$PHL_DEV2' not in 0..0.001"; fail=1; fi
# Topology of the single resulting face (exact, not tessellation): List counts
phl_check "  1 faces, 2 edges, open" "one hole: ONE face with two edges (outer loop + hole loop), not a second face"
phl_check "  1 faces, 3 edges, open" "two holes: ONE face with three edges (outer loop + 2 hole loops)"
phl_count "Object [0-9]*: valid" 3 "Check reports the two hole faces and the five-curve NetworkSrf face valid"
# Areas (tessellation-derived: ranges). Closed form for the annulus on z = 0.06 (x^2 - y^2) between r = 4.97 and r = 1.98 is about 71.3;
# the unholed reference measured 84.93, the hole ring alone 12.55 (closed form for r = 1.98: 12.6).
PHL_A_REF="$(phl_area 1)"; PHL_A_HOLE="$(phl_area 2)"; PHL_A_RING="$(phl_area 3)"; PHL_A_TWO="$(phl_area 4)"
if phl_in_range "$PHL_A_REF" 83 87; then echo "ok   no-hole reference area $PHL_A_REF in 83..87 (84.93 when written)"; else echo "FAIL no-hole reference area '$PHL_A_REF'"; fail=1; fi
if phl_in_range "$PHL_A_HOLE" 70 73; then echo "ok   outer ring with the centre hole: area $PHL_A_HOLE in 70..73 (71.43 when written; closed form of the annulus 71.3)"; else echo "FAIL one-hole area '$PHL_A_HOLE' not in 70..73"; fail=1; fi
if phl_in_range "$PHL_A_RING" 12 13.1; then echo "ok   the hole ring patched alone: area $PHL_A_RING in 12..13.1 (12.55 when written; closed form 12.6)"; else echo "FAIL hole-ring-alone area '$PHL_A_RING'"; fail=1; fi
if awk -v a="$PHL_A_REF" -v h="$PHL_A_HOLE" -v r="$PHL_A_RING" 'BEGIN { d = a - h; exit !(a != "" && h != "" && r != "" && d > 0.9 * r && d < 1.2 * r) }'; then echo "ok   the hole really removes area: unholed minus holed ($PHL_A_REF - $PHL_A_HOLE) is within 0.9..1.2 x the hole ring's own patch area $PHL_A_RING"; else echo "FAIL hole area removed is not about the hole ring's own area (ref $PHL_A_REF, holed $PHL_A_HOLE, ring $PHL_A_RING)"; fail=1; fi
if phl_in_range "$PHL_A_TWO" 73 78; then echo "ok   outer ring with two holes (r = 1.2 at y = +-2.5): area $PHL_A_TWO in 73..78 (75.72 when written; about 74.3 closed form for the ideal saddle minus two discs)"; else echo "FAIL two-hole area '$PHL_A_TWO' not in 73..78"; fail=1; fi
# Negative control: a second ring that crosses the outer one is reported and the surface stays untrimmed
phl_check "Patch: closed curve 2 is not wholly inside the outer boundary; keeping the untrimmed fitted surface" "a second closed curve crossing the outer one is refused as a hole with the reason printed"
phl_check "untrimmed, spanning the data's extent" "...and the fitted surface is returned untrimmed (the old behavior for that input)"

# NetworkSrf through FIVE curves (same script, case 3): the command used to keep only the
# first 4 curves. Now the curves are chained into a closed loop (any order or direction;
# here scrambled, two drawn backwards), joined, fitted by the kernel's least-squares
# NurbsSurface::FitPatch and trimmed by the joined loop: ONE face. It is approximate (not an
# interpolating Coons patch) and says so, printing the measured deviations.
phl_check "NetworkSrf: 5 curves chained into a closed loop; kernel least-squares NURBS patch ([0-9]* x [0-9]* net, worst deviation from the curves [0-9.e-]* vs tolerance 0.001: met) trimmed by the joined loop, trimmed edge within [0-9.e-]* of the loop (approximate: fitted through the boundary samples, not an interpolating Coons patch)" "NetworkSrf of five scrambled/reversed pieces of the saddle ring chains, joins, fits within the 0.001 tolerance and trims, and labels itself approximate"
PHL_NW_FIT="$({ grep -o 'worst deviation from the curves [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* curves //')"
PHL_NW_EDGE="$({ grep -o 'trimmed edge within [0-9.e-]* of the loop' <<<"$PHL_OUT" || true; } | sed 's/trimmed edge within //; s/ of the loop//')"
if phl_in_range "$PHL_NW_FIT" 0 0.001; then echo "ok   five-curve NetworkSrf: fit deviation from the curves $PHL_NW_FIT <= 0.001 (0.00018 when written)"; else echo "FAIL five-curve NetworkSrf fit deviation '$PHL_NW_FIT'"; fail=1; fi
if phl_in_range "$PHL_NW_EDGE" 0 0.001; then echo "ok   five-curve NetworkSrf: trimmed edge within $PHL_NW_EDGE of the loop <= 0.001 (0.00017 when written)"; else echo "FAIL five-curve NetworkSrf edge deviation '$PHL_NW_EDGE'"; fail=1; fi
phl_check "  1 faces, 1 edges, open" "the five-curve NetworkSrf is ONE face bounded by ONE joined edge (not 5 edges, not the first 4 curves only)"
PHL_A_NW="$(phl_area 5)"
if phl_in_range "$PHL_A_NW" 83 89; then echo "ok   five-curve NetworkSrf area $PHL_A_NW in 83..89 (86.01 when written; the single-closed-curve Patch of the same saddle ring measures 84.93)"; else echo "FAIL five-curve NetworkSrf area '$PHL_A_NW'"; fail=1; fi
phl_check "NetworkSrf: 5 curves could not be fitted (the 5 curves do not close into a loop within the document tolerance 0.001 (largest corner gap 0.5)); using the first 4 curves only" "five curves open by 0.5 (> tolerance) are NOT silently fitted: the measured gap is the printed reason and the old first-4 behavior runs"

# DXF importer coverage (File I/O > DXF): SOLID/TRACE, polygon-mesh POLYLINE,
# SOLID/3DFACE inside a BLOCK, edge-type (LINE/ARC) HATCH boundaries and HATCH
# islands (outer loop plus holes).
# Before this pass each was silently dropped on open: SOLID/TRACE had no case
# in DxfImporter::Entity at all, a POLYLINE with the polygon-mesh flag (70 bit
# 16) went straight to "skipped", a 3DFACE inside a BLOCK was deferred to the
# end-of-file per-layer mesh flush and so never reached Insert()'s placement
# transform (the block's instances came back empty), and a HATCH whose
# boundary is a chain of LINE/ARC edges (92 without bit 0x2 - what AutoCAD
# writes when the boundary was picked from separate objects) was skipped.
# A HATCH with more than one boundary path (islands/holes, group 91 > 1) was
# skipped too.
# The fixtures are hand-written (tests/dxf_solid_polymesh_fixture.dxf,
# dxf_solid_block_fixture.dxf, dxf_hatch_edges_fixture.dxf) with every
# expected number derived by hand, independent of Dino 8's own exporter;
# dxf_solid_hatch_script.txt then also exports to DXF and reopens that in a
# fresh document to compare before/after area and bounding box.
# Hatch/curve numbers that come from tessellation use tolerance ranges (the
# Windows CI tessellates slightly differently); mesh numbers are exact.
cp "$HERE/dxf_solid_polymesh_fixture.dxf" "$TMPW/dxf_solid_polymesh_fixture.dxf"
cp "$HERE/dxf_solid_block_fixture.dxf" "$TMPW/dxf_solid_block_fixture.dxf"
cp "$HERE/dxf_hatch_edges_fixture.dxf" "$TMPW/dxf_hatch_edges_fixture.dxf"
cp "$HERE/dxf_hatch_islands_solid_fixture.dxf" "$TMPW/dxf_hatch_islands_solid_fixture.dxf"
cp "$HERE/dxf_hatch_islands_pattern_plain_fixture.dxf" "$TMPW/dxf_hatch_islands_pattern_plain_fixture.dxf"
cp "$HERE/dxf_hatch_islands_pattern_hole_fixture.dxf" "$TMPW/dxf_hatch_islands_pattern_hole_fixture.dxf"
sed "s|@TMP@|$TMPW|g" "$HERE/dxf_solid_hatch_script.txt" > "$TMPW/dxf_solid_hatch_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FIOX_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/dxf_solid_hatch_script.txt" 2>&1)" || { echo "$FIOX_OUT"; echo "FAIL: DXF SOLID/polymesh/hatch-edge script exited non-zero"; exit 1; }
else
  FIOX_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/dxf_solid_hatch_script.txt" 2>&1)" || { echo "$FIOX_OUT"; echo "FAIL: DXF SOLID/polymesh/hatch-edge script exited non-zero"; exit 1; }
fi
# fiox_chk DESC GREP-O-PATTERN N ERE: the N-th (1-based) match of the -o
# pattern in the script output must match the ERE. The output order is
# fixed by the script (section 1 meshes, section 2 block, section 3 hatches).
fiox_chk() {
  local v
  v="$( (grep -o -- "$2" <<<"$FIOX_OUT" || true) | sed -n "${3}p" )"
  if grep -Eq -- "$4" <<<"$v"; then echo "ok   $1 ($v)"; else echo "FAIL $1 (got '$v', expected /$4/)"; near "$FIOX_OUT" "$2"; fail=1; fi
}
fiox_has() { if grep -qF -- "$1" <<<"$FIOX_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$FIOX_OUT" "$1"; fail=1; fi; }
FIOX_AREA='Area = [0-9.]*'
FIOX_BBOX='Bounding box min [^ ]* max [^ ]*'
# -- 1. SOLID + polygon meshes
fiox_has "DXF: 0 curves, 0 points, 3 meshes, 2 new layers; 1 unsupported entity skipped" "SOLID x3, a 3x3 polygon mesh and a closed 4x2 polygon mesh all import as meshes; the smooth-surface (group 75=6) polygon mesh is declined, not guessed at"
fiox_has "  9 vertices, 4 faces" "the 3x3 polygon mesh is 9 vertices / 2x2 = 4 quads"
fiox_has "  8 vertices, 4 faces" "the 4x2 polygon mesh closed in M (flag 1) wraps to 4 quads, not 3"
fiox_has "  11 vertices, 3 faces" "the three SOLIDs (quad, triangle, OCS-extruded quad) merge into one 3-face mesh"
fiox_chk "SOLID fills: total area = 50 (quad, stored 1-2-4-3 corner order) + 50 (triangle) + 12 (OCS quad)" "$FIOX_AREA" 1 '^Area = 112$'
fiox_chk "SOLID fills: bounding box, incl. the OCS extrusion (0,0,-1) mapping (x,y,z)->(-x,y,-z)" "$FIOX_BBOX" 1 '^Bounding box min -104,0,-2 max 30,10,0$'
fiox_chk "3x3 polygon mesh on plane z=(x+y)/10: area = 400*sqrt(1.02) = 403.98" "$FIOX_AREA" 2 '^Area = 40[34](\.[0-9]*)?$'
fiox_chk "3x3 polygon mesh bounding box" "$FIOX_BBOX" 2 '^Bounding box min 200,0,0 max 220,20,4$'
fiox_chk "closed 4x2 square tube (side 10, height 10): lateral area = 400" "$FIOX_AREA" 3 '^Area = 400$'
fiox_chk "closed 4x2 square tube bounding box" "$FIOX_BBOX" 3 '^Bounding box min 295,-5,0 max 305,5,10$'
fiox_chk "all three meshes: total area 112 + 403.98 + 400 = 916" "$FIOX_AREA" 4 '^Area = 91[56](\.[0-9]*)?$'
fiox_has "DXF: 0 curves, 0 points, 2 meshes, 2 new layers" "export -> reopen: the SOLID fills and the polygon meshes come back as 3DFACE meshes (one per layer)"
fiox_chk "round trip keeps the total mesh area (before == after)" "$FIOX_AREA" 5 '^Area = 91[56](\.[0-9]*)?$'
fiox_chk "round trip keeps the overall bounding box" "$FIOX_BBOX" 4 '^Bounding box min -104,-5,-2 max 305,20,10$'
# -- 2. SOLID + 3DFACE inside a BLOCK (2 instances: unscaled at 500,0,0; x2 scaled and rotated 90 deg at 600,0,0)
fiox_has "DXF: 0 curves, 0 points, 4 meshes, 2 block instances flattened" "a SOLID and a 3DFACE inside a BLOCK survive into both flattened INSERT instances (4 meshes, not 0)"
fiox_chk "block instances: area = (4+2) + (4+2)*2^2 = 30" "$FIOX_AREA" 6 '^Area = 30$'
fiox_chk "block instances: bounding box (instance 2 scaled x2, rotated 90 deg about its insert point)" "$FIOX_BBOX" 5 '^Bounding box min 500,0,0 max 600,4,4$'
# -- 3. edge-type HATCH boundaries
fiox_has "DXF: 0 curves, 0 points, 0 meshes, 4 hatches, 1 new layer; 2 unsupported entities skipped" "4 edge-boundary HATCHes import (3 solid + 1 pattern); the elliptic-arc-edge and the open-chain hatch are declined"
fiox_chk "hatch A (square + semicircle, LINE/ARC/LINE/LINE edges): area = 100 + 12.5*pi = 139.27" "$FIOX_AREA" 7 '^Area = (138\.[5-9]|139\.[0-3])[0-9]*$'
fiox_chk "hatch A bounding box (arc tessellated: max x ~15)" "$FIOX_BBOX" 6 '^Bounding box min 0,0,0 max 1[45](\.[0-9]*)?,10,0$'
fiox_chk "hatch B (shuffled, two edges stored reversed): area = 200" "$FIOX_AREA" 8 '^Area = 200$'
fiox_chk "hatch B bounding box" "$FIOX_BBOX" 7 '^Bounding box min 100,0,0 max 120,10,0$'
fiox_chk "hatch C (disc from a ccw AND a clockwise 73=0 arc edge): area = 16*pi = 50.27" "$FIOX_AREA" 9 '^Area = (49\.[5-9]|50\.[0-3])[0-9]*$'
fiox_chk "hatch C bounding box = the full disc (a wrong cw-arc sweep would collapse one half)" "$FIOX_BBOX" 8 '^Bounding box min 19[5-6](\.[0-9]*)?,-[34](\.[0-9]*)?,0 max 20[34](\.[0-9]*)?,[34](\.[0-9]*)?,0$'
fiox_chk "all three solid hatches: 139.27 + 200 + 50.27 = 389.54" "$FIOX_AREA" 10 '^Area = (388\.[5-9]|389\.[0-9]|390)[0-9]*$'
fiox_chk "pattern hatch D over a 30x20 line-edge loop: its hatch lines reach the far corner of the loop (x 330, y 20)" "$FIOX_BBOX" 9 '^Bounding box min 0,-[34](\.[0-9]*)?,0 max 330,20,0$'
fiox_has "DXF: 36 curves, 0 points, 0 meshes, 3 hatches, 1 new layer" "export -> reopen: the 3 solid hatches round-trip as real HATCH entities (the pattern hatch's lines return as 36 curves)"
fiox_chk "round trip keeps the solid-hatch area (before 389.5 / after within 1%)" "$FIOX_AREA" 11 '^Area = (38[5-9]|390)(\.[0-9]*)?$'
# -- 4. HATCH islands (several boundary paths: one outer loop plus holes)
fiox_has "DXF: 0 curves, 0 points, 0 meshes, 1 hatch, 1 new layer; 2 unsupported entities skipped" "islands: the 100x100 solid hatch with a polyline hole and an edge-type circular hole imports; the hole that pokes out of its outer loop and the two overlapping holes are declined, not filled wrongly"
fiox_chk "islands: solid fill area = 10000 - 400 (20x20 polyline hole) - 314.16 (r 10 circle hole) = 9285.84" "$FIOX_AREA" 12 '^Area = 928[0-9](\.[0-9]*)?$'
fiox_chk "islands: the filled face spans the full outer loop" "$FIOX_BBOX" 10 '^Bounding box min 0,0,0 max 100,100,0$'
fiox_has "DXF: 0 curves, 0 points, 0 meshes, 1 hatch, 1 new layer" "islands: export -> reopen: the holed solid fill is written as ONE HATCH with three boundary paths and read back as one hatch"
fiox_chk "islands: round trip keeps the holes (area after ~ area before 9285.84; without the holes it would be 10000)" "$FIOX_AREA" 13 '^Area = 928[0-9](\.[0-9]*)?$'
fiox_has "(113 objects)" "islands: ANSI31 over the plain 100x100 loop makes 113 hatch lines"
fiox_has "(170 objects)" "islands: the same pattern with a centred 50x50 hole makes 170 pieces (every line crossing the hole is split in two)"
FIOX_LEN_PLAIN="$( (grep -o 'Total length = [0-9.]*' <<<"$FIOX_OUT" || true) | sed -n 1p | sed 's/.*= //')"
FIOX_LEN_HOLE="$( (grep -o 'Total length = [0-9.]*' <<<"$FIOX_OUT" || true) | sed -n 2p | sed 's/.*= //')"
if awk -v a="${FIOX_LEN_PLAIN:-0}" -v b="${FIOX_LEN_HOLE:-0}" 'BEGIN { r = (a > 0) ? b / a : 0; exit !(a > 7900 && a < 8100 && r > 0.745 && r < 0.755) }'; then
  echo "ok   islands: hatch-line length with the 50x50 hole is 75% of the plain one, as the area ratio demands (plain $FIOX_LEN_PLAIN, holed $FIOX_LEN_HOLE)"
else
  echo "FAIL islands: hatch-line length ratio (plain '$FIOX_LEN_PLAIN', holed '$FIOX_LEN_HOLE', expected ~8000 and 0.75)"; near "$FIOX_OUT" "Total length = "; fail=1
fi

# SR: exact revolved-solid editing (solidsrev_script.txt) - closes two more
# sub-gaps of "Solid editing with B-rep results (booleans, fillet, shell,
# offset)": OffsetSrf Solid=Yes on a plain capped cylinder (the hollow wall
# between the original and the offset, two shells of one Brep) and OffsetSrf /
# Shell on a plain capped cone and cone frustum (the (radius, height) profile
# is offset with sharp corners and revolved: every face an exact revolved
# surface). All of these used to give meshes. Every case is bracketed by an
# SRBEGIN_<name> marker; srblock slices the app output into that case.
# Volumes are read from the display mesh, so the ranges carry that tessellation
# error (measured 0.05-0.15% low here; +-0.6% allowed for other platforms);
# face/edge counts and "closed solid" are topological, so those are exact.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SROUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/solidsrev_script.txt" 2>&1)" || { echo "$SROUT"; echo "FAIL: solidsrev script exited non-zero"; exit 1; }
else
  SROUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/solidsrev_script.txt" 2>&1)" || { echo "$SROUT"; echo "FAIL: solidsrev script exited non-zero"; exit 1; }
fi
srblock() { awk -v name="$1" '$0 ~ ("Unknown command: SRBEGIN_" name "$") { on = 1; next } on && /Unknown command: SRBEGIN_|Unknown command: SREND/ { exit } on { print }' <<<"$SROUT"; }
srcheck() { local blk; blk="$(srblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Shell|Offset|Object|  [0-9]|Volume|!)" <<<"$blk" | head -8 | sed 's/^/     actual:   /' || true; fail=1; fi; }
# srvol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
srvol() {
  local blk v; blk="$(srblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- OffsetSrf Solid=Yes on a plain cylinder
srcheck O_cyl_solid_out "OffsetSrf: distance 1, 1 object(s), solid, 1 exact B-rep" "cylinder Solid=Yes is an exact B-rep (before: a 13420-triangle mesh, reason 'planar-only B-rep boolean')"
srcheck O_cyl_solid_out "(polysurface)" "...a polysurface"
srcheck O_cyl_solid_out "6 faces, 6 edges, closed solid" "...6 faces (outer 3 + reversed inner 3), a closed solid"
srvol O_cyl_solid_out 912 922 "cylinder r5 h20 Solid=Yes +1: Volume = pi*(36*22 - 25*20) = 917.35"
srcheck O_cyl_solid_out "Object 2: valid" "...and Check reports the result valid"
srcheck O_cyl_solid_out "0 bad object(s) selected" "...SelBadObjects selects nothing"
srcheck O_cyl_solid_in "solid, 1 exact B-rep" "Solid=Yes inward (the offset cylinder is the inner shell) is exact too"
srcheck O_cyl_solid_in "6 faces, 6 edges, closed solid" "...6 faces, closed solid"
srvol O_cyl_solid_in 662 670 "cylinder Solid=Yes -1: Volume = pi*(25*20 - 16*18) = 666.0"
srcheck O_cyl_solid_in "Object 2: valid" "...valid"
srcheck O_cyl_plain "3 faces, 3 edges, closed solid" "control: Solid=No on a cylinder is still the single exact 3-face cylinder"
srvol O_cyl_plain 2473 2503 "control: grown cylinder Volume = pi*36*22 = 2488.1"
srcheck O_cyl_solid_collapse "exact B-rep offset not used (the cylinder would collapse at that offset)" "shrinking past the radius: exact refused WITH the reason"
srcheck O_cyl_solid_collapse "(mesh)" "...and the mesh offset runs"
srcheck O_cyl_solid_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
# --- OffsetSrf on a plain cone / frustum
srcheck O_cone "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "cone offset is exact (before: a mesh)"
srcheck O_cone "2 faces, 3 edges, closed solid" "...the offset is again a 2-face cone"
srvol O_cone 603.5 610.5 "cone r5 h10 +1 = cone r6.618 h13.236: Volume = 607.08"
srcheck O_cone "Object 2: valid" "...valid"
srcheck O_cone_solid "solid, 1 exact B-rep" "cone Solid=Yes is exact"
srcheck O_cone_solid "4 faces, 6 edges, closed solid" "...4 faces (outer 2 + inner 2), closed solid"
srvol O_cone_solid 343 347.5 "cone Solid=Yes hollow wall Volume = 607.08 - 261.80 = 345.28"
srcheck O_cone_solid "Object 2: valid" "...valid"
srcheck O_tcone "1 exact B-rep" "frustum offset is exact"
srcheck O_tcone "3 faces, 5 edges, closed solid" "...3 faces, closed solid"
srvol O_tcone 962 974 "frustum r5->r3 h10 +1: Volume = 968.05"
srcheck O_tcone "Object 2: valid" "...valid"
srcheck O_tcone_solid_in "solid, 1 exact B-rep" "frustum Solid=Yes inward is exact"
srcheck O_tcone_solid_in "6 faces, 10 edges, closed solid" "...6 faces, closed solid"
srvol O_tcone_solid_in 282.8 286.3 "frustum hollow wall Volume = 513.13 - 228.58 = 284.55"
srcheck O_tcone_solid_in "Object 2: valid" "...valid"
srcheck O_cone_collapse "exact B-rep offset not used (the cone would collapse or self-intersect at that offset)" "shrinking a cone past its axial inradius: exact refused WITH the reason"
srcheck O_cone_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
# --- Shell of a plain cone / frustum
srcheck S_cone_closed "Shell: thickness 1, closed, exact B-rep" "cone closed shell is exact (before: a mesh)"
srcheck S_cone_closed "4 faces, 6 edges, closed solid" "...4 faces (outer 2 + inner 2), closed solid"
srvol S_cone_closed 179.5 182 "hollow cone Volume = 261.80 - 81.02 = 180.78"
srcheck S_cone_closed "Object 2: valid" "...valid"
srcheck S_cone_cap "open (1 face(s) removed), exact B-rep" "cone with its flat cap removed is an exact open cup"
srcheck S_cone_cap "3 faces, 5 edges, closed solid" "...3 faces (outer wall, inner wall, rim annulus), closed solid"
srvol S_cone_cap 138.3 140.3 "cone cup Volume = 139.28"
srcheck S_cone_cap "Object 2: valid" "...valid"
srcheck S_cone_wall "exact B-rep shell not used (only one flat cap of a cone can be removed exactly" "removing the cone's WALL: no exact construction, reason printed, mesh kept"
srcheck S_cone_wall "(mesh)" "...a mesh"
srcheck S_cone_thick "exact B-rep shell not used (the wall thickness is too large for this cone)" "a wall as thick as the cone: refused WITH the reason"
srcheck S_tcone_closed "Shell: thickness 1, closed, exact B-rep" "frustum closed shell is exact"
srcheck S_tcone_closed "6 faces, 10 edges, closed solid" "...6 faces, closed solid"
srvol S_tcone_closed 282.8 286.3 "hollow frustum Volume = 284.55"
srcheck S_tcone_closed "Object 2: valid" "...valid"
srcheck S_tcone_top "open (1 face(s) removed), exact B-rep" "frustum with the small (top) cap removed is an exact cup"
srcheck S_tcone_top "5 faces, 9 edges, closed solid" "...5 faces, closed solid"
srvol S_tcone_top 269.2 272.7 "frustum top-open cup Volume = 270.94"
srcheck S_tcone_top "Object 2: valid" "...valid"
srcheck S_tcone_bottom "open (1 face(s) removed), exact B-rep" "frustum with the big (bottom) cap removed is an exact cup"
srcheck S_tcone_bottom "5 faces, 9 edges, closed solid" "...5 faces, closed solid"
srvol S_tcone_bottom 235.7 238.8 "frustum bottom-open cup Volume = 237.24"
srcheck S_tcone_bottom "Object 2: valid" "...valid"
srcheck S_cone_exactno "(mesh)" "old behaviour reachable: Exact=No gives the mesh shell"
# --- ChamferEdge on the rim of a plain cone / frustum
srcheck C_tcone_bottom "replaced with an exact chamfer (radius 1; exact cone on the cylinder rim" "frustum bottom-rim chamfer is an exact revolved bevel (before: the approximate mesh fallback)"
srcheck C_tcone_bottom "(polysurface)" "...a polysurface"
srcheck C_tcone_bottom "4 faces, 7 edges, closed solid" "...4 faces (cap, bevel cone, wall, top cap), 7 edges, closed solid"
srvol C_tcone_bottom 496 501.5 "frustum r5->r3 h10 with a 1x1 bottom bevel: Volume = 498.95"
srcheck C_tcone_bottom "Object 1: valid" "...Check reports it valid"
srcheck C_tcone_top "replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "frustum top-rim chamfer with Distance2 (wall 1, cap 2) is exact: the two distances are honoured"
srcheck C_tcone_top "4 faces, 7 edges, closed solid" "...4 faces, closed solid"
srvol C_tcone_top 495.4 501.3 "frustum top bevel wall 1 / cap 2: Volume = 498.35"
srcheck C_tcone_top "Object 1: valid" "...valid"
srcheck C_cone_rim "replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "plain cone rim chamfer with Distance2 is exact"
srcheck C_cone_rim "3 faces, 5 edges, closed solid" "...3 faces, closed solid"
srvol C_cone_rim 236.9 239.7 "cone r5 h10 rim bevel wall 1 / cap 2: Volume = 238.28"
srcheck C_cone_rim "Object 1: valid" "...valid"
srcheck C_cone_toobig "cone-rim attempt: a chamfer distance consumes the whole wall or cap" "a cap distance larger than the cap: refused WITH the cone-rim reason in the diagnostic"
srcheck C_cone_toobig "2 faces, 2 edges, closed solid" "...and the cone is left untouched"
if grep -q "^FAIL" <<<"$SROUT"; then echo "FAIL solidsrev script reported an in-script FAIL"; fail=1; fi

# --- SBX: ToSubD on a closed Brep box (sbx_script.txt) -------------------------
# MeshFromSelection's exact path (SubD::FromBrep) used to count every Brep it
# accepted as "verified" with worst deviation 0.000000 WITHOUT measuring, and
# FromBrep creases only naked edges, so a closed box became a 6-face cage with
# 0 creases whose Catmull-Clark limit surface is a rounded blob (ToNURBS
# volume 327.1 instead of 1000). The sharp Brep edges (dihedral > 35 degrees)
# are now creased and the limit surface is measured against the Brep.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SBX_OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/sbx_script.txt" 2>&1)" || { echo "$SBX_OUT"; echo "FAIL: sbx script exited non-zero"; exit 1; }
else
  SBX_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/sbx_script.txt" 2>&1)" || { echo "$SBX_OUT"; echo "FAIL: sbx script exited non-zero"; exit 1; }
fi
sbxcheck() { if grep -q -- "$1" <<<"$SBX_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$SBX_OUT" "$1"; fail=1; fi; }
# The first ToSubD line is the box's, the last is the sphere's (negative control).
SBX_BOX_LINE="$(grep -m1 "^history: ToSubD: created" <<<"$SBX_OUT" || true)"
SBX_SPH_LINE="$(grep "^history: ToSubD: created" <<<"$SBX_OUT" | tail -n 1 || true)"
SBX_BOX_VERIFIED="$(grep -o "([0-9]* of 1 limit-surface-fidelity" <<<"$SBX_BOX_LINE" | grep -o "[0-9]*" | head -n 1 || true)"
SBX_BOX_DEV="$(grep -o "worst measured deviation [0-9.]*" <<<"$SBX_BOX_LINE" | grep -o "[0-9.]*$" || true)"
# (1) the printed fidelity claim is consistent with the measured number: "1 of 1"
# only when the deviation is within the printed 0.001 tolerance, "0 of 1" otherwise.
if [ -n "$SBX_BOX_DEV" ] && [ -n "$SBX_BOX_VERIFIED" ] && awk -v d="$SBX_BOX_DEV" -v v="$SBX_BOX_VERIFIED" 'BEGIN{exit !((v==1 && d<=0.001) || (v==0 && d>0.001))}'; then
  echo "ok   sbx: the box's printed fidelity claim ($SBX_BOX_VERIFIED of 1, deviation $SBX_BOX_DEV) is consistent with the measured deviation vs tolerance 0.001"
else
  echo "FAIL sbx: the box's fidelity line is inconsistent or unparseable: $SBX_BOX_LINE"; fail=1
fi
sbxcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); exact Brep-face cage (no tessellation), 12 sharp edge(s) creased (dihedral above 35 degrees), deviation measured at [1-9][0-9]* exact limit-surface points" "ToSubD on a 10x10x10 Brep box reports 1 of 1 verified from MEASURED limit-surface samples (not an unconditional claim), within 0.001, with 12 sharp edges creased"
# (2) crease count: the cage's 12 box edges are creases (was 0 creases).
sbxcheck "6 faces, 12 edges, 8 vertices, 12 creases" "the box's SubD cage has 12 creases (was 0)"
sbxcheck "Crease edges: 12" "What reports the box SubD's 12 crease edges"
# (3) the limit surface, converted to a NURBS solid, is a box again: volume 1000
# (measured 1000.0; asserted 995..1005 - tessellation-derived numbers differ
# slightly across platforms). With the old uncreased cage this was 327.1.
sbxcheck "closed solid: yes, manifold" "ToNURBS of the creased box SubD is a closed manifold solid"
SBX_VOL="$(grep -o "Volume = [0-9.e+-]*" <<<"$SBX_OUT" | head -n 1 | awk '{print $3}' || true)"
if [ -n "$SBX_VOL" ] && awk -v a="$SBX_VOL" 'BEGIN{exit !(a>995 && a<1005)}'; then echo "ok   sbx: ToNURBS of the converted 10x10x10 box encloses $SBX_VOL (true 1000, asserted 995..1005; the uncreased cage gave 327.1)"; else echo "FAIL sbx: ToNURBS volume of the converted box is '$SBX_VOL' (expected 995..1005)"; fail=1; fi
SBX_NVOL="$(grep -c "Volume = " <<<"$SBX_OUT" || true)"
if [ "$SBX_NVOL" = "1" ]; then echo "ok   sbx: exactly one Volume line was printed (the NURBS solid's)"; else echo "FAIL sbx: expected exactly one Volume line, got $SBX_NVOL"; fail=1; fi
# (4) negative control: a smooth shape keeps its existing tessellate-and-verify figure.
if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); cage interpolated onto the Brep surface (limit surface passes through every cage vertex: [0-9]* iteration(s), residual 0\.0000[0-9]*), 0 feature edge(s) creased" <<<"$SBX_SPH_LINE" && ! grep -q "exact Brep-face cage" <<<"$SBX_SPH_LINE"; then echo "ok   sbx: Sphere ToSubD still reports its tessellate-and-verify figure (1 of 1, 0.000x, 0 feature edges) and does not take the exact-cage path"; else echo "FAIL sbx: Sphere ToSubD line changed: $SBX_SPH_LINE"; fail=1; fi
sbxcheck "18240 faces, 27360 edges, 9122 vertices, 0 creases" "the Sphere SubD is still the 96 x 96 grid cage with 0 creases"

# ---------------------------------------------------------------------------
# Construction history persists in the .3dm (HPS_; hps_save_script.txt +
# hps_reopen_script.txt). Document::HistoryRecords() is written as the document
# user string "Dino8.HistoryMeta" (object uuids on disk, remapped to the fresh
# ids on Open), so after Save -> New -> Open, and in a brand-new process, moving a
# source object rebuilds its dependents automatically (no UpdateHistory).
# Phase 1 builds + saves three documents (History Off = negative control; root
# curve deleted before Save = dangling source; the real chain, whose saved ids
# are NOT 1,2,3.. because a throw-away box was deleted first) and reopens the
# chain in-process; phase 2 is a fresh process that opens the files. Volumes and
# bounding boxes come from measured Volume / BoundingBox output, compared with a
# tolerance (the Windows CI tessellates the mesh offset/boolean slightly
# differently).
# ---------------------------------------------------------------------------
HPS_DIR="$TMPW/hps"
mkdir -p "$HPS_DIR"
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_save_script.txt" > "$HPS_DIR/hps_save_script.txt"
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_reopen_script.txt" > "$HPS_DIR/hps_reopen_script.txt"
hps_run() {  # hps_run <script>: one app launch, output on stdout
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$1" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$1" 2>&1
  fi
}
HPS_S="$(hps_run "$HPS_DIR/hps_save_script.txt")" || { echo "$HPS_S"; echo "FAIL: hps save script exited non-zero"; exit 1; }
HPS_R="$(hps_run "$HPS_DIR/hps_reopen_script.txt")" || { echo "$HPS_R"; echo "FAIL: hps reopen script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$HPS_S" || { echo "$HPS_S"; echo "FAIL: hps save script produced no smoke line"; fail=1; }
grep -q "^smoke:" <<<"$HPS_R" || { echo "$HPS_R"; echo "FAIL: hps reopen script produced no smoke line"; fail=1; }
hps_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
# hps_vol <output> <n>: the n-th "Volume = X" value; hps_bb <output> <n>: the n-th bounding box as "x0,y0,z0,x1,y1,z1"
hps_vol() { { grep -oE 'Volume = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Volume = //'; }
hps_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
# hps_closev <a> <b> <tol> / hps_closebb <a-list> <b-list> <tol>: prints 1 when every number is within tol
hps_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
hps_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
hps_sh() { hps_ok "$(hps_closev "$(hps_vol "$1" "$2")" "$3" "$4")" "$5 (measured $(hps_vol "$1" "$2"), expected $3 +/- $4)"; }
hps_sb() { hps_ok "$(hps_closebb "$(hps_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(hps_bb "$1" "$2"), expected $3)"; }
hps_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
hps_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- phase 1: the building process (3 documents, then the chain reopened in-process)
hps_count "$HPS_S" "Saved $HPS_DIR/hps_" 3 "HPS_save: the three documents (History Off, deleted source, the chain) were written"
hps_has "$HPS_S" "History recording: off. 0 object(s) with live construction history" "HPS_off: built with History Off, nothing is recorded"
hps_has "$HPS_S" "History recording: on. 2 object(s) with live construction history" "HPS_del: extrude + offset recorded before the root curve was deleted"
hps_has "$HPS_S" "object 3: Extrude <- 2  [distance=10" "HPS_on: before Save the ids are shifted (the throw-away box took id 1): extrude 3 <- curve 2"
hps_has "$HPS_S" "object 2: Extrude <- 1  [distance=10" "HPS_on: after New + Open the same records are back with REMAPPED ids (extrude 2 <- curve 1)"
hps_has "$HPS_S" "object 7: BooleanIntersection <- 5,6  [operation=intersection]" "HPS_on: the two-source boolean record came back with both sources remapped (5,6) and its operation"
hps_count "$HPS_S" "History recording: on. 4 object(s) with live construction history:" 2 "HPS_on: the History report lists 4 records both before Save and after the in-process reopen"
# Volume order in phase 1: 1 off(1728) 2 del(1728) 3 on id4 before save(1728) 4 id8 before save(250), then after reopen 5 id3 after Move(1728) 6 id7 before(250) 7 id7 after Move(500)
hps_sh "$HPS_S" 3 1728 1 "HPS_on before Save: the offset solid (box 12^3) has the expected volume"
hps_sh "$HPS_S" 4 250 1 "HPS_on before Save: the boolean intersection volume"
hps_sb "$HPS_S" 1 "-1,-1,-1,11,11,11" 0.05 "HPS_on before Save: offset solid bounding box"
hps_sb "$HPS_S" 2 "-1,-1,-1,11,11,11" 0.05 "HPS_on after New + Open (before any edit): the SAME bounding box as before Save"
hps_sb "$HPS_S" 3 "4,-1,-1,16,11,11" 0.05 "HPS_on after reopen, curve moved +5 in X: the offset solid FOLLOWED (bbox moved with no UpdateHistory)"
hps_sh "$HPS_S" 5 1728 1 "HPS_on after reopen + Move: the rebuilt offset solid keeps its volume"
hps_sh "$HPS_S" 6 250 1 "HPS_on after reopen (before edit): boolean volume equals the value before Save"
hps_sh "$HPS_S" 7 500 2 "HPS_on after reopen, second source curve moved +5: the boolean rebuilt automatically (250 -> 500)"
hps_has "$HPS_S" "History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)" "HPS_on in-process reopen: automatic propagation line for the offset chain"
hps_has "$HPS_S" "History: source object(s) 4 changed - 2 dependent(s) re-evaluated (5,7)" "HPS_on in-process reopen: automatic propagation line for the boolean chain"

# --- phase 2: a FRESH process opens the files
hps_count "$HPS_R" "History recording: on. 4 object(s) with live construction history:" 1 "HPS_fresh: the records are read from the .3dm by a new process"
hps_has "$HPS_R" "object 5: Extrude <- 4  [distance=10" "HPS_fresh: remapped ids (second extrude 5 <- curve 4)"
hps_has "$HPS_R" "object 3: OffsetSrf <- 2  [distance=1, solid=no]" "HPS_fresh: numeric options survived (distance=1, solid=no)"
# Volumes in phase 2: 1 id3 before(1728) 2 after Scale 2x(5808) 3 after Undo(1728) 4 id7(250) 5 id7 after Move(500) 6 after Undo(250) 7 OFF(1728) 8 DEL before(1728) 9 DEL after UpdateHistory(1728)
hps_sb "$HPS_R" 1 "-1,-1,-1,11,11,11" 0.05 "HPS_fresh: opened offset solid bounding box"
hps_sb "$HPS_R" 2 "4,-1,-1,16,11,11" 0.05 "HPS_fresh: curve moved +5 in X, no UpdateHistory: the offset solid bounding box followed"
hps_sh "$HPS_R" 1 1728 1 "HPS_fresh: offset solid volume before any edit"
hps_sh "$HPS_R" 2 5808 6 "HPS_fresh: curve scaled 2x about (5,0,0): offset solid volume rebuilt (same value as the live-session test in history_auto_script.txt)"
hps_sh "$HPS_R" 3 1728 1 "HPS_fresh: Undo restores the offset solid (the rebuild is inside the edit's undo step)"
hps_sh "$HPS_R" 4 250 1 "HPS_fresh: boolean volume before the edit"
hps_sh "$HPS_R" 5 500 2 "HPS_fresh: second curve moved: the boolean rebuilt (250 -> 500)"
hps_sh "$HPS_R" 6 250 1 "HPS_fresh: Undo restores the boolean"
hps_count "$HPS_R" "History: source object(s)" 4 "HPS_fresh: exactly 4 automatic updates (Move, Scale, Move of the 2nd curve, and the Move after the SECOND Save/Open) - none for the controls"
hps_has "$HPS_R" "History: source object(s) 4 changed - 2 dependent(s) re-evaluated (5,7)" "HPS_fresh: boolean chain propagation line"
hps_sb "$HPS_R" 3 "4,4,-1,16,16,11" 0.05 "HPS_resave: records written from a LOADED document survive a second Save/New/Open (curve moved +5 in Y: bbox follows on top of the earlier +5 X)"
# negative control 1: saved with History Off
hps_has "$HPS_R" "History recording: on. 0 object(s) with live construction history" "HPS_off control: a document saved with History Off has no records to restore"
hps_sb "$HPS_R" 4 "-1,-1,-1,11,11,11" 0.05 "HPS_off control: the source curve was moved and NOTHING followed (bbox unchanged)"
hps_has "$HPS_R" "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry" "HPS_off control: UpdateHistory says it has nothing to re-evaluate"
hps_sb "$HPS_R" 5 "-1,-1,-1,11,11,11" 0.05 "HPS_off control: still unchanged after UpdateHistory"
hps_sh "$HPS_R" 7 1728 1 "HPS_off control: volume unchanged"
# negative control 2: the source curve was deleted before Save
hps_has "$HPS_R" "object 1: Extrude <- (deleted)" "HPS_del control: the extrude's record kept its slot but names its source as deleted"
hps_has "$HPS_R" "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry, 2 skipped" "HPS_del control: UpdateHistory re-evaluates nothing and reports 2 skipped"
hps_has "$HPS_R" "UpdateHistory: object 1 (Extrude) kept as it was: its source object was deleted before the file was saved" "HPS_del control: the reason is the deleted source"
hps_sb "$HPS_R" 6 "-1,-1,-1,11,11,11" 0.05 "HPS_del control: offset solid bounding box before UpdateHistory"
hps_sb "$HPS_R" 7 "-1,-1,-1,11,11,11" 0.05 "HPS_del control: ...and after UpdateHistory (geometry untouched)"
hps_sh "$HPS_R" 8 1728 1 "HPS_del control: volume before UpdateHistory"
hps_sh "$HPS_R" 9 1728 1 "HPS_del control: volume after UpdateHistory (unchanged)"

# --- part 3: Shell records history (hps_shell_script.txt). Plain Shell (closed solid,
# uniform thickness, no opened faces) hides its source and records {source,
# thickness}; the shell follows edits of the source, survives Save/New/Open and
# EditHistory thickness=..., and an opened-face Shell / History Off record nothing.
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_shell_script.txt" > "$HPS_DIR/hps_shell_script.txt"
HPS_H="$(hps_run "$HPS_DIR/hps_shell_script.txt")" || { echo "$HPS_H"; echo "FAIL: hps shell script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$HPS_H" || { echo "$HPS_H"; echo "FAIL: hps shell script produced no smoke line"; fail=1; }
# Volumes: 1 shell(1408) 2 source scaled 2x (6008) 3 after Undo(1408) 4 after reopen + EditHistory thickness=2 (2464)
#          5 curve->Extrude->Shell (1408) 6 same after the curve moved (1408) 7 History Off (1408) 8 opened-face Shell (1084)
# Bounding boxes: 1 shell (0..20) 2 source moved +5 X 3 reopened source moved +5 Y 4 extrude chain moved +7 X
hps_has "$HPS_H" "Shell: thickness 1, closed, exact B-rep, volume 1408" "HPS_shell: a plain Shell of a box still takes the exact B-rep path"
hps_has "$HPS_H" "object 2: Shell <- 1  [thickness=1]" "HPS_shell: with History On the Shell is recorded (source 1, thickness 1) and the source box is kept (hidden) not deleted"
hps_sh "$HPS_H" 1 1408 2 "HPS_shell: hollowed 20x20x10 box, wall 1 (4000 - 18*18*8)"
hps_sb "$HPS_H" 2 "5,0,0,25,20,10" 0.05 "HPS_shell: source box moved +5 in X, no UpdateHistory: the shell followed"
hps_sh "$HPS_H" 2 6008 6 "HPS_shell: source box scaled 2x: the shell was re-shelled with the same wall (40*40*20 - 38*38*18)"
hps_sh "$HPS_H" 3 1408 2 "HPS_shell: Undo restores the previous shell (the rebuild is in the edit's undo step)"
hps_has "$HPS_H" "History recording: on. 1 object(s) with live construction history:" "HPS_shell: the Shell record is read back from the .3dm after New + Open"
hps_sb "$HPS_H" 3 "5,5,0,25,25,10" 0.05 "HPS_shell: after Save/New/Open the shell follows its (reopened) source moved +5 in Y"
hps_has "$HPS_H" "EditHistory: object 2 (Shell): thickness 1 -> 2." "HPS_shell: EditHistory exposes and changes the recorded thickness"
hps_sh "$HPS_H" 4 2464 4 "HPS_shell: after EditHistory thickness=2 (4000 - 16*16*6)"
if grep -qF -- "Shell: object 2 - exact B-rep shell not used" <<<"$HPS_H"; then echo "FAIL HPS_shell: curve -> Extrude -> Shell fell back to the mesh construction (it is a right prism, so the exact prism shell must apply)"; fail=1; else echo "ok   HPS_shell: curve -> Extrude -> Shell no longer declines (the extruded rectangle is a right prism: exact B-rep shell, live and on rebuild)"; fi
hps_sh "$HPS_H" 5 1408 5 "HPS_shell: curve -> Extrude -> Shell (exact prism path) volume before the edit"
hps_sb "$HPS_H" 4 "7,0,0,27,20,10" 0.05 "HPS_shell: source curve moved +7 in X: Extrude AND Shell followed (2-deep chain)"
hps_has "$HPS_H" "History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)" "HPS_shell: the chain propagation line names both dependents"
hps_sh "$HPS_H" 6 1408 5 "HPS_shell: ...and the prism-path shell keeps its volume"
hps_has "$HPS_H" "History recording: off. 0 object(s) with live construction history" "HPS_shell control: Shell with History Off records nothing"
hps_sh "$HPS_H" 7 1408 2 "HPS_shell control: History Off Shell result unchanged from before"
hps_has "$HPS_H" "History recording: on. 0 object(s) with live construction history" "HPS_shell control: a Shell with an opened (clicked) face records nothing"
hps_sh "$HPS_H" 8 1084 2 "HPS_shell control: the opened-face Shell is the same exact open shell as before (volume 1084)"

# --- Tutorial video pipeline (tutorials/record.py, verify.py; docs/TUTORIALS.md).
# Records one real tutorial headless (the app's own ScreenCaptureToFile under
# Xvfb 1280x720, encoded with ffmpeg), then verifies the finished artifact from
# the files themselves: size, frame count, duration, resolution, non-blank
# frames (pixel variance, Python stdlib) and WebVTT validity/cue order.
# Skipped, loudly, where ffmpeg/ffprobe/python3 are missing or off Linux.
TUT_ID="04-extrude-revolve-vase"
TUT_OUT="$TMPW/tut_out"
if [ "$(uname -s)" = "Linux" ] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  TUT_SELF="$(python3 "$HERE/../tutorials/verify.py" --selftest 2>&1)" || true
  tut_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
  tut_has "$TUT_SELF" "TUT_selftest_flat_blank=1" "TUT_selftest: a flat frame is classified blank"
  tut_has "$TUT_SELF" "TUT_selftest_noisy_not_blank=1" "TUT_selftest: a textured frame is not blank"
  tut_has "$TUT_SELF" "TUT_selftest_good_vtt=1" "TUT_selftest: a valid WebVTT is accepted"
  tut_has "$TUT_SELF" "TUT_selftest_bad_order_rejected=1" "TUT_selftest: out-of-order cues are rejected"
  tut_has "$TUT_SELF" "TUT_selftest_no_header_rejected=1" "TUT_selftest: a file without the WEBVTT header is rejected"
  tut_has "$TUT_SELF" "TUT_selftest_too_long_rejected=1" "TUT_selftest: a cue running past the video end is rejected"
  TUT_REC="$(timeout 900 python3 "$HERE/../tutorials/record.py" --bin "$BIN" --id "$TUT_ID" --out "$TUT_OUT" 2>&1)" || { echo "$TUT_REC" | tail -20; echo "FAIL TUT_record: recorder exited non-zero"; fail=1; }
  tut_has "$TUT_REC" "record: $TUT_ID ->" "TUT_record: recorder reported the finished video"
  TUT_VER="$(python3 "$HERE/../tutorials/verify.py" "$TUT_OUT" "$TUT_ID" 2>&1)" || { echo "$TUT_VER" | tail -20; echo "FAIL TUT_verify: verifier crashed (no video produced?)"; fail=1; TUT_VER=""; }
  tut_val() { { grep "^$2=" <<<"$1" || true; } | head -1 | cut -d= -f2-; }
  TUT_BYTES="$(tut_val "$TUT_VER" TUT_video_bytes)"
  if [ -n "$TUT_BYTES" ] && [ "$TUT_BYTES" -gt 50000 ] && [ "$TUT_BYTES" -lt 40000000 ]; then echo "ok   TUT_size: video file is $TUT_BYTES bytes (plausible: 50 kB..40 MB)"; else echo "FAIL TUT_size: video file size '$TUT_BYTES' not in 50 kB..40 MB"; fail=1; fi
  TUT_PF="$(tut_val "$TUT_VER" TUT_probe_frames)"; TUT_EF="$(tut_val "$TUT_VER" TUT_expected_frames)"
  if [ -n "$TUT_PF" ] && [ "$TUT_PF" = "$TUT_EF" ]; then echo "ok   TUT_frames: decoded frame count $TUT_PF equals the count expected from tutorial.txt"; else echo "FAIL TUT_frames: decoded '$TUT_PF' != expected '$TUT_EF'"; fail=1; fi
  TUT_PD="$(tut_val "$TUT_VER" TUT_probe_duration)"; TUT_ED="$(tut_val "$TUT_VER" TUT_expected_duration)"
  if [ -n "$TUT_PD" ] && python3 -c "import sys; sys.exit(0 if abs(float('$TUT_PD')-float('$TUT_ED')) <= 0.2 else 1)"; then echo "ok   TUT_duration: container duration $TUT_PD s matches expected $TUT_ED s"; else echo "FAIL TUT_duration: '$TUT_PD' vs expected '$TUT_ED'"; fail=1; fi
  tut_has "$TUT_VER" "TUT_probe_size=1280x720" "TUT_size720: video is 1280x720"
  tut_has "$TUT_VER" "TUT_probe_fps=10/1" "TUT_fps: video is 10 fps"
  TUT_SAMP="$(tut_val "$TUT_VER" TUT_sampled_frames)"
  if [ -n "$TUT_SAMP" ] && [ "$TUT_SAMP" -ge 10 ]; then echo "ok   TUT_sample: $TUT_SAMP frames sampled for the variance check"; else echo "FAIL TUT_sample: only '$TUT_SAMP' frames could be sampled"; fail=1; fi
  tut_has "$TUT_VER" "TUT_blank_frames=0" "TUT_blank: no sampled frame is blank (luminance variance >= 4)"
  TUT_DIFF="$(tut_val "$TUT_VER" TUT_first_last_diff)"
  if [ -n "$TUT_DIFF" ] && python3 -c "import sys; sys.exit(0 if float('$TUT_DIFF') > 0.5 else 1)"; then echo "ok   TUT_progress: first and last sampled frames differ (mean abs diff $TUT_DIFF)"; else echo "FAIL TUT_progress: first and last frames are identical (diff '$TUT_DIFF')"; fail=1; fi
  tut_has "$TUT_VER" "TUT_vtt=ok" "TUT_vtt: captions are valid WebVTT with strictly increasing, non-overlapping cues inside the video"
  TUT_NC="$(tut_val "$TUT_VER" TUT_vtt_cues)"; TUT_XC="$(tut_val "$TUT_VER" TUT_expected_cues)"
  if [ -n "$TUT_NC" ] && [ "$TUT_NC" = "$TUT_XC" ] && [ "$TUT_NC" -ge 3 ]; then echo "ok   TUT_cues: $TUT_NC caption cues, one per #narrate: line"; else echo "FAIL TUT_cues: '$TUT_NC' cues vs expected '$TUT_XC'"; fail=1; fi
  TUT_TXT="$TUT_OUT/$TUT_ID/$TUT_ID.txt"
  if [ -s "$TUT_TXT" ]; then echo "ok   TUT_transcript: voice-over transcript written"; else echo "FAIL TUT_transcript: $TUT_TXT missing or empty"; fail=1; fi
  # The generated site lists every tutorial and is self-contained (no CDN/tracker).
  TUT_SITE_OUT="$(python3 "$HERE/../tutorials/build_site.py" 2>&1)" || { echo "$TUT_SITE_OUT"; echo "FAIL TUT_site: build_site.py failed"; fail=1; }
  tut_has "$TUT_SITE_OUT" "(10 tutorials)" "TUT_site: index.html built for all 10 tutorials"
  if [ -z "$({ grep -E 'src="https?://|href="https?://|<script' "$HERE/../tutorials/index.html" || true; })" ]; then echo "ok   TUT_site_selfcontained: index.html has no external URLs and no scripts"; else echo "FAIL TUT_site_selfcontained: index.html references an external URL or script"; fail=1; fi
else
  echo "skip TUT_*: tutorial pipeline checks need Linux with ffmpeg, ffprobe and python3 (see docs/TUTORIALS.md)"
fi

# ---------------------------------------------------------------------------
# Third-party plug-in ecosystem (docs/PLUGIN_GUIDE.md, docs/COMMUNITY.md):
#  * psdk_*  - tests/plugin_sdk_test.sh installs the SDK (plugin-sdk/) to a temp
#    prefix, generates each plugin-templates/ template into a clean directory,
#    builds it against that prefix ALONE, loads the built plug-ins into this very
#    $BIN headless and checks each plug-in's command ran; also the ABI
#    compatibility rule, a package + localhost-HTTP marketplace round trip with
#    sha256 refusal, and DigitalSign/VerifySignature on a manifest.
#  * psite_* - tests/plugin_site_test.sh renders the plug-in index with
#    tools/site/build_site.py and checks no external requests, escaping of
#    hostile index data, parity with the app's own index parser, and that the
#    app loads the plugin-index.json the site publishes.
# The helpers print "ok   <name>" / "FAIL <name>"; the lists below make sure a
# helper that silently skipped a check cannot pass. Skipped on Windows runners
# (the helpers drive cmake/python3/bash job control, validated on Linux/macOS).
PSDK_REQUIRED="psdk_sdk_install psdk_sdk_header_identical psdk_find_package_ok psdk_find_package_too_new psdk_cmd_builds psdk_xyz_builds psdk_rep_builds psdk_templates_self_contained psdk_templates_rendered psdk_template_needs_sdk psdk_cmd_loaded psdk_xyz_loaded psdk_rep_loaded psdk_cmd_ran psdk_xyz_export_ran psdk_xyz_export_file psdk_xyz_import_ran psdk_rep_ran psdk_rep_total psdk_app_objects psdk_abi_newer_declined psdk_abi_newer_message psdk_abi_older_loads psdk_abi_older_ran psdk_package_layout psdk_market_index psdk_market_sha_refused psdk_market_install psdk_market_ran psdk_market_verify psdk_sign_verify psdk_sign_sidecar psdk_sign_tamper"
PSITE_REQUIRED="psite_renders_index psite_index_verbatim psite_install_instructions psite_community_link psite_no_external_requests psite_one_local_script psite_csp psite_no_tracker psite_app_reads_site_index psite_escapes_script psite_escapes_markup psite_no_javascript_url psite_rejects_schema2 psite_rejects_both psite_app_parity_schema psite_app_parity_both psite_stricter_trav psite_stricter_badsha psite_placeholder_entry_refused psite_packaged_entry_accepted psite_warns_missing_sha psite_github_forms"
if [ "$IS_WINDOWS" = 1 ]; then
  echo "skip psdk_*/psite_* (Windows runner: plug-in SDK and site helpers run on Linux/macOS)"
elif ! command -v cmake >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "skip psdk_*/psite_* (cmake or python3 not installed)"
else
  PSDK="$(timeout 900 bash "$HERE/plugin_sdk_test.sh" "$BIN" 2>&1)" || { echo "$PSDK" | tail -40; echo "FAIL: plugin_sdk_test.sh exited non-zero"; fail=1; }
  echo "$PSDK" | grep -E "^(ok|FAIL|skip)" || true
  if grep -q "^FAIL" <<<"$PSDK"; then fail=1; fi
  if grep -q "^skip psdk_market" <<<"$PSDK"; then
    PSDK_REQUIRED="$(sed -E 's/ psdk_(package_layout|market_[a-z_]+)//g' <<<"$PSDK_REQUIRED")"
  fi
  for n in $PSDK_REQUIRED; do
    if ! grep -q "^ok   $n[: ]" <<<"$PSDK"; then echo "FAIL $n did not report ok (check missing or helper skipped it)"; fail=1; fi
  done
  PSITE="$(timeout 900 bash "$HERE/plugin_site_test.sh" "$BIN" 2>&1)" || { echo "$PSITE" | tail -40; echo "FAIL: plugin_site_test.sh exited non-zero"; fail=1; }
  echo "$PSITE" | grep -E "^(ok|FAIL|skip)" || true
  if grep -q "^FAIL" <<<"$PSITE"; then fail=1; fi
  for n in $PSITE_REQUIRED; do
    if ! grep -q "^ok   $n[: ]" <<<"$PSITE"; then echo "FAIL $n did not report ok (check missing or helper skipped it)"; fail=1; fi
  done
  # Touch support of the exported web viewer (src/io/WebViewer.cpp): markers in
  # the real exported HTML, plus - where node + Playwright + Chromium exist - real
  # touch input (one-finger orbit, two-finger pinch) via tests/web_viewer_touch_check.js.
  PWV="$(timeout 900 bash "$HERE/web_viewer_touch_test.sh" "$BIN" 2>&1)" || { echo "$PWV" | tail -30; echo "FAIL: web_viewer_touch_test.sh exited non-zero"; fail=1; }
  echo "$PWV" | grep -E "^(ok|FAIL|skip)" || true
  if grep -q "^FAIL" <<<"$PWV"; then fail=1; fi
  for n in pwv_export pwv_viewport_meta pwv_touch_action pwv_pointer_events pwv_coarse_ui pwv_no_mouse_only pwv_self_contained; do
    if ! grep -q "^ok   $n[: ]" <<<"$PWV"; then echo "FAIL $n did not report ok"; fail=1; fi
  done
fi

# ---------------------------------------------------------------------------
# Dino 8 Touch (touch/, the PWA companion app) + its /touch/ and /touch/api/
# server routes (src/net/TouchApi.cpp). touch/tests/touch_gestures.test.js
# starts this very binary headless with --serve --serve-touch under its own
# xvfb-run, loads the PWA in touch-emulating Chromium (Playwright), drives it
# with synthetic CDP touch events and asserts measured camera changes (orbit
# angle, pan distance, pinch ratio), long-press selection, a three-finger
# undo and a typed command read back through the server, that unauthenticated
# requests are refused, and that the service worker loads the app with the
# network blocked. Skipped with a clear line when node, the playwright
# package or xvfb-run is missing (it is not a hard dependency of the app).
TCH_TEST="$HERE/../touch/tests/touch_gestures.test.js"
if ! command -v node >/dev/null 2>&1; then
  echo "skip TCH_ Dino 8 Touch PWA test (node is not installed)"
elif ! node -e "require('playwright')" >/dev/null 2>&1; then
  echo "skip TCH_ Dino 8 Touch PWA test (the node 'playwright' package is not installed)"
elif ! command -v xvfb-run >/dev/null 2>&1; then
  echo "skip TCH_ Dino 8 Touch PWA test (xvfb-run is not installed)"
elif [ ! -f "$TCH_TEST" ]; then
  echo "skip TCH_ Dino 8 Touch PWA test ($TCH_TEST not found)"
else
  TCH_RC=0
  TCH_OUT="$(timeout 900 node "$TCH_TEST" "$BIN" 2>&1)" || TCH_RC=$?
  TCH_OK="$(grep -c '^ok ' <<<"$TCH_OUT" || true)"
  TCH_BAD="$(grep -c '^FAIL' <<<"$TCH_OUT" || true)"
  if [ "$TCH_RC" -eq 0 ] && grep -q '^all passed' <<<"$TCH_OUT"; then
    echo "ok   TCH_touch: Dino 8 Touch PWA test passed ($TCH_OK checks: gestures, auth refusal, command round trip, offline service worker)"
  else
    echo "$TCH_OUT"
    echo "FAIL TCH_touch: Dino 8 Touch PWA test exited $TCH_RC ($TCH_OK ok, $TCH_BAD failed)"
    fail=1
  fi
fi

# ---------------------------------------------------------------------------
# S1S_: Sweep1 with SEVERAL cross-sections -> the kernel's exact
# Brep::Sweep1Sections (Sweep1Command::Build, cmd_surface.cpp), driven by
# sweep1_sections_script.txt: (A) two circles on a straight rail = a cone
# frustum, (B) circle / rectangle / circle, (C) three circles on a curved rail,
# then two refusals that must print their reason and fall back to the old
# sampled sweep: (D) a section plane the rail never reaches, (E) a closed rail.
# Everything is MEASURED from the app's own output: the kernel's printed
# deviations, the surface's closest-point distance to points ON each section
# (ClosestPt), the display-mesh Area and BoundingBox, each against a tolerance
# range (the mesh-derived figures tessellate slightly differently on Windows).
# Output checks use here-strings (no echo | grep).
# ---------------------------------------------------------------------------
s1s_ok() { echo "ok   $1"; }
s1s_bad() { echo "FAIL $1"; fail=1; }
S1S_CMD=(timeout 900 "$BIN" --smoke 30 --script "$HERE/sweep1_sections_script.txt")
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  S1S="$("${S1S_CMD[@]}" 2>&1)" || { echo "$S1S" | tail -40; echo "FAIL S1S_run: sweep1 sections script exited non-zero"; fail=1; S1S=""; }
else
  S1S="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/sweep1_sections_script.txt" 2>&1)" || { echo "$S1S" | tail -40; echo "FAIL S1S_run: sweep1 sections script exited non-zero"; fail=1; S1S=""; }
fi
if grep -q "^FAIL" <<<"$S1S"; then s1s_bad "S1S_script: an @expect line of the script failed"; else s1s_ok "S1S_script: every @expect_objects line of the script held"; fi
# The output of the n-th Sweep1 command (up to the next one).
s1s_case() { awk -v n="$1" '/Command: Sweep1$/ { c++ } c == n' <<<"$S1S"; }
# All "distance X" values of the ClosestPt lines of a case must be below 1e-6; $2 = how many there must be.
s1s_dists() {
  local d n
  d="$(grep -o "Closest point [^ ]* distance [0-9.e+-]*" <<<"$1" | awk '{print $NF}' || true)"
  n="$(grep -c . <<<"$d" || true)"
  if [ "$n" = "$2" ] && awk '{ if ($1 + 0 >= 1e-6) bad = 1 } END { exit bad }' <<<"$d"; then
    s1s_ok "$3 (all $2 points on the input sections are within 1e-6 of the surface; got: $(echo $d))"
  else
    s1s_bad "$3 (expected $2 distances below 1e-6, got $n: $(echo $d))"
  fi
}
# The kernel's printed accuracy: sections reproduced below $2, between-station deviation below $3.
s1s_acc() {
  local line
  line="$(grep -o "sections reproduced to [0-9.e+-]*, between stations within [0-9.e+-]*" <<<"$1" | head -1 || true)"
  if [ -n "$line" ] && awk -v a="$2" -v b="$3" '{ exit !($4 + 0 < a && $8 + 0 <= b) }' <<<"$line"; then
    s1s_ok "$4 ($line)"
  else
    s1s_bad "$4 (accuracy line missing or out of bounds: '$line')"
  fi
}
# BoundingBox of the case: $2 = "x0lo x0hi y0lo y0hi z0lo z0hi x1lo x1hi y1lo y1hi z1lo z1hi" (min then max corner ranges).
s1s_bbox() {
  local line
  line="$(grep -o "Bounding box min [^ ]* max [^ ]*" <<<"$1" | head -1 || true)"
  if [ -n "$line" ] && awk -v r="$2" '{ split($4, a, ","); split($6, b, ","); split(r, q, " ");
        ok = (a[1] >= q[1] && a[1] <= q[2] && a[2] >= q[3] && a[2] <= q[4] && a[3] >= q[5] && a[3] <= q[6] &&
              b[1] >= q[7] && b[1] <= q[8] && b[2] >= q[9] && b[2] <= q[10] && b[3] >= q[11] && b[3] <= q[12]); exit !ok }' <<<"$line"; then
    s1s_ok "$3 ($line)"
  else
    s1s_bad "$3 (box '$line' outside the expected ranges $2)"
  fi
}
S1S_A="$(s1s_case 1)"; S1S_B="$(s1s_case 2)"; S1S_C="$(s1s_case 3)"; S1S_D="$(s1s_case 4)"; S1S_E="$(s1s_case 5)"
# (A) cone frustum r = 2 -> 1 over z = 0..10
if grep -q "Sweep1: exact kernel multi-section sweep (2 sections, " <<<"$S1S_A"; then s1s_ok "S1S_A_kernel: two circles reach the kernel's Brep::Sweep1Sections"; else s1s_bad "S1S_A_kernel: two circles did not reach Brep::Sweep1Sections"; fi
s1s_acc "$S1S_A" 1e-9 1e-9 "S1S_A_accuracy: frustum sections reproduced below 1e-9 and the wall equals the blend between stations (a straight rail with equal weights)"
s1s_dists "$S1S_A" 5 "S1S_A_passthrough"
A_AREA="$(grep -o "Area = [0-9.e+-]*" <<<"$S1S_A" | head -1 | awk '{print $3}' || true)"
if [ -n "$A_AREA" ] && awk -v v="$A_AREA" 'BEGIN { exit !(v > 94.2 && v < 95.2) }'; then s1s_ok "S1S_A_area: surface area $A_AREA matches the frustum's lateral area pi (r0 + r1) sqrt(h^2 + (r0 - r1)^2) = 94.72 to the display mesh's 0.5"; else s1s_bad "S1S_A_area: area '$A_AREA' is not near 94.72"; fi
s1s_bbox "$S1S_A" "-2.05 -1.9 -2.05 -1.9 -0.01 0.01 1.9 2.05 1.9 2.05 9.99 10.01" "S1S_A_bbox: box is the r = 2 base circle's x/y extent and z = 0..10"
# (B) circle -> rectangle -> circle
if grep -q "Sweep1: exact kernel multi-section sweep (3 sections, " <<<"$S1S_B"; then s1s_ok "S1S_B_kernel: circle / rectangle / circle reach the kernel's Brep::Sweep1Sections"; else s1s_bad "S1S_B_kernel: circle / rectangle / circle did not reach Brep::Sweep1Sections"; fi
s1s_acc "$S1S_B" 1e-9 1e-3 "S1S_B_accuracy: sections reproduced below 1e-9 and the between-station deviation within the document tolerance 0.001 (the command retries with more stations until it is)"
s1s_dists "$S1S_B" 5 "S1S_B_passthrough"
s1s_bbox "$S1S_B" "-3.05 -2.9 -2.05 -1.9 -0.01 0.01 2.9 3.05 1.9 2.05 9.99 10.01" "S1S_B_bbox: box is the 6 x 3 rectangle's x extent (3), the r = 2 base circle's y extent and z = 0..10"
# (C) three circles on the curved rail
if grep -q "Sweep1: exact kernel multi-section sweep (3 sections, " <<<"$S1S_C"; then s1s_ok "S1S_C_kernel: three circles on a curved rail reach the kernel's Brep::Sweep1Sections"; else s1s_bad "S1S_C_kernel: curved-rail sweep did not reach Brep::Sweep1Sections"; fi
s1s_acc "$S1S_C" 1e-9 1e-3 "S1S_C_accuracy: sections reproduced below 1e-9, between-station deviation within the document tolerance"
s1s_dists "$S1S_C" 4 "S1S_C_passthrough"
s1s_bbox "$S1S_C" "-1.6 -1.4 -2.05 -1.9 -0.01 0.01 3.9 4.4 1.9 2.05 9.99 10.01" "S1S_C_bbox: box spans the curved sweep (x from the first circle's -1.5 to about 4.15 past the last circle's x = 3 + 1, y +-2 from the middle circle, z = 0..10)"
# (D) a plane the rail never reaches; (E) a closed rail: reason printed, old sampled sweep still builds
if grep -q "Sweep1: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep1Sections: the rail never crosses the plane of section 2" <<<"$S1S_D" && grep -q "Sweep1: 2 section(s) along 2 rail stations" <<<"$S1S_D"; then s1s_ok "S1S_D_refusal: a section plane the rail never reaches is refused with that reason and the old sampled sweep builds"; else s1s_bad "S1S_D_refusal: refusal text or fallback line missing"; fi
if grep -q "Sweep1: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep1Sections: a closed rail is not supported" <<<"$S1S_E" && grep -q "Sweep1: 2 section(s) along " <<<"$S1S_E"; then s1s_ok "S1S_E_refusal: a closed rail is refused with that reason and the old sampled sweep builds"; else s1s_bad "S1S_E_refusal: refusal text or fallback line missing"; fi
S1S_N="$(grep -c "exact kernel multi-section sweep" <<<"$S1S" || true)"
if [ "$S1S_N" = "3" ]; then s1s_ok "S1S_count: exactly the three well-formed multi-section sweeps reached the kernel"; else s1s_bad "S1S_count: $S1S_N multi-section sweeps reached the kernel, expected 3"; fi

# B2S_: sequential exact Booleans (b2s_script.txt). A second hole cut in the result of a first exact
# Boolean, and box + sphere (also with a second sphere), stay exact B-rep: every accepted exact result
# is a closed solid (IsSolid, Check() clean at the sewing step) whose display-mesh volume is within the
# stated range of the analytic value, and a case the engine cannot do is declined WITH a reason (never an
# open or wrong solid). Volumes are read from the display mesh (chord 0.05% of the diagonal), so the
# ranges carry that tessellation error (measured ~0.1% here; the Windows CI tessellates slightly
# differently, hence the +-0.5% windows).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  B2SOUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/b2s_script.txt" 2>&1)" || { echo "$B2SOUT"; echo "FAIL b2s_script exited non-zero"; exit 1; }
else
  B2SOUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/b2s_script.txt" 2>&1)" || { echo "$B2SOUT"; echo "FAIL b2s_script exited non-zero"; exit 1; }
fi
b2s_block() { awk -v name="$1" '$0 ~ ("Unknown command: B2SBEGIN_" name "$") { on = 1; next } on && /Unknown command: B2SBEGIN_|Unknown command: B2SEND/ { exit } on { print }' <<<"$B2SOUT"; }
b2s_check() {
  local blk; blk="$(b2s_block "$1")"
  if grep -q -- "$2" <<<"$blk"; then echo "ok   b2s_$1: $3"; else
    echo "FAIL b2s_$1: $3"; echo "     expected: $2"
    { grep -E "^history: (Boolean|Shell|Object|  [0-9]|Volume|Area|!)" <<<"$blk" || true; } | head -8 | sed 's/^/     actual:   /'
    fail=1
  fi
}
# b2s_num NAME KEY MIN MAX DESC: the case's last "KEY = V" (Volume / Area) must lie in [MIN, MAX]
b2s_num() {
  local blk v; blk="$(b2s_block "$1")"
  v="$({ grep -E "^history: $2 = " <<<"$blk" || true; } | tail -1 | sed -E "s/^history: $2 = ([0-9.eE+-]+).*/\\1/")"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   b2s_$1: $5 ($2 $v in [$3, $4])"; else echo "FAIL b2s_$1: $5 ($2 '${v:-none}' not in [$3, $4])"; fail=1; fi
}
# --- second sequential hole: exact, re-evaluated from the recorded operands
b2s_check chain2 "exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "first hole is exact and closed"
b2s_check chain2 "exact B-rep boolean (no tessellation, general engine), 8 face(s), re-evaluated from the recorded original operands (the base and 2 tool(s) in one pass" "second sequential hole is exact (before: declined, mesh)"
b2s_check chain2 "(polysurface)" "...result is a polysurface, not a mesh"
b2s_check chain2 "8 faces, [0-9]* edges, closed solid" "...8 faces (6 box + 2 hole walls), closed solid"
b2s_check chain2 "mesh cross-check" "...with its independent mesh-boolean cross-check volume printed"
b2s_num chain2 Volume 855.5 861.7 "two holes r1.5 in a 10-cube: 1000 - 2*pi*1.5^2*10 = 858.62"
b2s_num chain2 Area 755 765 "area = 400 + 2*(100-2*pi*1.5^2) + 2*(2*pi*1.5*10) = 760.2"
b2s_check chain3 "(the base and 3 tool(s) in one pass" "third sequential hole is exact too"
b2s_check chain3 "9 faces, [0-9]* edges, closed solid" "...9 faces, closed solid"
b2s_num chain3 Volume 861 868 "three holes r1.2: 1000 - 3*pi*1.44*10 = 864.28"
# --- a moved intermediate result must NOT use the recorded operands: declined with the engine's reason, mesh volume right
b2s_check moved "exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a MOVED first result is not re-evaluated from its recorded operands: declined WITH the reason"
b2s_check moved "(mesh)" "...and the fallback is a mesh"
b2s_num moved Volume 855.5 861.7 "...whose volume is still 1000 - 2*pi*1.5^2*10 = 858.62"
# --- box + sphere
b2s_check box_sphere "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "box + sphere is exact (before: declined, mesh)"
b2s_check box_sphere "7 faces, [0-9]* edges, closed solid" "...7 faces (5 box + box top with the circle removed + hemisphere), closed solid"
b2s_num box_sphere Volume 1130 1136 "box + upper hemisphere: 1000 + 2/3*pi*64 = 1134.04"
b2s_num box_sphere Area 646 655 "area = 600 - pi*16 + 2*pi*16 = 650.27"
b2s_check box_sphere_shell "Shell: thickness 0.5, closed, volume" "a Shell takes the box + sphere result as a closed solid (mesh construction: a curved face has no exact kernel shell)"
b2s_check box_sphere_sphere "re-evaluated from the recorded original operands" "box + sphere, then + a second sphere: exact"
b2s_check box_sphere_sphere "8 faces, [0-9]* edges, closed solid" "...8 faces, closed solid"
b2s_num box_sphere_sphere Volume 1264 1272 "1000 + 2*(2/3*pi*64) = 1268.08"
b2s_check box_two_spheres "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sewn into a closed solid" "box + two spheres in one Boolean is exact (the left-to-right fold fails; the retry unites the spheres first)"
b2s_num box_two_spheres Volume 1264 1272 "1000 + 2*(2/3*pi*64) = 1268.08"
# --- still declined, honestly: a different operation on the box + sphere result
b2s_check sphere_then_hole "BooleanDifference: exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a hole drilled in the box + sphere result (Difference after a Union) is declined WITH the reason"
b2s_check sphere_then_hole "(mesh)" "...mesh fallback"
b2s_num sphere_then_hole Volume 1098 1106 "...with the right volume 1134.04 - pi*10 = 1102.6"
# --- other sphere placements: declined honestly, with the reason; the mesh fallback has the right volume
b2s_check sph_cap "BooleanUnion: exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a sphere poking out of the top as a cap is declined WITH the reason"
b2s_check sph_cap "(mesh)" "...mesh fallback"
b2s_num sph_cap Volume 1038 1046 "...with the right volume 1000 + pi*4*(12-2)/3 = 1041.89"
b2s_check sph_side "BooleanUnion: exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a sphere centred on a side face is declined WITH the reason"
b2s_num sph_side Volume 1052 1060 "...with the right volume 1000 + 2/3*pi*27 = 1056.55"


# History / associative re-execution, round 2 (H2R_): FilletEdge, ChamferEdge, Cap,
# BlendSrf and Project/Pull record construction history (tests/h2r_edge_script.txt,
# h2r_cap_script.txt, h2r_blend_script.txt, h2r_proj_script.txt).
# FilletEdge/ChamferEdge on a solid: with History On the solid is hidden (kept as the
# recorded source) and the exact result is a new object that records the radius or
# distances and, per edge, a geometric signature (direction, both face normals, position
# relative to the solid's bounding box); editing the source re-finds each edge by that
# signature on the edited solid and re-runs the exact kernel fillet/chamfer. Every
# number below is a measured Volume or Bounding box, compared with the SAME operation
# performed fresh (History Off) on the moved/scaled source; negative controls: History
# Off records nothing, a rotated source is still followed (edge re-found by its position
# in the edge list, dihedral angle and relative length), a source chamfered on the very
# edge that was filleted makes the rebuild refuse with the reason and keep the old result,
# Rho fillet / angle chamfer / a Project that splits into pieces / a Cap of a closed solid
# record nothing.
# Tolerances: tessellation-derived values (volume, blend bounding boxes) are compared
# with ranges, as the Windows CI tessellates slightly differently.
# ---------------------------------------------------------------------------
H2R_DIR="$TMPW/h2r"
mkdir -p "$H2R_DIR"
h2r_run() {  # h2r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H2R_DIR|g" "$HERE/h2r_$1_script.txt" > "$H2R_DIR/h2r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H2R_DIR/h2r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H2R_DIR/h2r_$1_script.txt" 2>&1
  fi
}
h2r_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
h2r_vol() { { grep -oE 'Volume = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Volume = //'; }
h2r_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
h2r_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
h2r_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
h2r_sh() { h2r_ok "$(h2r_closev "$(h2r_vol "$1" "$2")" "$3" "$4")" "$5 (measured $(h2r_vol "$1" "$2"), expected $3 +/- $4)"; }
h2r_sb() { h2r_ok "$(h2r_closebb "$(h2r_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(h2r_bb "$1" "$2"), expected $3)"; }
h2r_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
h2r_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }
h2r_countre() { local n; n="$(grep -cE -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- FilletEdge / ChamferEdge (h2r_edge_script.txt)
H2R_E="$(h2r_run edge)" || { echo "$H2R_E"; echo "FAIL: h2r edge script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_E" || { echo "$H2R_E"; echo "FAIL: h2r edge script produced no smoke line"; fail=1; }
# Volumes: 1 fillet r2 (991.4) 2 source moved +5 X 3 source scaled 2x (7983) 4 after Undo 5 EditHistory radius=3 (980.6) 6 reopened source moved +5 Y
#   7 two chamfers of 3 (910) 8 source moved 9 source scaled 2x (7820) 10 EditHistory distance=2 (7920) 11 asymmetric chamfer 2/4 (960) 12 source moved +3 Z
#   13 EditHistory distance2=1 (990) 14 History Off fillet 15 ...after Move 16 source rotated 30 degrees: followed 17 source chamfered on the recorded edge: old result kept
#   18-21 fresh controls (7983, 7820, 980.6, rotated 991.4)
# Bounding boxes: 1 fillet 2 moved +5 X 3 reopened source moved +5 X then +5 Y 4 chamfered box moved +7 X 5 rotated source 6 fresh rotated control
h2r_has "$H2R_E" "FilletEdge: edge 10 of object 1 replaced with an exact fillet (radius 2); History is On: the original solid 1 is kept hidden as the source and the result is object 2" "H2R_fillet: with History On the exact fillet hides its source (kept, not edited in place) and the result is a new object"
h2r_has "$H2R_E" "object 2: FilletEdge <- 1  [radius=2]" "H2R_fillet: the record names the source solid and the radius"
h2r_sh "$H2R_E" 1 991.4 0.3 "H2R_fillet: box 10^3, fillet radius 2 (1000 - (1-pi/4)*2^2*10)"
h2r_sb "$H2R_E" 1 "0,0,0,10,10,10" 0.05 "H2R_fillet: result bounding box"
h2r_sh "$H2R_E" 2 991.4 0.3 "H2R_fillet: source moved +5 in X, no UpdateHistory: the fillet followed (same volume)"
h2r_sb "$H2R_E" 2 "5,0,0,15,10,10" 0.05 "H2R_fillet: ...and its bounding box moved with the source"
h2r_has "$H2R_E" "FilletEdge: edge 1 re-found as edge 10 of the source (direction and both face normals match)" "H2R_fillet: the recorded edge was re-found on the edited source and the rebuild says so"
h2r_has "$H2R_E" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (2)" "H2R_fillet: automatic propagation line names the dependent"
h2r_sh "$H2R_E" 3 7983 3 "H2R_fillet: source scaled 2x about (5,0,0): the same edge re-found, radius kept (8000 - (1-pi/4)*2^2*20)"
h2r_sh "$H2R_E" 18 "$(h2r_vol "$H2R_E" 3)" 3 "H2R_fillet control: the same fillet performed fresh (History Off) on a 20^3 box at x 5..25 has the same volume as the rebuilt one"
h2r_sh "$H2R_E" 18 7983 3 "H2R_fillet control: fresh volume itself, measured"
h2r_sh "$H2R_E" 4 991.4 0.3 "H2R_fillet: Undo restores the previous result (the rebuild is inside the edit's undo step)"
h2r_has "$H2R_E" "EditHistory: object 2 (FilletEdge): radius 2 -> 3." "H2R_fillet: EditHistory exposes and changes the recorded radius"
h2r_sh "$H2R_E" 5 980.6 0.3 "H2R_fillet: after EditHistory radius=3 (1000 - (1-pi/4)*3^2*10)"
h2r_has "$H2R_E" "object 2: FilletEdge <- 1  [radius=3]" "H2R_fillet: after Save/New/Open the record (with its edge signature) is read back from the .3dm"
h2r_sh "$H2R_E" 6 980.6 0.3 "H2R_fillet: reopened, source moved +5 in Y: the fillet followed with its radius"
h2r_sb "$H2R_E" 3 "5,5,0,15,15,10" 0.05 "H2R_fillet: reopened source moved: bounding box followed"
h2r_sh "$H2R_E" 20 "$(h2r_vol "$H2R_E" 6)" 0.3 "H2R_fillet control: the same radius-3 fillet performed fresh on the moved box has the same volume"
h2r_has "$H2R_E" "ChamferEdge: edge 6 of object 2 replaced with an exact chamfer (radius 3); recorded in the history of object 2 (now 2 step(s))" "H2R_chamfer: a second pick in the same run extends the record of the first result instead of chaining"
h2r_has "$H2R_E" "object 2: ChamferEdge <- 1  [distance=3, distance2=3]" "H2R_chamfer: one record, source 1, both distances"
h2r_sh "$H2R_E" 7 910 0.5 "H2R_chamfer: two chamfers of 3 on a 10^3 box (1000 - 2*3*3/2*10)"
h2r_sh "$H2R_E" 8 910 0.5 "H2R_chamfer: source moved +7 in X: both chamfers followed"
h2r_sb "$H2R_E" 4 "7,0,0,17,10,10" 0.05 "H2R_chamfer: ...bounding box moved with the source"
h2r_has "$H2R_E" "ChamferEdge: edge 2 re-found as edge 6 of the source (direction and both face normals match)" "H2R_chamfer: the second step's edge is re-found as well"
h2r_sh "$H2R_E" 9 7820 3 "H2R_chamfer: source scaled 2x about (7,0,0): 20^3 box with two chamfers of 3 (8000 - 2*4.5*20)"
h2r_sh "$H2R_E" 19 7820 3 "H2R_chamfer control: the same two chamfers performed fresh on a 20^3 box at x 7..27"
h2r_has "$H2R_E" "EditHistory: object 2 (ChamferEdge): distance 3 -> 2." "H2R_chamfer: EditHistory changes the distance"
h2r_sh "$H2R_E" 10 7920 3 "H2R_chamfer: after EditHistory distance=2 both chamfers are rebuilt (8000 - 2*2*20)"
h2r_has "$H2R_E" "ChamferEdge: edge 10 of object 1 replaced with an exact chamfer (distance1 2, distance2 4); History is On" "H2R_chamfer: an asymmetric chamfer records too"
h2r_has "$H2R_E" "object 2: ChamferEdge <- 1  [distance=2, distance2=4]" "H2R_chamfer: both distances are in the record"
h2r_sh "$H2R_E" 11 960 0.5 "H2R_chamfer: distances 2 and 4 on a 10^3 box (1000 - 2*4/2*10)"
h2r_sh "$H2R_E" 12 960 0.5 "H2R_chamfer: source moved +3 in Z: unchanged volume"
h2r_has "$H2R_E" "EditHistory: object 2 (ChamferEdge): distance2 4 -> 1." "H2R_chamfer: EditHistory changes distance2"
h2r_sh "$H2R_E" 13 990 0.5 "H2R_chamfer: after distance2=1 (1000 - 2*1/2*10)"
# negative controls
h2r_countre "$H2R_E" 'exact fillet \(radius 2\)$' 3 "H2R_off control: with History Off (the N1 box and the fresh X1 and X4 controls) the fillet message carries no history note (edited in place, nothing hidden)"
h2r_has "$H2R_E" "History recording: off. 0 object(s) with live construction history" "H2R_off control: History Off records nothing"
h2r_sh "$H2R_E" 14 991.4 0.3 "H2R_off control: the in-place fillet of the original box has the same volume"
h2r_sh "$H2R_E" 15 991.4 0.3 "H2R_off control: moving the filleted box changes nothing else"
h2r_has "$H2R_E" "FilletEdge: edge 1 re-found as edge 10 of the source (the solid was re-oriented: same position in its edge list, same dihedral angle and relative length)" "H2R_rotate: a source rotated 30 degrees about Z has no edge with the recorded direction/normals; the solid kept its topology, so the edge is re-found by its position in the edge list, dihedral angle and relative length, and the rebuild says so"
h2r_sh "$H2R_E" 16 991.4 0.3 "H2R_rotate: the rebuilt fillet on the rotated source has the same volume"
h2r_sb "$H2R_E" 5 "-1.83,-1.83,0,11.83,11.1,10" 0.05 "H2R_rotate: ...and the bounding box of a rotated, filleted box"
h2r_sb "$H2R_E" 6 "-1.83,-1.83,0,11.83,11.1,10" 0.05 "H2R_rotate control: the same fillet performed fresh on the rotated box has the same bounding box"
h2r_sh "$H2R_E" 21 991.4 0.3 "H2R_rotate control: ...and the same volume"
h2r_has "$H2R_E" "no longer exists on the edited source: no edge has that direction between faces with those normals, and the solid's own edge 10 no longer has the recorded dihedral angle and length" "H2R_refuse: the source was chamfered in place on the very edge the fillet was recorded on; the edge vanished and the reason is printed"
h2r_has "$H2R_E" "UpdateHistory: object 2 (FilletEdge) kept as it was: edge 1 of 1:" "H2R_refuse: UpdateHistory keeps the old result and names the edge"
h2r_sh "$H2R_E" 17 991.4 0.3 "H2R_refuse: the old result keeps its volume (not the chamfered source's 955)"
h2r_has "$H2R_E" "staged for an exact conic fillet (rho 0.6" "H2R_rho control: a Rho fillet takes its own exact conic path"
h2r_has "$H2R_E" "not recorded in history (this chamfer mode (distance and angle) is not one the rebuild reproduces)" "H2R_angle control: a distance/angle chamfer says it is not recorded"
h2r_count "$H2R_E" "History recording: on. 0 object(s) with live construction history" 2 "H2R_rho/angle control: after the Rho fillet and after the angle chamfer nothing is recorded"

# --- Cap (h2r_cap_script.txt)
# Bounding boxes: 1 capped box 2 source scaled 2x 3 source rotated 90 deg, saved, reopened, moved +4 Z 4 fresh control 5 History Off moved
H2R_C="$(h2r_run cap)" || { echo "$H2R_C"; echo "FAIL: h2r cap script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_C" || { echo "$H2R_C"; echo "FAIL: h2r cap script produced no smoke line"; fail=1; }
h2r_has "$H2R_C" "Capped 1 object(s), 2 opening(s); History is On: the open polysurface(s) are kept hidden as the source of 1 recorded result(s)" "H2R_cap: with History On Cap hides the open polysurface (kept as the recorded source) and adds the capped copy"
h2r_has "$H2R_C" "object 2: Cap <- 1" "H2R_cap: the record names the open polysurface"
h2r_sb "$H2R_C" 1 "0,0,0,10,10,10" 0.05 "H2R_cap: capped box bounding box"
h2r_sb "$H2R_C" 2 "0,0,0,20,20,20" 0.05 "H2R_cap: source scaled 2x: the capped copy was re-capped on the new size"
h2r_sb "$H2R_C" 4 "0,0,0,20,20,20" 0.05 "H2R_cap control: the same Cap performed fresh (History Off) on a 20^3 open box has the same bounding box"
h2r_count "$H2R_C" "6 faces, 76 edges, open" 4 "H2R_cap: the re-capped copies have the same topology as a fresh Cap (6 faces, 76 edges; both rebuilds and the control)"
h2r_sb "$H2R_C" 3 "-10,0,4,10,20,24" 0.05 "H2R_cap: source rotated 90 degrees about Z, saved, reopened in a new document, moved +4 in Z: the record survived and the caps followed"
h2r_count "$H2R_C" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (2)" 3 "H2R_cap: three automatic updates (scale, rotate, and the Move after Open)"
h2r_sb "$H2R_C" 5 "5,0,0,15,10,10" 0.05 "H2R_cap History Off control: Cap edits in place (the moved result's bounding box)"
h2r_count "$H2R_C" "History recording: off. 0 object(s) with live construction history" 2 "H2R_cap History Off control: nothing recorded (the fresh control box and the in-place Cap both report 0 records)"
h2r_has "$H2R_C" "Capped 0 object(s), 0 opening(s)" "H2R_cap control: Cap of a closed solid does nothing"
h2r_has "$H2R_C" "History recording: on. 0 object(s) with live construction history" "H2R_cap control: ...and records nothing"

# --- Project / Pull (h2r_proj_script.txt)
# Bounding boxes: 1 projected line 2 line moved +1,+1 3 plane moved +4 Z 4 line moved +3 X: refused, kept 5 reopened, line moved -3 X
#                 6 pulled point 7 plane moved +4 Z 8 point moved +2 X 9 fresh control
H2R_P="$(h2r_run proj)" || { echo "$H2R_P"; echo "FAIL: h2r proj script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_P" || { echo "$H2R_P"; echo "FAIL: h2r proj script produced no smoke line"; fail=1; }
h2r_has "$H2R_P" "Project: 1 curve(s), 0 point(s); 1 result(s) recorded in history" "H2R_project: a curve that maps to one piece is recorded"
h2r_has "$H2R_P" "object 3: Project <- 2,1" "H2R_project: the record names the curve and the target"
h2r_sb "$H2R_P" 1 "2,2,0,18,18,0" 0.05 "H2R_project: line (2,2)-(18,18) projected along +Z onto the plane"
h2r_sb "$H2R_P" 2 "3,3,0,19,19,0" 0.05 "H2R_project: source line moved +1,+1: the projection followed"
h2r_sb "$H2R_P" 3 "3,3,4,19,19,4" 0.05 "H2R_project: target plane moved +4 in Z: the projection lifted onto it"
h2r_sb "$H2R_P" 9 "3,3,4,19,19,4" 0.05 "H2R_project control: the same projection performed fresh (History Off) has the same bounding box"
h2r_has "$H2R_P" "has no editable options - its inputs are its source objects" "H2R_project: EditHistory says a projection has no options of its own"
h2r_has "$H2R_P" "the curve now projected to 0 piece(s) instead of the one that was recorded" "H2R_project refuse: a line moved partly off the plane maps to no piece: the reason is printed"
h2r_sb "$H2R_P" 4 "3,3,4,19,19,4" 0.05 "H2R_project refuse: the previous projection is kept"
h2r_has "$H2R_P" "UpdateHistory: object 3 (Project) kept as it was:" "H2R_project refuse: UpdateHistory refuses the same way"
h2r_sb "$H2R_P" 5 "3,3,4,19,19,4" 0.05 "H2R_project: after Save/New/Open the record is back and moving the line back rebuilds it"
h2r_has "$H2R_P" "Pull: 0 curve(s), 1 point(s); 1 result(s) recorded in history" "H2R_pull: a pulled point is recorded"
h2r_has "$H2R_P" "object 3: Pull <- 2,1" "H2R_pull: the record names the point and the target"
h2r_sb "$H2R_P" 6 "5,5,0,5,5,0" 0.05 "H2R_pull: point (5,5,-3) pulled to the plane"
h2r_sb "$H2R_P" 7 "5,5,4,5,5,4" 0.05 "H2R_pull: target plane moved +4 in Z: the pulled point followed"
h2r_sb "$H2R_P" 8 "7,5,4,7,5,4" 0.05 "H2R_pull: source point moved +2 in X: the pulled point followed"
h2r_has "$H2R_P" "Project: 2 curve(s), 0 point(s); 0 result(s) recorded in history, 1 source(s) split into several pieces and not recorded" "H2R_project control: a curve that maps to two pieces is not recorded"
h2r_countre "$H2R_P" '^history: Project: 1 curve\(s\), 0 point\(s\)$' 1 "H2R_project History Off control: the fresh projection prints no history note"

# --- BlendSrf (h2r_blend_script.txt)
# Bounding boxes: 1 blend between two squares 2 second square moved +10 X 3 first square moved +4 Y 4 EditHistory continuity=curvature
#                 5 reopened, second square moved +5 X 6 fresh tangency control 7 fresh curvature control 8,9 refused: source deleted
H2R_B="$(h2r_run blend)" || { echo "$H2R_B"; echo "FAIL: h2r blend script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_B" || { echo "$H2R_B"; echo "FAIL: h2r blend script produced no smoke line"; fail=1; }
h2r_has "$H2R_B" "object 3: BlendSrf <- 1,2  [continuity=tangency]" "H2R_blend: the blend records both surfaces and its continuity (neither is consumed)"
h2r_sb "$H2R_B" 1 "10,0,0,20.31,10,0" 0.1 "H2R_blend: tangent blend between two 10x10 squares 10 apart"
h2r_sb "$H2R_B" 2 "10,0,0,30,10,0" 0.1 "H2R_blend: second square moved +10 in X: the blend lengthened (no UpdateHistory)"
h2r_sb "$H2R_B" 3 "10,0,0,30.37,14,0" 0.1 "H2R_blend: first square moved +4 in Y: the blend followed it"
h2r_sb "$H2R_B" 6 "10,0,0,30.37,14,0" 0.1 "H2R_blend control: the same blend built fresh (History Off) between the surfaces in their moved positions has the same bounding box"
h2r_has "$H2R_B" "EditHistory: object 3 (BlendSrf): continuity tangency -> curvature." "H2R_blend: EditHistory changes the continuity"
h2r_sb "$H2R_B" 4 "10,0,0,30.91,14,0" 0.1 "H2R_blend: curvature-continuous rebuild"
h2r_sb "$H2R_B" 7 "10,0,0,30.91,14,0" 0.1 "H2R_blend control: the same Continuity=Curvature blend built fresh has the same bounding box"
h2r_has "$H2R_B" "object 3: BlendSrf <- 1,2  [continuity=curvature]" "H2R_blend: record (with its edge description) read back from the .3dm after New + Open"
h2r_sb "$H2R_B" 5 "10,0,0,35.81,14,0" 0.1 "H2R_blend: reopened, second square moved +5 in X: the blend followed"
h2r_has "$H2R_B" "kept as they were: object 3 - source object 2 no longer exists" "H2R_blend refuse: a deleted source is reported and the blend is kept"
h2r_sb "$H2R_B" 9 "10,0,0,20.31,10,0" 0.1 "H2R_blend refuse: the old blend keeps its shape"
h2r_has "$H2R_B" "UpdateHistory: object 3 (BlendSrf) kept as it was: source object 2 no longer exists" "H2R_blend refuse: UpdateHistory refuses the same way"

# ---------------------------------------------------------------------------
# SO2: exact Shell / OffsetSrf of RIGHT PRISMS (so2_script.txt; prism_solid.h) - the
# non-convex and filleted-box half of "Solid editing with B-rep results (booleans,
# fillet, shell, offset)". An extruded L and a box whose parallel edges were rounded
# with FilletEdge (planar faces + cylindrical strips) used to decline with 'exact
# B-rep shell not used' / 'exact B-rep offset not used' and become a mesh. The profile
# (lines + arcs) is offset analytically (plane -> parallel plane, cylinder ->
# concentric cylinder, new corners = exact line/line intersections, tangent joints stay
# tangent), the caps move along the axis and the result is extruded back into a closed
# B-rep. Expected volumes are closed forms (Steiner/miter offset of the profile area):
#   area(d) = A + d*P + d^2*(sum of tan(turn/2) at the mitred corners + half the arcs' turning)
# and are read from the display mesh (chord 0.005), so the ranges carry tessellation error.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SO2OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/so2_script.txt" 2>&1)" || { echo "$SO2OUT"; echo "FAIL: so2 script exited non-zero"; exit 1; }
else
  SO2OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/so2_script.txt" 2>&1)" || { echo "$SO2OUT"; echo "FAIL: so2 script exited non-zero"; exit 1; }
fi
so2block() { awk -v name="$1" '$0 ~ ("Unknown command: SO2BEGIN_" name "$") { on = 1; next } on && /Unknown command: SO2BEGIN_|Unknown command: SO2END/ { exit } on { print }' <<<"$SO2OUT"; }
so2check() { local blk; blk="$(so2block "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; { grep -E "^history: (Shell|Offset|Object|  [0-9]|Volume|!)" <<<"$blk" || true; } | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
# so2vol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
so2vol() {
  local blk v; blk="$(so2block "$1")"
  v="$({ grep -E "^history: Volume = " <<<"$blk" || true; } | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/')"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- extruded L (profile area 300, perimeter 80, five convex corners and one reflex corner: area(d) = 300 + 80 d + 4 d^2)
so2check L_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_L_shell: the L-shaped extrusion shell is an exact B-rep (before: 'exact B-rep shell not used', mesh)"
so2check L_shell "11 faces, 21 edges, closed solid" "SO2_L_shell: ...a closed solid, outer extrusion (3 faces) + inner extrusion (8 faces)"
so2vol L_shell 1050 1062 "SO2_L_shell: Volume = 8*300 - 6*224 = 1056 (inner profile area 300 - 80 + 4 = 224, inner height 6)"
so2check L_shell "Object [0-9]*: valid" "SO2_L_shell: ...and Check reports it valid"
so2check L_offset_out "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "SO2_L_offset: OffsetSrf +1 of the L is exact (before: 'exact B-rep offset not used', mesh)"
so2vol L_offset_out 3830 3850 "SO2_L_offset: Volume = (300 + 80 + 4)*(8 + 2) = 3840"
so2check L_offset_out "Object [0-9]*: valid" "SO2_L_offset: ...Check valid"
so2check L_offset_in "OffsetSrf: distance -1, 1 object(s), 1 exact B-rep" "SO2_L_offset_in: OffsetSrf -1 of the L is exact"
so2vol L_offset_in 1338 1350 "SO2_L_offset_in: Volume = (300 - 80 + 4)*(8 - 2) = 1344"
so2check L_offset_in "Object [0-9]*: valid" "SO2_L_offset_in: ...Check valid"
so2check L_offset_solid "solid, 1 exact B-rep" "SO2_L_offset_solid: Solid=Yes (hollow wall between the L and its offset) is exact"
so2vol L_offset_solid 1435 1445 "SO2_L_offset_solid: Volume = 3840 - 2400 = 1440"
so2check L_offset_solid "Object [0-9]*: valid" "SO2_L_offset_solid: ...Check valid"
so2check L_shell_toothick "exact B-rep shell not used (the prism would collapse between its caps at that offset)" "SO2_L_declined: a wall of 5 on an 8-high L (2*5 > 8) is refused WITH the reason"
so2check L_arm_toothin "exact B-rep shell not used (a flat edge of the profile would collapse or reverse at that distance)" "SO2_L_declined: a wall of 5 on a 30-high L with 10-wide arms (the inner offset of an arm reverses) is refused WITH the reason"
# --- box with ONE rounded vertical edge (radius 2): area 100 - (1 - pi/4)*4 = 99.1416, perimeter 39.1416, 3 mitred corners + one quarter arc
so2check F1_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_F1_shell: Shell of a box with a FilletEdge-rounded edge is an exact B-rep (before: 'exact B-rep shell not used', mesh)"
so2vol F1_shell 478 484 "SO2_F1_shell: Volume = 10*99.1416 - 8*(64 - (1 - pi/4)) = 481.13"
so2check F1_shell "Object [0-9]*: valid" "SO2_F1_shell: ...Check valid"
so2check F1_offset "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "SO2_F1_offset: OffsetSrf +1 of the rounded box is exact (cylinder r2 -> concentric r3)"
so2vol F1_offset 1700 1710 "SO2_F1_offset: Volume = 12*(144 - (1 - pi/4)*9) = 1704.82"
so2check F1_offset "7 faces, 15 edges, closed solid" "SO2_F1_offset: ...7 faces (5 walls including the rounded strip, 2 caps), closed solid"
so2check F1_offset "Object [0-9]*: valid" "SO2_F1_offset: ...Check valid"
so2check F1_offset_in "OffsetSrf: distance -0.5, 1 object(s), 1 exact B-rep" "SO2_F1_offset_in: OffsetSrf -0.5 (cylinder r2 -> r1.5) is exact"
so2vol F1_offset_in 722 727 "SO2_F1_offset_in: Volume = 9*(99.1416 - 0.5*39.1416 + 0.25*(3 + pi/4)) = 724.65"
so2check F1_offset_in "Object [0-9]*: valid" "SO2_F1_offset_in: ...Check valid"
# --- box with FOUR rounded vertical edges (radius 2): area 100 - 4*(1 - pi/4)*4 = 96.566
so2check F4_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_F4_shell: Shell of a box with 4 rounded edges is an exact B-rep"
so2vol F4_shell 457 463 "SO2_F4_shell: Volume = 10*96.566 - 8*(64 - 4*(1 - pi/4)) = 460.53"
so2check F4_shell "Object [0-9]*: valid" "SO2_F4_shell: ...Check valid"
so2check F4_offset_solid "solid, 1 exact B-rep" "SO2_F4_offset_solid: Solid=Yes offset of the 4-edge rounded box is exact"
so2vol F4_offset_solid 667 672 "SO2_F4_offset_solid: Volume = 12*(144 - 4*(1 - pi/4)*9) - 965.66 = 669.63"
so2check F4_offset_solid "Object [0-9]*: valid" "SO2_F4_offset_solid: ...Check valid"
# --- tilted prisms (axis not a coordinate axis): the construction is frame-independent
so2check R_F1_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_R_F1: the rounded box rotated 37 degrees about (1,2,3) shells exactly"
so2vol R_F1_shell 478 484 "SO2_R_F1: Volume is unchanged by the rotation (481.13)"
so2check R_F1_shell "Object [0-9]*: valid" "SO2_R_F1: ...Check valid"
so2check R_L_offset "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "SO2_R_L: the L rotated 61 degrees about (3,-1,2) offsets exactly"
so2vol R_L_offset 3830 3850 "SO2_R_L: Volume is unchanged by the rotation (3840)"
so2check R_L_offset "Object [0-9]*: valid" "SO2_R_L: ...Check valid"
# --- not a right prism: still declined with its reason
so2check H_shell "Shell: thickness 0.5, closed, exact B-rep, volume" "SO2_H_shell: a box with a Boolean through-hole (sampled keyhole cap loop) now shells exactly (prism-with-hole construction, HSO_; before: 'exact B-rep shell not used (the cap boundary is not one clean closed loop', mesh)"
so2check X_notprism "exact B-rep shell not used (" "SO2_declined: a box with a sphere fused on top is not a right prism: the exact shell is refused with a reason"
if grep -q "^FAIL" <<<"$SO2OUT"; then echo "FAIL so2 script reported an in-script FAIL"; fail=1; fi


# --- NetworkSrf through a CURVE NETWORK (s2n_network_script.txt, prefix S2N_ / s2n_).
# Curves crossing in their interiors (3 one way x 3 the other, drawn scrambled and half of them
# backwards) are sorted into the two directions by their meetings, a bicubic NURBS surface is
# fitted through them and EVERY input curve's distance to it is measured and printed; a network
# whose curves do not meet within the document tolerance is refused with the reason and the old
# behaviour runs; a boundary loop of 4 curves still takes the exact Coons path. Areas are
# tessellation-derived, so they are range-checked (the Windows CI tessellates slightly differently).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  S2N_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/s2n_network_script.txt" 2>&1)" || { echo "$S2N_OUT"; echo "FAIL: s2n network script exited non-zero"; exit 1; }
else
  S2N_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/s2n_network_script.txt" 2>&1)" || { echo "$S2N_OUT"; echo "FAIL: s2n network script exited non-zero"; exit 1; }
fi
s2n_check() { if grep -q "$1" <<<"$S2N_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$S2N_OUT" "$1"; fail=1; fi; }
s2n_count() { local n; n="$(grep -c "$1" <<<"$S2N_OUT" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$S2N_OUT" "$1"; fail=1; fi; }
s2n_area() { { grep -o 'Area = [0-9.]* square' <<<"$S2N_OUT" || true; } | sed -n "${1}p" | sed 's/Area = //; s/ square//'; }
s2n_in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }'; }
grep -q "^smoke:" <<<"$S2N_OUT" || { echo "$S2N_OUT"; echo "FAIL: s2n network script produced no smoke line"; fail=1; }
if grep -q "^FAIL" <<<"$S2N_OUT"; then echo "FAIL s2n network script printed a FAIL line"; fail=1; fi
s2n_count "^ok   expect_objects 0 (got 0)" 5 "S2N_: every case cleaned up after itself (5 sections, none left an object behind)"
s2n_check "NetworkSrf: curve network of 3 x 3 curves (9 meetings, 5 crossing in their interiors, worst meeting gap [0-9.e-]*)" "S2N_3x3: six scrambled/reversed curves are sorted into 3 + 3, 9 meetings of which 5 cross in interiors"
s2n_check "measured distance of each input curve from the surface: \([0-9.e-]*, \)\{5\}[0-9.e-]* (worst [0-9.e-]*, document tolerance 0.001: met)" "S2N_3x3: the distance of ALL SIX input curves from the surface is measured and printed, and met the tolerance"
s2n_check "Approximate least-squares fit over the curves' bounding rectangle, not an interpolating or trimmed surface" "S2N_3x3: the result labels itself approximate and untrimmed"
S2N_WORST="$({ grep -o 'worst [0-9.e-]*, document tolerance 0.001: met' <<<"$S2N_OUT" || true; } | head -1 | sed 's/worst //; s/, document.*//')"
S2N_GAP="$({ grep -o 'worst meeting gap [0-9.e-]*' <<<"$S2N_OUT" || true; } | head -1 | sed 's/worst meeting gap //')"
if s2n_in_range "$S2N_WORST" 0 0.001; then echo "ok   S2N_3x3: worst curve-to-surface deviation $S2N_WORST <= 0.001"; else echo "FAIL S2N_3x3 worst deviation '$S2N_WORST' not in 0..0.001"; fail=1; fi
if s2n_in_range "$S2N_GAP" 0 0.001; then echo "ok   S2N_3x3: worst meeting gap $S2N_GAP <= 0.001"; else echo "FAIL S2N_3x3 worst meeting gap '$S2N_GAP' not in 0..0.001"; fail=1; fi
# The area of the 6 x 4 rectangle plus the 0.72 high bump is a little over 24 (measured 25.52 here); the bounding box reaches the bump top z = 0.72.
s2n_check "NURBS surface (cubic where the net allows) fitted through the curves and the meetings ([0-9]* x [0-9]* net)" "S2N_3x3: the control net of the fitted surface is reported"
S2N_A1="$(s2n_area 1)"
if s2n_in_range "$S2N_A1" 25 26.2; then echo "ok   S2N_3x3: area $S2N_A1 in 25..26.2 (25.52 when written: the 6 x 4 rectangle plus the 0.72 high bump)"; else echo "FAIL S2N_3x3 area '$S2N_A1' not in 25..26.2"; fail=1; fi
S2N_TOP="$({ grep -o 'Bounding box min 0,0,-\?[0-9.e-]* max 6,4,[0-9.e-]*' <<<"$S2N_OUT" || true; } | head -1 | sed 's/.* max 6,4,//')"
if s2n_in_range "$S2N_TOP" 0.69 0.75; then echo "ok   S2N_3x3: the surface spans x 0..6, y 0..4 and its top is z = $S2N_TOP (the bump height 0.72 is reproduced through the interior curves)"; else echo "FAIL S2N_3x3 bounding box top '$S2N_TOP' not in 0.69..0.75 (or the box is not 6 x 4)"; fail=1; fi
s2n_count "Object [0-9]*: valid" 1 "S2N_3x3: Check reports the fitted surface valid"
s2n_check "NetworkSrf: these curves cross in their interiors but cannot be fitted as a curve network (curve 1 does not meet the rest of the network within the tolerance (nearest is curve [0-9]*, 0\.[45][0-9]* apart)); using the older loop behaviour" "S2N_miss: a curve lifted 0.5 off the network is refused with the measured miss and the old behaviour runs"
s2n_check "NetworkSrf: curve network of 2 x 2 curves (4 meetings, 4 crossing in their interiors" "S2N_hash: 4 curves forming a # (2 x 2, all crossings interior) take the network path"
S2N_A2="$(s2n_area 2)"
if s2n_in_range "$S2N_A2" 23.5 24.5; then echo "ok   S2N_hash: flat # area $S2N_A2 in 23.5..24.5 (the 6 x 4 bounding rectangle of the curves)"; else echo "FAIL S2N_hash area '$S2N_A2' not in 23.5..24.5"; fail=1; fi
s2n_check "NetworkSrf: exact Coons patch through 4 curves" "S2N_loop control: a closed 4-curve boundary loop still takes the exact Coons path"
s2n_count "NetworkSrf: curve network of" 2 "S2N_: only the two crossing networks used the network routine (the miss and the loop did not)"


# H3R_: construction history, part 3 - Sweep1/Sweep2 with SEVERAL cross-sections, the non-planar fitted Patch and
# FilletSrf/ChamferSrf (Trim=No) now record {sources, options} and rebuild when a source is edited (automatic
# propagation, no UpdateHistory), including a source edited through its CONTROL POINTS (HBar + HBarDragSelfTest: the
# TransformSubObjects call sequence a gizmo/control-point drag makes). Every rebuild is compared with the SAME
# construction built fresh (History Off) from the same, already moved, sources; every refusal keeps the old result.
# Scripts: h3r_{sweep1,sweep2,patch,fillet}_script.txt (their headers list the numbered measurements).
# ---------------------------------------------------------------------------
H3R_DIR="$TMPW/h3r"
mkdir -p "$H3R_DIR"
h3r_run() {  # h3r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H3R_DIR|g" "$HERE/h3r_$1_script.txt" > "$H3R_DIR/h3r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H3R_DIR/h3r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H3R_DIR/h3r_$1_script.txt" 2>&1
  fi
}
h3r_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
h3r_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
h3r_ar() { { grep -oE 'Area = [0-9.e+-]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Area = //'; }
h3r_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
h3r_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
# bounding box n of output $1 equals the expected "x0,y0,z0,x1,y1,z1" within $4 (a tolerance range: the Windows CI tessellates slightly differently)
h3r_sb() { h3r_ok "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(h3r_bb "$1" "$2"), expected $3 +/- $4)"; }
# bounding box n equals bounding box m of the same output (a rebuilt result against the same construction built fresh)
h3r_eq() { h3r_ok "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$(h3r_bb "$1" "$3")" "$4")" "$5 (#$2 $(h3r_bb "$1" "$2") vs #$3 $(h3r_bb "$1" "$3"))"; }
# bounding box n differs from bounding box m by more than $4 in at least one coordinate (the edit really changed the result)
h3r_ne() { h3r_ok "$([ "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$(h3r_bb "$1" "$3")" "$4")" = 1 ] && echo 0 || echo 1)" "$5 (#$2 $(h3r_bb "$1" "$2") vs #$3 $(h3r_bb "$1" "$3"))"; }
h3r_sa() { h3r_ok "$(h3r_closev "$(h3r_ar "$1" "$2")" "$3" "$4")" "$5 (measured $(h3r_ar "$1" "$2"), expected $3 +/- $4)"; }
h3r_eqa() { h3r_ok "$(h3r_closev "$(h3r_ar "$1" "$2")" "$(h3r_ar "$1" "$3")" "$4")" "$5 (area #$2 $(h3r_ar "$1" "$2") vs #$3 $(h3r_ar "$1" "$3"))"; }
h3r_nea() { h3r_ok "$([ "$(h3r_closev "$(h3r_ar "$1" "$2")" "$(h3r_ar "$1" "$3")" "$4")" = 1 ] && echo 0 || echo 1)" "$5 (area #$2 $(h3r_ar "$1" "$2") vs #$3 $(h3r_ar "$1" "$3"))"; }
h3r_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
h3r_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- Sweep1 with two cross-sections (h3r_sweep1_script.txt)
# Bounding boxes: 1 fresh wall 2 section 2 moved +1 Y 3 section 1 moved -1 Y 4 moved again then Undo (= 3) 5 moved again 6 rail control points moved
#   7 fresh sweep from the same moved sources (= 6) 8 reopened, section 1 moved +1 X 9 fresh (= 8) 10 refused (= 8) 11 History Off control (= 1)
# Areas: 1 fresh 2 section 2 moved 3 section 1 moved twice 4 control points moved 5 fresh (= 4) 6 reopened 7 fresh (= 6) 8 refused (= 6) 9 History Off control (= 1)
H3R_S1="$(h3r_run sweep1)" || { echo "$H3R_S1"; echo "FAIL: h3r sweep1 script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_S1" || { echo "$H3R_S1"; echo "FAIL: h3r sweep1 script produced no smoke line"; fail=1; }
h3r_has "$H3R_S1" "Sweep1: exact kernel multi-section sweep (2 sections, 32 rail stations)" "H3R_sweep1: the two-section sweep is the exact kernel one"
h3r_count "$H3R_S1" "object 4: Sweep1 <- 1,2,3" 3 "H3R_sweep1: the record lists the rail and BOTH sections (live, and read back from the .3dm after New + Open)"
h3r_sb "$H3R_S1" 1 "-1.75,-1.48,0,1.5,1.48,10" 0.15 "H3R_sweep1: curved rail, circles r=1 (z=0) and r=1.5 (z=10)"
h3r_has "$H3R_S1" "History: source object(s) 3 changed - 1 dependent(s) re-evaluated (4)" "H3R_sweep1: moving section 2 rebuilds the wall automatically (no UpdateHistory)"
h3r_sb "$H3R_S1" 2 "-1.75,-0.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 2 moved +1 Y: the wall's Y range grew to follow it"
h3r_ne "$H3R_S1" 2 1 0.3 "H3R_sweep1 control: the wall really changed (not the old bounding box)"
h3r_sb "$H3R_S1" 3 "-1.75,-1.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 1 moved -1 Y: the wall followed"
h3r_eq "$H3R_S1" 4 3 0.02 "H3R_sweep1: Undo takes the section move and the rebuilt wall back together (same undo step)"
h3r_sb "$H3R_S1" 5 "-1.75,-2.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 1 moved -1 Y again: the wall followed"
h3r_has "$H3R_S1" "HBarDragSelfTest: moved anchor control point 1 by 1.5,0,0" "H3R_sweep1: the rail's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_S1" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (4)" "H3R_sweep1: editing the rail's CONTROL POINTS rebuilt the wall with no UpdateHistory"
h3r_ne "$H3R_S1" 6 5 0.3 "H3R_sweep1 control: the control-point edit really changed the wall"
h3r_eq "$H3R_S1" 7 6 0.02 "H3R_sweep1: the wall rebuilt after the control-point edit equals the same sweep built fresh from the edited rail and sections"
h3r_eqa "$H3R_S1" 5 4 0.8 "H3R_sweep1: ...and has the same area"
h3r_sa "$H3R_S1" 1 75.1 1.5 "H3R_sweep1: wall area"
h3r_nea "$H3R_S1" 4 3 0.3 "H3R_sweep1 control: the control-point edit changed the area"
h3r_eq "$H3R_S1" 9 8 0.02 "H3R_sweep1: after Save/New/Open the record is back and moving a section rebuilds the wall (equals a fresh sweep)"
h3r_eqa "$H3R_S1" 7 6 0.8 "H3R_sweep1: ...with the same area"
h3r_ne "$H3R_S1" 8 7 0.1 "H3R_sweep1 control: the reopened wall changed when its section moved"
h3r_has "$H3R_S1" "kept as they were: object 4 - dino8::kernel::Brep::Sweep1Sections: the rail never crosses the plane of section 2" "H3R_sweep1 refuse: a section the rail no longer crosses is reported with the kernel's reason and the wall kept"
h3r_eq "$H3R_S1" 10 8 0.02 "H3R_sweep1 refuse: the old wall keeps its shape"
h3r_eq "$H3R_S1" 11 1 0.02 "H3R_sweep1 History Off control: moving a section leaves a wall built with History Off alone"
h3r_has "$H3R_S1" "History recording: off. 0 object(s) with live construction history" "H3R_sweep1 History Off control: nothing was recorded"

# --- Sweep2 with two cross-sections (h3r_sweep2_script.txt)
# Bounding boxes: 1 fresh wall 2 section 2 moved +1 Y 3 section 1 moved -1 Y 4 moved again then Undo (= 3) 5 rail 2 control points moved 6 fresh (= 5)
#   7 reopened, section 2 moved +1 Y 8 fresh (= 7) 9 refused: two sections at one station (= 7) 10 History Off control (= 1)
# Areas: 1 fresh 2 section 2 moved 3 control points moved 4 fresh (= 3) 5 reopened 6 fresh (= 5) 7 refused (= 5) 8 History Off control (= 1)
H3R_S2="$(h3r_run sweep2)" || { echo "$H3R_S2"; echo "FAIL: h3r sweep2 script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_S2" || { echo "$H3R_S2"; echo "FAIL: h3r sweep2 script produced no smoke line"; fail=1; }
h3r_has "$H3R_S2" "Sweep2: exact kernel multi-section sweep (2 sections, 32 rail stations)" "H3R_sweep2: the two-section sweep is the exact kernel one"
h3r_count "$H3R_S2" "object 5: Sweep2 <- 1,2,3,4" 3 "H3R_sweep2: the record lists both rails and BOTH sections (live, and read back from the .3dm after New + Open)"
h3r_sb "$H3R_S2" 1 "0,0,0,5.53,2,10" 0.15 "H3R_sweep2: straight rail and curved rail, arcs at z=0 and z=10"
h3r_has "$H3R_S2" "History: source object(s) 4 changed - 1 dependent(s) re-evaluated (5)" "H3R_sweep2: moving section 2 rebuilds the wall automatically (no UpdateHistory)"
h3r_sb "$H3R_S2" 2 "0,0,0,5.53,3,10" 0.15 "H3R_sweep2: section 2 moved +1 Y: the wall's Y range grew"
h3r_sb "$H3R_S2" 3 "0,-1,0,5.53,3,10" 0.15 "H3R_sweep2: section 1 moved -1 Y: the wall followed"
h3r_eq "$H3R_S2" 4 3 0.02 "H3R_sweep2: Undo takes the section move and the rebuilt wall back together (same undo step)"
h3r_has "$H3R_S2" "HBarDragSelfTest: moved anchor control point 1 by 1,0,0" "H3R_sweep2: rail 2's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_S2" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (5)" "H3R_sweep2: editing rail 2's CONTROL POINTS rebuilt the wall with no UpdateHistory"
h3r_ne "$H3R_S2" 5 4 0.3 "H3R_sweep2 control: the control-point edit really changed the wall"
h3r_eq "$H3R_S2" 6 5 0.02 "H3R_sweep2: the wall rebuilt after the control-point edit equals the same sweep built fresh from the edited rails and sections"
h3r_eqa "$H3R_S2" 4 3 0.8 "H3R_sweep2: ...and has the same area"
h3r_sa "$H3R_S2" 1 60.7 1.5 "H3R_sweep2: wall area"
h3r_eq "$H3R_S2" 8 7 0.02 "H3R_sweep2: after Save/New/Open the record is back and moving a section rebuilds the wall (equals a fresh sweep)"
h3r_eqa "$H3R_S2" 6 5 0.8 "H3R_sweep2: ...with the same area"
h3r_has "$H3R_S2" "kept as they were: object 5 - dino8::kernel::Brep::Sweep2Sections: two sections sit at the same station of the rails" "H3R_sweep2 refuse: two sections at one station are reported with the kernel's reason and the wall kept"
h3r_eq "$H3R_S2" 9 7 0.02 "H3R_sweep2 refuse: the old wall keeps its shape"
h3r_eq "$H3R_S2" 10 1 0.02 "H3R_sweep2 History Off control: moving a section leaves a wall built with History Off alone"
h3r_has "$H3R_S2" "History recording: off. 0 object(s) with live construction history" "H3R_sweep2 History Off control: nothing was recorded"

# --- Non-planar Patch (h3r_patch_script.txt)
# Bounding boxes: 1 patch through 9 points 2 centre point moved +2 Z 3 fresh (= 2) 4 all points flattened: refused (= 2) 5 a point deleted: refused (= 2)
#   6 saddle curve, trimmed face 7 two control points of the curve moved 8 fresh patch from the moved curve (= 7)
# Areas: 1 patch 2 moved (= 3 fresh) 4 saddle 5 moved (= 6 fresh)
H3R_P="$(h3r_run patch)" || { echo "$H3R_P"; echo "FAIL: h3r patch script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_P" || { echo "$H3R_P"; echo "FAIL: h3r patch script produced no smoke line"; fail=1; }
h3r_has "$H3R_P" "object 10: Patch <- 1,2,3,4,5,6,7,8,9" "H3R_patch: the fitted patch records all nine points it was fitted to"
h3r_has "$H3R_P" "object 2: Patch <- 1" "H3R_patch: the trimmed saddle patch records its curve"
h3r_sb "$H3R_P" 1 "-2,-2,-1,2,2,1" 0.1 "H3R_patch: patch through nine points"
h3r_sa "$H3R_P" 1 17.27 0.3 "H3R_patch: its area (closed form 17.27)"
h3r_has "$H3R_P" "History: source object(s) 5 changed - 1 dependent(s) re-evaluated (10)" "H3R_patch: moving a point re-runs the fit automatically (no UpdateHistory)"
h3r_sb "$H3R_P" 2 "-2,-2,-1,2,2,1.94" 0.15 "H3R_patch: centre point moved +2 Z: the patch followed (3x3 net now)"
h3r_ne "$H3R_P" 2 1 0.3 "H3R_patch control: the patch really changed"
h3r_eq "$H3R_P" 3 2 0.02 "H3R_patch: equals the patch fitted fresh through the moved points"
h3r_eqa "$H3R_P" 2 3 0.3 "H3R_patch: ...with the same area"
h3r_has "$H3R_P" "the sources are now flat (within 0.001 of their best-fit plane), so the fitted patch no longer applies" "H3R_patch refuse: flattened data are reported and the patch kept"
h3r_eq "$H3R_P" 4 2 0.02 "H3R_patch refuse: the patch keeps its shape"
h3r_has "$H3R_P" "object 10 - source object 9 no longer exists" "H3R_patch refuse: a deleted point is reported and the patch kept"
h3r_eq "$H3R_P" 5 2 0.02 "H3R_patch refuse: the patch keeps its shape"
h3r_sa "$H3R_P" 4 84.9 1.5 "H3R_patch: saddle trimmed face area (the flat disc is 78.5)"
h3r_has "$H3R_P" "HBarDragSelfTest: moved anchor control point 3 by 0,0,0.4" "H3R_patch: the saddle curve's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_P" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (2)" "H3R_patch: editing the curve's CONTROL POINTS re-fitted and re-trimmed the face with no UpdateHistory"
h3r_ne "$H3R_P" 7 6 0.3 "H3R_patch control: the control-point edit really changed the face"
h3r_eq "$H3R_P" 8 7 0.02 "H3R_patch: the rebuilt face equals the patch fitted fresh through the edited curve"
h3r_eqa "$H3R_P" 5 6 0.5 "H3R_patch: ...with the same area"

# --- FilletSrf / ChamferSrf, Trim=No (h3r_fillet_script.txt)
# Bounding boxes: 1 fillet r1 2 wall moved +3 X 3 fresh (= 2) 4 EditHistory radius=2 5 fresh r2 (= 4) 6 reopened, wall +2 X 7 fresh (= 6) 8 refused (= 6)
#   9 ChamferSrf 10 wall moved +2 X 11 fresh chamfer (= 10)
# Areas: 1 fillet 2 moved 3 fresh 4 r2 5 fresh r2 6 reopened 7 fresh 8 chamfer 9 moved 10 fresh chamfer  (quarter circle r: pi/2 r x 10; chamfer: sqrt(2) r x 10)
H3R_F="$(h3r_run fillet)" || { echo "$H3R_F"; echo "FAIL: h3r fillet script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_F" || { echo "$H3R_F"; echo "FAIL: h3r fillet script produced no smoke line"; fail=1; }
h3r_has "$H3R_F" "object 3: FilletSrf <- 1,2  [radius=1, endradius=1]" "H3R_fillet: the fillet records both surfaces and its radii (neither is consumed)"
h3r_sb "$H3R_F" 1 "0,0,0,1,10,1" 0.05 "H3R_fillet: radius-1 fillet between a floor and a wall"
h3r_sa "$H3R_F" 1 15.71 0.1 "H3R_fillet: its area (quarter circle pi/2 x 10 = 15.71)"
h3r_has "$H3R_F" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (3)" "H3R_fillet: moving the wall rebuilds the fillet automatically (no UpdateHistory)"
h3r_sb "$H3R_F" 2 "3,0,0,4,10,1" 0.05 "H3R_fillet: wall moved +3 X: the fillet followed"
h3r_eq "$H3R_F" 3 2 0.02 "H3R_fillet: equals the fillet built fresh between the moved surfaces"
h3r_has "$H3R_F" "EditHistory: object 3 (FilletSrf): radius 1 -> 2." "H3R_fillet: EditHistory changes the radius"
h3r_sb "$H3R_F" 4 "3,0,0,5,10,2" 0.05 "H3R_fillet: radius-2 rebuild"
h3r_sa "$H3R_F" 4 31.42 0.2 "H3R_fillet: its area (pi x 10 = 31.42)"
h3r_eq "$H3R_F" 5 4 0.02 "H3R_fillet: equals the radius-2 fillet built fresh"
h3r_has "$H3R_F" "object 3: FilletSrf <- 1,2  [radius=2, endradius=2]" "H3R_fillet: record (with the edited radius) read back from the .3dm after New + Open"
h3r_sb "$H3R_F" 6 "5,0,0,7,10,2" 0.05 "H3R_fillet: reopened, wall moved +2 X more: the fillet followed"
h3r_eq "$H3R_F" 7 6 0.02 "H3R_fillet: equals the fillet built fresh"
h3r_has "$H3R_F" "kept as they were: object 3 - source object 1 no longer exists" "H3R_fillet refuse: a deleted source is reported and the fillet kept"
h3r_eq "$H3R_F" 8 6 0.02 "H3R_fillet refuse: the old fillet keeps its shape"
h3r_has "$H3R_F" "ChamferSrf: built between object 1 and 2, radius 1" "H3R_chamfer: ChamferSrf Trim=No builds the ruled chamfer"
h3r_sa "$H3R_F" 8 14.14 0.1 "H3R_chamfer: its area (sqrt(2) x 10 = 14.14)"
h3r_sb "$H3R_F" 10 "2,0,0,3,10,1" 0.05 "H3R_chamfer: wall moved +2 X: the chamfer followed"
h3r_eq "$H3R_F" 11 10 0.02 "H3R_chamfer: equals the chamfer built fresh between the moved surfaces"
h3r_has "$H3R_F" "FilletSrf: no history recorded - Trim=Yes cuts the two source surfaces" "H3R_fillet negative control: Trim=Yes is not recorded, and says why"
h3r_has "$H3R_F" "History recording: on. 0 object(s) with live construction history" "H3R_fillet negative control: Trim=Yes added no record (the History after it lists none)"


# TS2: ToSubD of a revolved solid (tosubd2_script.txt). The app's Cylinder,
# Cone and TCone (a surface-of-revolution wall plus trimmed planar caps) used
# to fall back to the chord-tolerance mesher: an ~11900-face triangle cage,
# 0 of 1 limit-surface-fidelity verified, worst deviation 0.02-0.05. The cage
# is now built from the Brep's own wall parametrisation and shared rim ring
# (all-quad O-grid caps), the rims are creased, and the Catmull-Clark limit
# surface is measured against the exact surface (the same analytic wall
# sampled far finer than the tolerance, exactly planar caps). Ranges rather
# than exact numbers for everything that depends on the platform's float
# evaluation (deviation, volumes).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  TS2="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/tosubd2_script.txt" 2>&1)" || { echo "$TS2"; echo "FAIL: tosubd2 script exited non-zero"; exit 1; }
else
  TS2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/tosubd2_script.txt" 2>&1)" || { echo "$TS2"; echo "FAIL: tosubd2 script exited non-zero"; exit 1; }
fi
ts2check() { if grep -q -- "$1" <<<"$TS2"; then echo "ok   $2"; else echo "FAIL $2"; near "$TS2" "$1"; fail=1; fi; }
# in range: ts2range VALUE LO HI DESC
ts2range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t TS2_TOSUBD < <(grep -F "history: ToSubD: created" <<<"$TS2" || true)
mapfile -t TS2_LIST < <(grep -E "^history:   [0-9]+ faces, [0-9]+ edges, [0-9]+ vertices, [0-9]+ creases" <<<"$TS2" || true)
mapfile -t TS2_VOL < <(grep -o "Volume = [0-9.e+-]*" <<<"$TS2" | awk '{print $3}' || true)
if [ "${#TS2_TOSUBD[@]}" -eq 6 ] && [ "${#TS2_LIST[@]}" -eq 5 ] && [ "${#TS2_VOL[@]}" -eq 4 ]; then
  echo "ok   tosubd2 script printed 6 ToSubD lines, 5 SubD List lines and 4 volumes"
  # worst measured deviation per ToSubD line, in script order: cylinder, cone, TCone, big cylinder, torus, extruded circle
  ts2dev() { sed -E 's/.*worst measured deviation ([0-9.]+)\).*/\1/' <<<"${TS2_TOSUBD[$1]}"; }
  ts2name=(cylinder cone TCone "big cylinder (radius 40)" torus "extruded circle solid")
  for i in 0 1 2 3 4 5; do
    if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.0[0-9]*)" <<<"${TS2_TOSUBD[$i]}"; then
      ts2range "$(ts2dev $i)" 0 0.001 "ToSubD of the ${ts2name[$i]} is VERIFIED: measured limit-surface deviation within the 0.001 document tolerance (before: 0 of 1 verified, 0.02-0.05, for cylinder/cone/TCone)"
    else
      echo "FAIL ToSubD of the ${ts2name[$i]} is not verified: ${TS2_TOSUBD[$i]}"; fail=1
    fi
  done
  # The three wall solids and the big cylinder go through the analytic revolved-solid cage; the torus does not.
  for i in 0 1 2 3 5; do
    if grep -q "analytic revolved-solid cage (.* segments around x .* along the wall, all-quad O-grid caps welded to the wall's rim ring), cage interpolated onto the Brep surface" <<<"${TS2_TOSUBD[$i]}" && grep -q "against the exact surface sampled [0-9]* x 64 (planar caps exact), reference chord sag 0\.000[0-9]* included in the deviation" <<<"${TS2_TOSUBD[$i]}"; then
      echo "ok   ToSubD of the ${ts2name[$i]} reports the analytic cage and what the deviation was measured against"
    else
      echo "FAIL ToSubD of the ${ts2name[$i]} does not report the analytic revolved-solid cage: ${TS2_TOSUBD[$i]}"; fail=1
    fi
  done
  if grep -q "analytic revolved-solid cage" <<<"${TS2_TOSUBD[4]}"; then echo "FAIL the torus unexpectedly used the revolved-solid cage"; fail=1; else echo "ok   the torus keeps its grid cage (not a wall + cap solid)"; fi
  # Cage sizes: a few hundred faces (before: 11894 / 11660 / 11894), closed manifold (Euler), rims creased.
  # F E V C per List line: cylinder, cone, TCone, big cylinder
  ts2lname=(cylinder cone TCone "big cylinder (radius 40)" "extruded circle solid")
  ts2fe() { sed -E 's/^history: +([0-9]+) faces, ([0-9]+) edges, ([0-9]+) vertices, ([0-9]+) creases.*/\1 \2 \3 \4/' <<<"${TS2_LIST[$1]}"; }
  for i in 0 1 2 3 4; do
    read -r F E V C <<<"$(ts2fe $i)"
    if [ "$((V - E + F))" -eq 2 ]; then echo "ok   the ${ts2lname[$i]} cage is a closed manifold: Euler $V - $E + $F = 2"; else echo "FAIL the ${ts2lname[$i]} cage Euler $V - $E + $F != 2"; fail=1; fi
    ts2range "$F" 300 1600 "the ${ts2lname[$i]} cage has a few hundred to ~1500 faces (before: ~11900)"
    ts2range "$C" 64 160 "the ${ts2lname[$i]} cage creases its rims (and the cone's apex spokes)"
  done
  ts2check "352 faces, 704 edges, 354 vertices, 64 creases" "the cylinder cage: 32 x 5 wall + two 64-face O-grid caps = 352 faces, 64 rim creases (before: 11894 faces, 512 creases)"
  ts2check "32 segments around x 5 along the wall, all-quad O-grid caps" "the cylinder uses the 32-segment cage (verified at the first round)"
  # Volumes in script order: cylinder SubD, cylinder ToNURBS, cone SubD, TCone SubD
  ts2range "${TS2_VOL[1]}" 501.0 504.4 "ToNURBS of the cylinder SubD: closed polysurface, Volume vs pi r^2 h = 502.65"
  ts2range "${TS2_VOL[0]}" 497.0 511.0 "cylinder SubD display Volume vs pi r^2 h = 502.65 (display tessellation of the SubD, looser)"
  ts2range "${TS2_VOL[2]}" 163.5 171.5 "cone SubD Volume vs pi r^2 h / 3 = 167.55"
  ts2range "${TS2_VOL[3]}" 288.0 300.0 "TCone SubD Volume vs pi h (R^2 + R r + r^2) / 3 = 293.2"
else
  echo "FAIL tosubd2 script printed ${#TS2_TOSUBD[@]} ToSubD / ${#TS2_LIST[@]} List / ${#TS2_VOL[@]} Volume lines (expected 6 / 5 / 4)"; fail=1
fi
ts2check "ToNURBS: watertight conversion of a 352-face SubD (2 Catmull-Clark refinement round(s) first): 5632 bicubic patches" "ToNURBS of the cylinder SubD converts the 352-face cage"
ts2check "0 naked edge(s) left, closed solid: yes, manifold" "...to a closed manifold polysurface"
ts2check "5632 faces, 22528 edges, closed solid" "...which lists as a closed solid"
ts2check "gl_error=0" "tosubd2 script ran without OpenGL errors"

# ---------------------------------------------------------------------------
# S2C_: Sweep2 with SEVERAL cross-sections on CLOSED rails (a cyclic sweep: the
# wall is closed round the ring) and on rails that TOUCH at their ends (a wall
# pinched to a point there) -> the kernel's exact Brep::Sweep2Sections,
# driven by sweep2_cyclic_script.txt (read its header for the seven cases). All
# figures are the kernel's own printed deviations, the surface's closest-point
# distance to points ON the sections (ClosestPt), and the display mesh's Area /
# BoundingBox against closed forms, each as a RANGE (the mesh-derived figures
# tessellate slightly differently on Windows). Output checks use here-strings.
# ---------------------------------------------------------------------------
s2c_ok() { echo "ok   $1"; }
s2c_bad() { echo "FAIL $1"; fail=1; }
S2C_CMD=(timeout 900 "$BIN" --smoke 30 --script "$HERE/sweep2_cyclic_script.txt")
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  S2C="$("${S2C_CMD[@]}" 2>&1)" || { echo "$S2C" | tail -40; echo "FAIL S2C_run: sweep2 cyclic script exited non-zero"; fail=1; S2C=""; }
else
  S2C="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/sweep2_cyclic_script.txt" 2>&1)" || { echo "$S2C" | tail -40; echo "FAIL S2C_run: sweep2 cyclic script exited non-zero"; fail=1; S2C=""; }
fi
if grep -q "^FAIL" <<<"$S2C"; then s2c_bad "S2C_script: an @expect line of the script failed"; else s2c_ok "S2C_script: every @expect_objects line of the script held"; fi
# The output of the n-th Sweep2 command (up to the next one).
s2c_case() { awk -v n="$1" '/Command: Sweep2$/ { c++ } c == n' <<<"$S2C"; }
# All "distance X" values of the ClosestPt lines of a case must be below 1e-6; $2 = how many there must be.
s2c_dists() {
  local d n
  d="$(grep -o "Closest point [^ ]* distance [0-9.e+-]*" <<<"$1" | awk '{print $NF}' || true)"
  n="$(grep -c . <<<"$d" || true)"
  if [ "$n" = "$2" ] && awk '{ if ($1 + 0 >= 1e-6) bad = 1 } END { exit bad }' <<<"$d"; then
    s2c_ok "$3 (all $2 points on the input sections are within 1e-6 of the surface; got: $(echo $d))"
  else
    s2c_bad "$3 (expected $2 distances below 1e-6, got $n: $(echo $d))"
  fi
}
# The kernel's printed accuracy: sections reproduced below 1e-12 and the wall edges within $2 of the rails.
s2c_acc() {
  local line
  line="$(grep -o "([0-9]* sections, [0-9]* rail stations); measured: sections reproduced to [0-9.e+-]*, wall edges within [0-9.e+-]* of the rails" <<<"$1" | head -1 || true)"
  if [ -n "$line" ] && awk -v b="$2" '{ s = $10; e = $14; exit !(s + 0 < 1e-12 && e + 0 <= b) }' <<<"$line"; then
    s2c_ok "$3 ($line)"
  else
    s2c_bad "$3 (accuracy line missing or out of bounds: '$line')"
  fi
}
# BoundingBox of the case: $2 = "x0lo x0hi y0lo y0hi z0lo z0hi x1lo x1hi y1lo y1hi z1lo z1hi" (min then max corner ranges).
s2c_bbox() {
  local line
  line="$(grep -o "Bounding box min [^ ]* max [^ ]*" <<<"$1" | head -1 || true)"
  if [ -n "$line" ] && awk -v r="$2" '{ split($4, a, ","); split($6, b, ","); split(r, q, " ");
        ok = (a[1] >= q[1] && a[1] <= q[2] && a[2] >= q[3] && a[2] <= q[4] && a[3] >= q[5] && a[3] <= q[6] &&
              b[1] >= q[7] && b[1] <= q[8] && b[2] >= q[9] && b[2] <= q[10] && b[3] >= q[11] && b[3] <= q[12]); exit !ok }' <<<"$line"; then
    s2c_ok "$3 ($line)"
  else
    s2c_bad "$3 (box '$line' outside the expected ranges $2)"
  fi
}
s2c_area() {
  local v
  v="$(grep -o "Area = [0-9.e+-]*" <<<"$1" | head -1 | awk '{print $3}' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v > lo && v < hi) }'; then s2c_ok "$4 (area $v in ($2, $3))"; else s2c_bad "$4 (area '$v' outside ($2, $3))"; fi
}
S2C_A="$(s2c_case 1)"; S2C_B="$(s2c_case 2)"; S2C_C="$(s2c_case 3)"; S2C_D="$(s2c_case 4)"; S2C_E="$(s2c_case 5)"; S2C_F="$(s2c_case 6)"; S2C_G="$(s2c_case 7)"
# (A) closed rails r = 5 and 8, three straight radial sections: the flat annulus, pi (64 - 25) = 122.52
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_A"; then s2c_ok "S2C_A_kernel: two closed rings + 3 radial sections reach the kernel's Brep::Sweep2Sections (no fallback)"; else s2c_bad "S2C_A_kernel: closed rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_A" 1e-3 "S2C_A_accuracy: sections reproduced below 1e-12 and the wall edges within the document tolerance 0.001 of both rings"
s2c_area "$S2C_A" 121.0 123.6 "S2C_A_area: flat annulus area pi (8^2 - 5^2) = 122.52 to the display mesh's tessellation"
s2c_bbox "$S2C_A" "-8.05 -7.8 -8.05 -7.8 -0.01 0.01 7.8 8.05 7.8 8.05 -0.01 0.01" "S2C_A_bbox: box is the r = 8 ring's extent and z = 0"
s2c_dists "$S2C_A" 5 "S2C_A_passthrough"
# (B) the same rings with three different arched sections (control heights 1, 4, 2 -> arch heights 0.5, 2, 1)
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_B"; then s2c_ok "S2C_B_kernel: three different arched sections between closed rings reach the kernel"; else s2c_bad "S2C_B_kernel: arched sections on closed rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_B" 1e-3 "S2C_B_accuracy: sections reproduced below 1e-12, wall edges within the document tolerance of both rings"
s2c_bbox "$S2C_B" "-8.05 -7.8 -8.05 -7.8 -0.01 0.01 7.8 8.05 7.8 8.05 1.9 2.2" "S2C_B_bbox: ring extent in x/y and a tallest arch of about 2 (the 4-control-height section's 4 / 2)"
s2c_dists "$S2C_B" 3 "S2C_B_passthrough"
# (C) rails that meet at both ends, three straight sections: the flat lens, 2 int y dx = 160 / 6 = 26.667
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_C"; then s2c_ok "S2C_C_kernel: two rails meeting at both ends reach the kernel (no fallback)"; else s2c_bad "S2C_C_kernel: touching rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_C" 1e-3 "S2C_C_accuracy: sections reproduced below 1e-12, wall edges within the document tolerance of the rails"
s2c_area "$S2C_C" 26.2 27.1 "S2C_C_area: flat lens area 2 int y dx = 26.667 to the display mesh's tessellation"
s2c_bbox "$S2C_C" "-0.01 0.01 -2.05 -1.95 -0.01 0.01 9.99 10.01 1.95 2.05 -0.01 0.01" "S2C_C_bbox: box is x 0..10 (the rails' meeting points), y +-2 (the rails' bulge), z = 0"
s2c_dists "$S2C_C" 3 "S2C_C_passthrough"
# (D) the same rails with three arched sections (control heights 1, 3, 1 -> arch heights 0.5, 1.5, 0.5)
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_D"; then s2c_ok "S2C_D_kernel: arched sections between touching rails reach the kernel"; else s2c_bad "S2C_D_kernel: arched sections on touching rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_D" 1e-3 "S2C_D_accuracy: sections reproduced below 1e-12, wall edges within the document tolerance of the rails"
s2c_bbox "$S2C_D" "-0.01 0.01 -2.05 -1.95 -0.01 0.01 9.99 10.01 1.95 2.05 1.4 1.6" "S2C_D_bbox: x 0..10, y +-2 and the middle section's arch height 3 / 2 = 1.5"
s2c_dists "$S2C_D" 3 "S2C_D_passthrough"
# (E) anchors that cross round the closed rails: refused with the reason, the old fit still builds
if grep -q "Sweep2: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep2Sections: the sections are not ordered consistently along the two rails (their anchors cross)); using the scaled-frame fit" <<<"$S2C_E" && grep -q "Sweep2: 3 section(s) along " <<<"$S2C_E"; then s2c_ok "S2C_E_refusal: crossing anchors round closed rails are refused with that reason and the old fit builds"; else s2c_bad "S2C_E_refusal: refusal text or fallback line missing"; fi
# (F) a long straight run into a tight bend: 128 stations leave the edges 0.0165 from the rails (kernel test), so the retry ladder must get to 256
if grep -q "Sweep2: exact kernel multi-section sweep (2 sections, 256 rail stations)" <<<"$S2C_F"; then s2c_ok "S2C_F_kernel: the straight-run-into-a-bend rails reach the kernel after the ladder 32, 64, 128 missed the tolerance (256 stations)"; else s2c_bad "S2C_F_kernel: expected the exact sweep at 256 stations"; fi
s2c_acc "$S2C_F" 1e-3 "S2C_F_accuracy: sections reproduced below 1e-12 and the wall edges within the document tolerance 0.001 of the rails at 256 stations"
s2c_bbox "$S2C_F" "-0.01 0.01 -0.01 0.01 -0.01 0.01 103.9 104.1 3.9 4.1 3.9 4.1" "S2C_F_bbox: box is the rails' extent x 0..104, y 0..4, z 0..4"
s2c_dists "$S2C_F" 2 "S2C_F_passthrough"
# (G) rails with a tangent jump: more stations cannot follow it, the miss is reported at 512 stations and the old fit builds
if grep -q "Sweep2: the exact multi-section sweep was not used (the wall edges are [0-9.e-]* from the rails at 512 stations (tolerance 0.001)); using the scaled-frame fit" <<<"$S2C_G" && grep -q "Sweep2: 2 section(s) along " <<<"$S2C_G"; then s2c_ok "S2C_G_miss: a tangent jump in the rails is a reported miss at 512 stations (not an exact sweep) and the old fit builds"; else s2c_bad "S2C_G_miss: miss reason or fallback line missing"; fi
S2C_N="$(grep -c "exact kernel multi-section sweep" <<<"$S2C" || true)"
if [ "$S2C_N" = "5" ]; then s2c_ok "S2C_count: exactly the five well-formed sweeps reached the kernel"; else s2c_bad "S2C_count: $S2C_N multi-section sweeps reached the kernel, expected 5"; fi

# TS3: ToNURBS of the cone's SubD (tosubd3_script.txt). The radius-4 cone's
# SubD used to be the 64-segment cage (960 faces): ToNURBS reported "closed
# solid: yes, manifold" but Volume then said "Object N is not closed" and
# printed 0, because the mesher could not weld the 64-segment cage's tiny cap
# patches (the apex is NOT the cause: a radius-2 cone, same apex, 32 segments,
# measures fine). The segment ladder now also tries 40 and 48 before 64, and
# the radius-4 cone verifies at 40 (380 faces). The last two blocks show what
# the SubD's own Volume is: the volume of the current CONTROL NET (an
# interpolated cage lies outside its limit surface), which falls onto the
# exact figure as the net is refined with SubDivide. Ranges, not exact
# numbers (deviation and volumes depend on the platform's float evaluation).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  TS3="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/tosubd3_script.txt" 2>&1)" || { echo "$TS3"; echo "FAIL: tosubd3 script exited non-zero"; exit 1; }
else
  TS3="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/tosubd3_script.txt" 2>&1)" || { echo "$TS3"; echo "FAIL: tosubd3 script exited non-zero"; exit 1; }
fi
ts3check() { if grep -q -- "$1" <<<"$TS3"; then echo "ok   $2"; else echo "FAIL $2"; near "$TS3" "$1"; fail=1; fi; }
# in range: ts3range VALUE LO HI DESC
ts3range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t TS3_TOSUBD < <(grep -F "history: ToSubD: created" <<<"$TS3" || true)
mapfile -t TS3_NURBS < <(grep -F "history: ToNURBS: watertight conversion" <<<"$TS3" || true)
mapfile -t TS3_LIST < <(grep -E "^history:   [0-9]+ faces, [0-9]+ edges, [0-9]+ vertices, [0-9]+ creases" <<<"$TS3" || true)
mapfile -t TS3_SOLID < <(grep -E "^history:   [0-9]+ faces, [0-9]+ edges, closed solid" <<<"$TS3" || true)
mapfile -t TS3_VOL < <(grep -o "Volume = [0-9.e+-]*" <<<"$TS3" | awk '{print $3}' || true)
TS3_NOTCLOSED="$(grep -c "is not closed" <<<"$TS3" || true)"
# ToSubD lines in script order: cone r4, cone r2, cylinder, TCone. Volumes: 0 cone r4 SubD, 1 cone r4 ToNURBS,
# 2 cone r2 ToNURBS, 3-6 cylinder after 0..3 SubDivide, 7-10 TCone after 0..3 SubDivide.
if [ "${#TS3_TOSUBD[@]}" -eq 4 ] && [ "${#TS3_NURBS[@]}" -eq 2 ] && [ "${#TS3_LIST[@]}" -eq 2 ] && [ "${#TS3_SOLID[@]}" -eq 2 ] && [ "${#TS3_VOL[@]}" -eq 11 ]; then
  echo "ok   tosubd3 script printed 4 ToSubD, 2 ToNURBS, 2 SubD List, 2 polysurface List lines and 11 volumes"
  if [ "$TS3_NOTCLOSED" = "0" ]; then echo "ok   no Volume reported \"is not closed\" (before: the radius-4 cone's ToNURBS polysurface did, and printed Volume = 0)"; else echo "FAIL $TS3_NOTCLOSED Volume line(s) reported \"is not closed\""; fail=1; fi
  if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.0[0-9]*)" <<<"${TS3_TOSUBD[0]}"; then
    ts3range "$(sed -E 's/.*worst measured deviation ([0-9.]+)\).*/\1/' <<<"${TS3_TOSUBD[0]}")" 0 0.001 "ToSubD of the radius-4 cone is VERIFIED: measured limit-surface deviation within the 0.001 tolerance"
  else
    echo "FAIL ToSubD of the radius-4 cone is not verified: ${TS3_TOSUBD[0]}"; fail=1
  fi
  if grep -q "analytic revolved-solid cage (4[08] segments around x [0-9]* along the wall, all-quad O-grid caps" <<<"${TS3_TOSUBD[0]}"; then
    echo "ok   the radius-4 cone verifies at 40 or 48 segments around (before: 64, whose cap patches the mesher could not weld)"
  else
    echo "FAIL the radius-4 cone does not use a 40/48-segment cage: ${TS3_TOSUBD[0]}"; fail=1
  fi
  read -r TS3F TS3E TS3V TS3C <<<"$(sed -E 's/^history: +([0-9]+) faces, ([0-9]+) edges, ([0-9]+) vertices, ([0-9]+) creases.*/\1 \2 \3 \4/' <<<"${TS3_LIST[0]}")"
  ts3range "$TS3F" 300 700 "the radius-4 cone cage has a few hundred faces (before: 960)"
  if [ "$((TS3V - TS3E + TS3F))" -eq 2 ]; then echo "ok   the radius-4 cone cage is a closed manifold: Euler $TS3V - $TS3E + $TS3F = 2"; else echo "FAIL the radius-4 cone cage Euler $TS3V - $TS3E + $TS3F != 2"; fail=1; fi
  ts3range "$TS3C" 80 200 "the radius-4 cone cage creases its rim and apex spokes"
  if grep -q "0 naked edge(s) left, closed solid: yes, manifold" <<<"${TS3_NURBS[0]}"; then echo "ok   ToNURBS of the radius-4 cone's SubD: 0 naked edges, closed manifold solid"; else echo "FAIL ToNURBS of the radius-4 cone: ${TS3_NURBS[0]}"; fail=1; fi
  ts3range "${TS3_VOL[1]}" 164.5 170.5 "ToNURBS of the radius-4 cone SubD: closed polysurface, Volume vs pi r^2 h / 3 = 167.55 (before: 'not closed', 0)"
  ts3range "${TS3_VOL[0]}" 163.5 172.0 "radius-4 cone SubD Volume (control net) vs 167.55"
  if grep -q "32 segments around" <<<"${TS3_TOSUBD[1]}" && grep -q "0 naked edge(s) left, closed solid: yes, manifold" <<<"${TS3_NURBS[1]}"; then
    echo "ok   the radius-2 cone (same apex, 32 segments) converts to a closed manifold solid: the apex is not the problem"
  else
    echo "FAIL the radius-2 cone: ${TS3_TOSUBD[1]} / ${TS3_NURBS[1]}"; fail=1
  fi
  ts3range "${TS3_VOL[2]}" 40.6 42.8 "ToNURBS of the radius-2 cone SubD: Volume vs pi r^2 h / 3 = 41.89"
  # Volume of a SubD is the volume of its control net: above the exact figure, falling onto it as the net is refined.
  if awk -v a="${TS3_VOL[3]}" -v b="${TS3_VOL[4]}" -v c="${TS3_VOL[5]}" -v d="${TS3_VOL[6]}" 'BEGIN { exit !(a > b && b > c && c >= d) }'; then
    echo "ok   cylinder SubD Volume falls monotonically as the net is refined: ${TS3_VOL[3]} > ${TS3_VOL[4]} > ${TS3_VOL[5]} >= ${TS3_VOL[6]}"
  else
    echo "FAIL cylinder SubD Volume is not monotone under SubDivide: ${TS3_VOL[3]} ${TS3_VOL[4]} ${TS3_VOL[5]} ${TS3_VOL[6]}"; fail=1
  fi
  ts3range "${TS3_VOL[3]}" 503.5 509.0 "cylinder cage (control net) Volume overshoots pi r^2 h = 502.65 (the cage lies outside the limit surface)"
  ts3range "${TS3_VOL[6]}" 502.0 503.3 "cylinder Volume after 3 SubDivide rounds converges onto pi r^2 h = 502.65"
  if awk -v a="${TS3_VOL[7]}" -v b="${TS3_VOL[8]}" -v c="${TS3_VOL[9]}" -v d="${TS3_VOL[10]}" 'BEGIN { exit !(a > b && b > c && c >= d) }'; then
    echo "ok   TCone SubD Volume falls monotonically as the net is refined: ${TS3_VOL[7]} > ${TS3_VOL[8]} > ${TS3_VOL[9]} >= ${TS3_VOL[10]}"
  else
    echo "FAIL TCone SubD Volume is not monotone under SubDivide: ${TS3_VOL[7]} ${TS3_VOL[8]} ${TS3_VOL[9]} ${TS3_VOL[10]}"; fail=1
  fi
  ts3range "${TS3_VOL[10]}" 292.5 294.0 "TCone Volume after 3 SubDivide rounds converges onto pi h (R^2 + R r + r^2) / 3 = 293.2"
else
  echo "FAIL tosubd3 script printed ${#TS3_TOSUBD[@]} ToSubD / ${#TS3_NURBS[@]} ToNURBS / ${#TS3_LIST[@]} SubD List / ${#TS3_SOLID[@]} polysurface List / ${#TS3_VOL[@]} Volume lines (expected 4 / 2 / 2 / 2 / 11)"; fail=1
fi
ts3check "gl_error=0" "tosubd3 script ran without OpenGL errors"

# SATF: ACIS SAT (.sat text) through Import/Export/Open/SaveAs (satf_script.txt,
# satf_bool_script.txt; io/FileSat.cpp over the kernel's clean-room reader and
# writer). The format support is self-consistent only - no real ACIS-written
# file was available - so these checks pin the app wiring and the honesty of the
# printed summary (verified vs UNVERIFIED layouts, refusals with a reason), not
# compatibility with another CAD system. Ranges, not exact numbers.
printf 'this is not an ACIS save file\n' > "$TMPW/satf_bad.sat"
sed "s|@TMP@|$TMPW|g" "$HERE/satf_script.txt" > "$TMPW/satf_script.txt"
sed "s|@TMP@|$TMPW|g" "$HERE/satf_bool_script.txt" > "$TMPW/satf_bool_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SATF="$(timeout 900 "$BIN" --smoke 40 --script "$TMPW/satf_script.txt" 2>&1)" || { echo "$SATF"; echo "FAIL: satf script exited non-zero"; exit 1; }
  SATFB="$(timeout 900 "$BIN" --smoke 40 --script "$TMPW/satf_bool_script.txt" 2>&1)" || { echo "$SATFB"; echo "FAIL: satf boolean script exited non-zero"; exit 1; }
else
  SATF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 40 --script "$TMPW/satf_script.txt" 2>&1)" || { echo "$SATF"; echo "FAIL: satf script exited non-zero"; exit 1; }
  SATFB="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 40 --script "$TMPW/satf_bool_script.txt" 2>&1)" || { echo "$SATFB"; echo "FAIL: satf boolean script exited non-zero"; exit 1; }
fi
satf_has() { if grep -qF -- "$1" <<<"$SATF"; then echo "ok   $2"; else echo "FAIL $2"; near "$SATF" "$1"; fail=1; fi; }
# count of lines containing a literal: satf_count TEXT MIN DESC
satf_count() { local n; n="$(grep -cF -- "$1" <<<"$SATF" || true)"; if [ "${n:-0}" -ge "$2" ]; then echo "ok   $3 ($n >= $2)"; else echo "FAIL $3 (got ${n:-0}, expected >= $2)"; near "$SATF" "$1"; fail=1; fi; }
satf_range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t SATF_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SATF" | awk '{print $3}' || true)
satf_has "SAT export satf_box.sat (ACIS 7.0 text, version 700): 1 of 1 object(s) written" "Export of a box to .sat wrote 1 of 1 objects and says ACIS 7.0 text"
satf_has "[documented layouts only]" "the box export is labelled as documented layouts only"
satf_has "SAT import satf_box.sat: 1 Brep body(ies) read" "Open of the .sat box read one Brep body"
satf_has "Every entity read uses a layout that public documentation states" "the box import says it used documented layouts only"
satf_has "closed solid" "the imported box is reported as a closed solid"
satf_count "no real ACIS-written file has been used to test it" 2 "every SAT summary carries the self-consistency-only note"
if [ "${#SATF_VOLS[@]}" -ge 4 ]; then
  satf_range "${SATF_VOLS[0]}" 3999.5 4000.5 "box Volume before export (20 x 20 x 10 = 4000)"
  satf_range "${SATF_VOLS[1]}" 3999.5 4000.5 "box Volume after .sat export and Open (4000)"
  satf_range "${SATF_VOLS[2]}" 2090 2160 "sphere Volume after .sat export and Import vs 4/3 pi r^3 = 2144.7 (it was 0 before the whole-sphere face was rebuilt as a native sphere)"
  satf_range "${SATF_VOLS[3]}" 770 800 "cylinder Volume after .sat export and Open vs pi r^2 h = 785.4"
else
  echo "FAIL satf script printed only ${#SATF_VOLS[@]} Volume lines (expected 4)"; fail=1
fi
satf_has "is a whole sphere face with no edges; it was rebuilt as the application's native sphere Brep" "a whole-sphere body from the file is rebuilt as the app's native sphere and the summary says so"
satf_count "UNVERIFIED LAYOUT: the bodies marked above" 2 "sphere and cylinder exports both disclose the UNVERIFIED layout"
satf_count "[UNVERIFIED cone/sphere/torus/ellipse layout]" 2 "...and mark the body line itself"
satf_has "SAT import satf_sphere.sat: 1 Brep body(ies) read" "Import of the .sat sphere read one body"
satf_count "UNVERIFIED LAYOUT: 1 of 1 bodies use cone/sphere/torus/ellipse entities" 2 "sphere and cylinder imports both disclose that they rest on UNVERIFIED layouts"
satf_has "SAT export wrote nothing" "exporting only a mesh writes nothing"
satf_has "SAT export writes Brep bodies only" "...and says why (no body representation for a mesh)"
satf_has "SAT import refused (satf_bad.sat)" "a file that is not an ACIS save file is refused with the file name"
# boolean result: reported honestly whichever way it goes
if grep -qF "SAT export satf_bool.sat (ACIS 7.0 text, version 700): 1 of 1 object(s) written" <<<"$SATFB"; then
  mapfile -t SATFB_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SATFB" | awk '{print $3}' || true)
  if [ "${#SATFB_VOLS[@]}" -ge 2 ]; then
    satf_range "${SATFB_VOLS[0]}" 2990 3010 "box with a 10 x 10 through-hole, BooleanDifference Volume (4000 - 1000 = 3000)"
    satf_range "${SATFB_VOLS[1]}" 2990 3010 "the same body after .sat export and Open (3000)"
  else
    echo "FAIL satf boolean script printed only ${#SATFB_VOLS[@]} Volume lines (expected 2)"; fail=1
  fi
  if grep -qF "SAT import satf_bool.sat: 1 Brep body(ies) read" <<<"$SATFB"; then echo "ok   the boolean result was read back as one Brep body"; else echo "FAIL the boolean result did not read back as one Brep body"; near "$SATFB" "SAT import"; fail=1; fi
else
  # the app's boolean result is not a Brep the SAT writer accepts: it must have said so with a reason
  if grep -qF "SAT export wrote nothing" <<<"$SATFB"; then echo "ok   the boolean result was refused by the SAT writer with a reason (see the output above)"; else echo "FAIL the boolean export neither wrote the body nor printed a refusal"; near "$SATFB" "SAT export"; fail=1; fi
fi

# ---------------------------------------------------------------------------
# History / associative re-execution, round 4 (H4R_): ExtrudeSrfAlongCrv, ExtrudeSrfTapered,
# ExtrudeSrfToPoint, Contour, Section and OffsetMultiple record construction history
# (tests/h4r_ext_script.txt), OffsetCrvOnSrf too (tests/h4r_offsrf_script.txt), and construction history survives Save / New / Open for a
# chain of every kind that has its own smoke script (tests/h4r_persist_script.txt).
# Part 1: with History On each result is recorded with the object it was swept or cut
# from; moving or scaling the source, or EditHistory on the numbers, rebuilds it with no
# UpdateHistory. Every rebuilt number is compared with the SAME operation performed fresh
# (History Off) on the edited source. Contour/Section record one result per piece and
# refuse (keeping the old curve) when the edited source meets the plane in a different
# number of pieces; a tessellated sphere's section chain can split at some planes (the
# fresh Contour command does too), so the sphere case only asserts that the sources were
# noticed and the four curves are still there.
# Part 2: one chain of each of 14 kinds (Sweep1 with two sections, non-planar Patch,
# FilletSrf, PlanarSrf -> ExtrudeSrf, Pipe, Loft, Revolve, Extrude, BooleanUnion, Offset,
# ExtrudeCrvTapered, NetworkSrf, OffsetSrf, ExtrudeCrvToPoint) is built, saved, the document
# is replaced by New and then Open, and only the SOURCES of each chain are moved +2 in Y:
# the result's bounding box must be its saved one shifted by (0,2,0). Revolve is the one
# kind whose axis is an independent pick that does not move with the profile (and
# ExtrudeCrvToPoint keeps its absolute apex), so Revolve is compared with a fresh revolve
# of the moved profile instead.
# Tolerances: tessellation-derived values (volume, length) are compared with ranges, as the
# Windows CI tessellates slightly differently.
# ---------------------------------------------------------------------------
H4R_DIR="$TMPW/h4r"
mkdir -p "$H4R_DIR"
h4r_run() {  # h4r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H4R_DIR|g" "$HERE/h4r_$1_script.txt" > "$H4R_DIR/h4r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H4R_DIR/h4r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H4R_DIR/h4r_$1_script.txt" 2>&1
  fi
}
h4r_len() { { grep -oE 'Total length = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Total length = //'; }
h4r_sl() { h2r_ok "$(h2r_closev "$(h4r_len "$1" "$2")" "$3" "$4")" "$5 (measured $(h4r_len "$1" "$2"), expected $3 +/- $4)"; }
# two measurements of the same kind agree: h4r_eqbb OUT i j tol label / h4r_eqlen OUT i j tol label / h4r_eqvol OUT i j tol label
h4r_eqbb() { h2r_ok "$(h2r_closebb "$(h2r_bb "$1" "$2")" "$(h2r_bb "$1" "$3")" "$4")" "$5 (rebuilt $(h2r_bb "$1" "$2") vs fresh $(h2r_bb "$1" "$3"))"; }
h4r_eqlen() { h2r_ok "$(h2r_closev "$(h4r_len "$1" "$2")" "$(h4r_len "$1" "$3")" "$4")" "$5 (rebuilt $(h4r_len "$1" "$2") vs fresh $(h4r_len "$1" "$3"))"; }
h4r_eqvol() { h2r_ok "$(h2r_closev "$(h2r_vol "$1" "$2")" "$(h2r_vol "$1" "$3")" "$4")" "$5 (rebuilt $(h2r_vol "$1" "$2") vs fresh $(h2r_vol "$1" "$3"))"; }
# bounding box i equals bounding box j shifted by (0,2,0)
h4r_shift2() {
  local a b; a="$(h2r_bb "$1" "$2")"; b="$(h2r_bb "$1" "$3")"
  h2r_ok "$(awk -v a="$a" -v b="$b" -v t="$4" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){ e=x[i]+((i==2||i==5)?2:0)-y[i]; if(e<0)e=-e; if(e>t){print 0; exit} } print 1 }')" "$5 (saved $a, after the sources moved +2 Y $b)"
}

# --- part 1: ExtrudeSrf* family, Contour, Section, OffsetMultiple
H4R_E="$(h4r_run ext)" || { echo "$H4R_E"; echo "FAIL: h4r ext script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_E" || { echo "$H4R_E"; echo "FAIL: h4r ext script produced no smoke line"; fail=1; }
h2r_has "$H4R_E" "object 9: ExtrudeSrfAlongCrv <- 1,2" "H4R_ext: ExtrudeSrfAlongCrv records the surface and the path curve"
h2r_has "$H4R_E" "object 10: ExtrudeSrfTapered <- 3  [distance=5, draft=5]" "H4R_ext: ExtrudeSrfTapered records the surface, the distance and the draft"
h2r_has "$H4R_E" "object 11: ExtrudeSrfToPoint <- 4  [apexx=45, apexy=5, apexz=10]" "H4R_ext: ExtrudeSrfToPoint records the surface and the apex"
h2r_has "$H4R_E" "object 12: Contour <- 5" "H4R_ext: every Contour piece records the contoured object"
h2r_has "$H4R_E" "object 15: Contour <- 5" "H4R_ext: ...all four pieces"
h2r_has "$H4R_E" "object 16: Section <- 6" "H4R_ext: Section records the sectioned object"
h2r_has "$H4R_E" "object 17: OffsetMultiple <- 7  [distance=2]" "H4R_ext: OffsetMultiple records the curve and the distance (one record per offset)"
h2r_count "$H4R_E" "14 object(s) with live construction history" 2 "H4R_ext: 14 recorded results before the edits and again after Open; the History Off controls added none"
# initial results
h2r_sb "$H4R_E" 1 "0,0,0,10,10,5" 0.05 "H4R_ext: ExtrudeSrfAlongCrv of a 10x10 plane along a 5 line (before)"
h2r_sh "$H4R_E" 1 500 1 "H4R_ext: ...volume 10*10*5 (before)"
h2r_sb "$H4R_E" 2 "20,0,0,30,10,5" 0.05 "H4R_ext: ExtrudeSrfTapered distance 5 draft 5 (before)"
h2r_sh "$H4R_E" 2 469.7 1.5 "H4R_ext: ...volume of the 5 degree taper (before)"
h2r_sb "$H4R_E" 3 "40,0,0,50,10,10" 0.05 "H4R_ext: ExtrudeSrfToPoint apex 10 above (before)"
h2r_sh "$H4R_E" 3 333.3 1 "H4R_ext: ...pyramid volume 100*10/3 (before)"
h4r_sl "$H4R_E" 1 159.9 1 "H4R_ext: Contour of a 10^3 box, 4 planes: total loop length 4*40 (before)"
h2r_sb "$H4R_E" 4 "60,0,1.25,70,10,8.75" 0.05 "H4R_ext: ...planes at z 1.25 .. 8.75 (before)"
h4r_sl "$H4R_E" 2 40 0.3 "H4R_ext: Section through the box at y=5: one 10x10 loop (before)"
h2r_sb "$H4R_E" 5 "80,5,0,90,5,10" 0.05 "H4R_ext: ...section bounding box (before)"
h4r_sl "$H4R_E" 3 20.88 0.6 "H4R_ext: OffsetMultiple 2 offsets x 2 of a curve (before)"
h2r_sb "$H4R_E" 6 "97.78,1.664,0,108.8,6.2,0" 0.15 "H4R_ext: ...offsets bounding box (before)"
# after the edits
h2r_sb "$H4R_E" 8 "3,0,0,13,10,10" 0.05 "H4R_ext: plane moved +3 X and path scaled 2x: the extrusion followed (x 3..13, height 10)"
h2r_sh "$H4R_E" 4 1000 2 "H4R_ext: ...volume 10*10*10"
h2r_has "$H4R_E" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (9)" "H4R_ext: moving the surface re-evaluates the extrusion automatically"
h2r_has "$H4R_E" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (9)" "H4R_ext: scaling the path re-evaluates it too"
h2r_has "$H4R_E" "EditHistory: object 10 (ExtrudeSrfTapered): distance 5 -> 8." "H4R_ext: EditHistory changes the taper distance"
h2r_has "$H4R_E" "EditHistory: object 10 (ExtrudeSrfTapered): draft 5 -> 10." "H4R_ext: ...and the draft"
h2r_sb "$H4R_E" 9 "20,4,0,30,14,8" 0.05 "H4R_ext: taper after plane moved +4 Y, distance 8, draft 10"
h2r_sh "$H4R_E" 5 651 3 "H4R_ext: ...volume"
h2r_has "$H4R_E" "EditHistory: object 11 (ExtrudeSrfToPoint): apexz 10 -> 20." "H4R_ext: EditHistory moves the apex"
h2r_sb "$H4R_E" 10 "40,2,0,50,12,20" 0.05 "H4R_ext: cone after plane moved +2 Y and apex raised to z 20"
h2r_sh "$H4R_E" 6 666.7 2 "H4R_ext: ...volume 100*20/3"
h2r_has "$H4R_E" "History: source object(s) 5 changed - 4 dependent(s) re-evaluated (12,13,14,15)" "H4R_ext: moving the contoured box re-evaluates all four contour curves"
h2r_sb "$H4R_E" 11 "65,3,1.25,75,13,8.75" 0.05 "H4R_ext: contours followed the box moved (+5,+3,+1) and stayed on their fixed planes"
h4r_sl "$H4R_E" 5 159.9 1 "H4R_ext: ...total length"
h2r_has "$H4R_E" "History: source object(s) 6 changed - 1 dependent(s) re-evaluated (16)" "H4R_ext: scaling the sectioned box re-evaluates the section"
h4r_sl "$H4R_E" 6 79.94 0.6 "H4R_ext: section of the box scaled 2x: one 20x20 loop"
h2r_sb "$H4R_E" 12 "80,5,0,100,5,20" 0.05 "H4R_ext: ...section bounding box"
h2r_has "$H4R_E" "History: source object(s) 7 changed - 2 dependent(s) re-evaluated (17,18)" "H4R_ext: scaling the curve re-evaluates both offsets"
h4r_sl "$H4R_E" 7 42.09 0.7 "H4R_ext: offsets of the curve scaled 2x"
h2r_sb "$H4R_E" 13 "97.78,1.664,0,118.8,9.2,0" 0.2 "H4R_ext: ...offsets bounding box"
h2r_has "$H4R_E" "History: source object(s) 8 changed" "H4R_ext: moving the contoured sphere is noticed"
h4r_sl "$H4R_E" 8 101.9 6 "H4R_ext: the sphere's four contour curves are all still there (pieces whose count changed kept as they were)"
# controls: the same operations fresh on the edited sources
h4r_eqbb "$H4R_E" 8 15 0.05 "H4R_ext control: fresh ExtrudeSrfAlongCrv bounding box"
h4r_eqvol "$H4R_E" 4 7 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 9 16 0.05 "H4R_ext control: fresh ExtrudeSrfTapered (distance 8, draft 10) bounding box"
h4r_eqvol "$H4R_E" 5 8 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 10 17 0.05 "H4R_ext control: fresh ExtrudeSrfToPoint (apex z 20) bounding box"
h4r_eqvol "$H4R_E" 6 9 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 11 18 0.05 "H4R_ext control: fresh Contour of the moved box bounding box"
h4r_eqlen "$H4R_E" 5 9 0.3 "H4R_ext control: ...total length"
h4r_eqbb "$H4R_E" 12 19 0.05 "H4R_ext control: fresh Section of the scaled box bounding box"
h4r_eqlen "$H4R_E" 6 10 0.3 "H4R_ext control: ...length"
h4r_eqbb "$H4R_E" 13 20 0.1 "H4R_ext control: fresh OffsetMultiple of the scaled curve bounding box"
h4r_eqlen "$H4R_E" 7 11 0.3 "H4R_ext control: ...total length"
# negative control: the contour planes no longer meet the box
h2r_has "$H4R_E" "History: source object(s) 5 changed - 0 dependent(s) re-evaluated, 4 kept as they were" "H4R_ext: the box moved +20 Z leaves every contour plane: no rebuild, all four kept"
h2r_has "$H4R_E" "the edited source now meets the plane in 0 piece(s), it gave 1 when this result was made; kept as it was" "H4R_ext: ...with the reason"
h4r_eqbb "$H4R_E" 21 11 0.05 "H4R_ext: the kept contours did not move"
h4r_eqlen "$H4R_E" 12 5 0.01 "H4R_ext: ...nor change length"
h4r_eqbb "$H4R_E" 22 11 0.05 "H4R_ext: the box moved back: the contours are rebuilt again, equal to before"
# Save, New, Open
h2r_has "$H4R_E" "object 10: ExtrudeSrfTapered <- 3  [distance=8, draft=10]" "H4R_ext: after Save/New/Open the taper record (with the EditHistory'd numbers) is read back from the .3dm"
h2r_has "$H4R_E" "object 11: ExtrudeSrfToPoint <- 4  [apexx=45, apexy=5, apexz=20]" "H4R_ext: ...the apex record"
h2r_sb "$H4R_E" 23 "3,5,0,13,15,10" 0.05 "H4R_ext: reopened, plane moved +5 Y: the extrusion followed"
h2r_sh "$H4R_E" 10 1000 2 "H4R_ext: ...volume"
h2r_sb "$H4R_E" 24 "65,4,1.25,75,14,8.75" 0.05 "H4R_ext: reopened, box moved +1 Y: the contours followed"
h4r_sl "$H4R_E" 14 159.9 1 "H4R_ext: ...total length"
h4r_eqbb "$H4R_E" 25 6 0.1 "H4R_ext: reopened, curve scaled back to its first size: the offsets are the first ones again"
h4r_eqlen "$H4R_E" 15 3 0.1 "H4R_ext: ...length"
h4r_eqbb "$H4R_E" 26 5 0.05 "H4R_ext: reopened, box scaled back: the section is the first one again"
h4r_eqlen "$H4R_E" 16 2 0.1 "H4R_ext: ...length"
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_E" && echo 1 || echo 0)" "H4R_ext: ran without OpenGL errors"

# --- part 2: history survives Save / New / Open for 14 construction kinds
H4R_P="$(h4r_run persist)" || { echo "$H4R_P"; echo "FAIL: h4r persist script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_P" || { echo "$H4R_P"; echo "FAIL: h4r persist script produced no smoke line"; fail=1; }
h2r_count "$H4R_P" "17 object(s) with live construction history" 2 "H4R_persist: 17 recorded results before Save and again after New + Open"
for rec in "object 4: Sweep1 <- 1,2,3" "object 14: Patch <- 5,6,7,8,9,10,11,12,13" "object 17: FilletSrf <- 15,16" "object 20: ExtrudeSrf <- 19" "object 22: Pipe <- 21" "object 26: Loft <- 23,24,25" "object 28: Revolve <- 27" "object 35: BooleanUnion <- 33,34" "object 37: Offset <- 36" "object 39: ExtrudeCrvTapered <- 38" "object 42: NetworkSrf2 <- 40,41" "object 44: OffsetSrf <- 43" "object 46: ExtrudeCrvToPoint <- 45"; do
  h2r_count "$H4R_P" "$rec" 2 "H4R_persist: record '$rec' listed before Save and again after Open"
done
h2r_count "$H4R_P" "dependent(s) re-evaluated" 14 "H4R_persist: after Open each of the 14 chains' source edits re-evaluated its dependents"
h2r_countre "$H4R_P" "kept as they were:" 0 "H4R_persist: no rebuild was refused"
H4R_NAMES=(Sweep1 Patch FilletSrf "PlanarSrf+ExtrudeSrf" Pipe Loft Revolve Extrude BooleanUnion Offset ExtrudeCrvTapered NetworkSrf OffsetSrf ExtrudeCrvToPoint)
for k in $(seq 1 14); do
  nm="${H4R_NAMES[$((k - 1))]}"
  if [ "$k" = "7" ]; then
    h4r_eqbb "$H4R_P" 21 29 0.05 "H4R_persist: $nm: after Open the profile moved +2 Y: the revolve about the fixed axis equals a fresh revolve of the moved profile"
    h2r_ok "$(awk -v a="$(h2r_bb "$H4R_P" 7)" -v b="$(h2r_bb "$H4R_P" 21)" 'BEGIN{ n=split(a,x,","); split(b,y,","); for(i=1;i<=n;i++){ d=x[i]-y[i]; if(d<0)d=-d; if(d>0.1){print 1; exit} } print 0 }')" "H4R_persist: $nm: ...and it did change from the saved result (the rebuild ran)"
  else
    h4r_shift2 "$H4R_P" "$k" "$((14 + k))" 0.05 "H4R_persist: $nm: after Open the sources moved +2 Y: the rebuilt result is the saved one shifted (0,2,0)"
  fi
done
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_P" && echo 1 || echo 0)" "H4R_persist: ran without OpenGL errors"

# --- part 3: OffsetCrvOnSrf (h4r_offsrf_script.txt)
H4R_O="$(h4r_run offsrf)" || { echo "$H4R_O"; echo "FAIL: h4r offsrf script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_O" || { echo "$H4R_O"; echo "FAIL: h4r offsrf script produced no smoke line"; fail=1; }
h2r_has "$H4R_O" "object 3: OffsetCrvOnSrf <- 2,1  [distance=3]" "H4R_offsrf: OffsetCrvOnSrf records the curve, the surface and the distance"
h2r_sb "$H4R_O" 1 "2,8,0,18,8,0" 0.05 "H4R_offsrf: the 16-long line at y=5 offset by 3 along the surface (before)"
h4r_sl "$H4R_O" 1 16 0.1 "H4R_offsrf: ...length (before)"
h2r_has "$H4R_O" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (3)" "H4R_offsrf: moving the curve re-evaluates the offset automatically"
h2r_sb "$H4R_O" 2 "2,12,0,18,12,0" 0.05 "H4R_offsrf: curve moved +4 Y: the offset followed (y=9+3)"
h2r_has "$H4R_O" "EditHistory: object 3 (OffsetCrvOnSrf): distance 3 -> -2." "H4R_offsrf: EditHistory changes the distance"
h2r_sb "$H4R_O" 3 "2,7,0,18,7,0" 0.05 "H4R_offsrf: ...the offset is now on the other side (y=9-2)"
h4r_eqbb "$H4R_O" 3 4 0.05 "H4R_offsrf control: the same offset performed fresh (History Off) on the moved curve has the same bounding box"
h4r_eqlen "$H4R_O" 3 4 0.05 "H4R_offsrf control: ...and the same length"
h2r_has "$H4R_O" "object 3: OffsetCrvOnSrf <- 2,1  [distance=-2]" "H4R_offsrf: after Save/New/Open the record (with the EditHistory'd distance) is read back from the .3dm"
h2r_sb "$H4R_O" 5 "2,9,0,18,9,0" 0.05 "H4R_offsrf: reopened, curve moved +2 Y more: the offset followed (y=11-2)"
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_O" && echo 1 || echo 0)" "H4R_offsrf: ran without OpenGL errors"

# ---------------------------------------------------------------------------
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
frhcheck F_toobig "(mesh)" "...and the old approximate path still runs"
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

exit $fail
