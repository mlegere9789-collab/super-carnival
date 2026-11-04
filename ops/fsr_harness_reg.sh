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
HERE="/home/user/miniature-pancake/.claude/worktrees/agent-a102f7e751a3e860d/dino8-app/tests"
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
# Surfaces: Pipe, OffsetSrf, Shell, Sweep1/2, NetworkSrf, Patch, ExtrudeCrvAlongCrv,
# ExtrudeCrvTapered, Project, Pull (see surface_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SF="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/surface_script.txt" 2>&1)" || { echo "$SF"; echo "FAIL: surface script exited non-zero"; exit 1; }
else
  SF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/surface_script.txt" 2>&1)" || { echo "$SF"; echo "FAIL: surface script exited non-zero"; exit 1; }
fi
sfcheck() { if echo "$SF" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SF" "$1"; fail=1; fi; }
sfcheck "Pipe: radius 1, 1 pipe(s) (exact capped B-rep)" "Pipe on an open rail now calls the kernel's exact Brep::Pipe instead of building a mesh"
sfcheck "Volume = 31.29 cubic" "Pipe r=1 along 10 units has volume ~ pi*10 (closer than the old mesh's 31.06, read from the exact B-rep's own tessellation)"
sfcheck "Area = 62.79 square" "uncapped Pipe surface area ~ 2*pi*10"
sfcheck "degree 3 x 1, CVs 27 x 2" "uncapped Pipe is a periodic NURBS tube"
sfcheck "Bounding box min 20,0,-2 max 30,10,-2" "OffsetSrf moved the plane by 2 along its normal"
sfcheck "Volume = 200 cubic" "OffsetSrf Solid=Yes closed a 10x10x2 slab"
sfcheck "Shell: thickness 1, closed, exact B-rep, volume 1408" "Shell hollowed the box (4000 - 18*18*8) via the kernel's exact ShellConvexPlanar, not the mesh path"
sfcheck "ExtrudeCrvAlongCrv: 1 surface(s)" "ExtrudeCrvAlongCrv built a sum surface"
sfcheck "Sweep1: exact kernel sweep (rotation-minimizing frames)" "Sweep1's single-section case now calls the kernel's exact Brep::Sweep1"
sfcheck "Area = 125.6 square" "Sweep1 area ~ 2*pi*2*10 (kernel's exact NURBS circle reused directly, not a resampled fit)"
sfcheck "Sweep2: exact kernel sweep (two-rail frame transport)" "Sweep2's single-section case now calls the kernel's exact Brep::Sweep2"
sfcheck "NetworkSrf: exact Coons patch through 4 curves (all 4 boundaries reproduced exactly)" "NetworkSrf sorted 4 curves into a loop and built the kernel's exact Coons patch (real NURBS algebra, not the sample-and-refit approximation)"
sfcheck "NetworkSrf: ruled surface between 2 curves" "NetworkSrf ruled two curves"
sfcheck "Patch: planar face bounded by the closed curve" "Patch trimmed a plane with the circle"
sfcheck "Area = 78.51 square" "Patch disc area ~ pi*25"
sfcheck "Patch: least-squares plane through 0 curve(s) and 3 point(s)" "Patch fitted a plane through points"
sfcheck "ExtrudeCrvTapered: distance 5, draft 10 deg, 1 object(s)" "ExtrudeCrvTapered ran"
sfcheck "3 faces, 3 edges, closed solid" "ExtrudeCrvTapered capped and joined into a closed solid (wall + 2 planar trimmed cap faces; the cap loops share the wall seam, so 3 edges, where the old fan caps needed 5)"
sfcheck "Project: 1 curve(s), 0 point(s)" "Project produced one curve"
sfcheck "CV\[1\] 240,20,0" "Project landed the line on the plane"
if [ "$(echo "$SF" | grep -c "CV\[1\] 240,20,0")" -eq 2 ]; then echo "ok   Project with an explicit custom direction (two typed points, +Z) lands on the exact same result as the CPlane-normal default - the real \"no way to choose a direction\" gap this command's own PARITY_MAP bullet named is now closed"; else echo "FAIL Project with an explicit custom direction (two typed points, +Z) lands on the exact same result as the CPlane-normal default"; near "$SF" "CV\[1\] 240,20,0"; fail=1; fi
sfcheck "Pull: 0 curve(s), 1 point(s)" "Pull produced one point"
sfcheck "  225,5,0" "Pull moved the point onto the plane"
# Shell (open): picking the top face before entering thickness removes that
# face's own wall layer from the result rather than producing another
# fully-closed solid - real material gone, not a cosmetic label. The result
# is still a single valid closed 2-manifold (a real opening is a cavity
# reachable through empty space, not a literal hole in the mesh - the same
# reason a 3D-printable mug's own mesh has no naked edges either), so the
# proof is the exact Volume/Area/BoundingBox difference from the closed case
# above, not IsClosedManifold()/SelOpenMesh.
sfcheck "Shell: face 5 on object" "Shell registered the clicked top face to remove"
sfcheck "Shell: thickness 1, open (1 face(s) removed), exact B-rep, volume 1084" "Shell (open) is now the kernel's exact ShellConvexPlanar with the clicked top face removed (a real polysurface, no longer the welded mesh): volume 1408 - 18*18*1 = 1084"
sfcheck "Area = 2248 square" "Shell (open) area matches the outer+inner+rim geometry exactly (all flat, no curvature error)"
sfcheck "Bounding box min 300,0,0 max 320,20,10" "Shell (open) left the outer wall's own bounding box untouched"
sfcheck "Volume = 1084 cubic" "Shell (open) volume is exactly the closed shell's 1408 minus the removed top layer's own 18x18x1"
# Shell (per-face thickness): no face removed, but the top face is given
# its own thickness of 3 while every other face keeps the default 1 - a
# real different-thickness-per-face wall, not just a global number. The
# per-vertex offset solve (OffsetMeshPerFace) makes each kept face's own
# vertices hit the exact intersection of its neighbours' own offset planes,
# so a box's orthogonal faces still meet in clean corners even though two
# of them moved by different amounts; proved numerically by hand below.
sfcheck "Shell: face 5 on object" "Shell registered the clicked top face for its own thickness"
sfcheck "set to thickness 3" "the top face's override was recorded as 3"
sfcheck "Shell: thickness 1, 1 face(s) at their own thickness, closed, exact B-rep, volume 2056" "Shell (per-face) is now one exact B-rep shell (kernel ShellConvexPlanar with a per-face thickness array) with a mixed-thickness wall"
sfcheck "Area = 2680 square" "Shell (per-face) area matches outer 1600 + inner 1080 (two disjoint nested boxes, no boolean rework needed)"
sfcheck "Bounding box min 340,0,0 max 360,20,10" "Shell (per-face) left the outer wall's own bounding box untouched"
sfcheck "Volume = 2056 cubic" "Shell (per-face) volume is exactly 4000 - 18*18*6 (inner box shrunk to height 6 by the top face's own thickness 3, not the default 1) - 648 less material removed than the same box's uniform thickness-1 shell above (1408), i.e. 1408 + 18*18*2 = 2056"
# OffsetSrf on a polysurface (Solid=No): the kernel's exact
# OffsetSolidConvexPlanar now takes this case directly for a convex,
# all-planar-faced solid - a real polysurface result, not a tessellated
# mesh, closing PARITY_MAP.md's own "OffsetSrf on polysurfaces gives
# meshes" gap for this common case. OffsetSrf keeps the original box as
# its own separate object (same as it already does for a plain
# Surface), so List on the new result alone (SelLast) is what proves
# the kind, not SelPolysrf (which would also catch the untouched
# original box).
sfcheck "6 faces, 12 edges, closed solid" "OffsetSrf on a polysurface (Solid=No) produced a real polysurface - the kernel's exact OffsetSolidConvexPlanar, not the mesh-offset fallback"
sfcheck "Volume = 5808 cubic" "OffsetSrf on a polysurface (Solid=No) grew a 20x20x10 box by 1 on every face via the kernel's exact OffsetSolidConvexPlanar, giving the exact closed-form volume of a 22x22x12 box"
sfcheck "Bounding box min 439,-1,-1 max 461,21,11" "OffsetSrf on a polysurface moved every one of the box's own 6 planar faces outward by exactly 1, not an approximate vertex-normal mesh offset"
sfcheck "smoke: frames=200 objects=50" "surface script produced the expected object count"
# Kernel primitives reached from the app commands (kernel_wiring_script.txt):
# MergeSrf -> NurbsSurface::Join (exact control-net splice, 7x4 for a bicubic
# split at 0.4, instead of a 25x17 sample-and-refit), ChamferEdge/ChamferSrf
# on a cylinder rim -> ChamferCylinderRim (exact cone, unequal distances,
# re-closed into a true 4-face/7-edge solid), and the curve MakeUniform ->
# NurbsCurve::MakeUniform (domain-preserving, deviation-gated). The second half
# of the same script proves the section-anchored single-section Sweep1/Sweep2
# (a section anywhere along the rail is reproduced exactly and the surface
# covers the whole rail - the kernel call alone carried it rigidly from the
# rail start) and the exact interpolating Loft (every section reproduced,
# curves reversed/re-seamed first, capped solids, mixed open/closed refused).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  KW="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/kernel_wiring_script.txt" 2>&1)" || { echo "$KW"; echo "FAIL: kernel-wiring script exited non-zero"; exit 1; }
else
  KW="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/kernel_wiring_script.txt" 2>&1)" || { echo "$KW"; echo "FAIL: kernel-wiring script exited non-zero"; exit 1; }
fi
kwcheck() { if grep -q "$1" <<<"$KW"; then echo "ok   $2"; else echo "FAIL $2"; near "$KW" "$1"; fail=1; fi; }
kwcount() { local n; n="$(grep -c "$1" <<<"$KW" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$KW" "$1"; fail=1; fi; }
echo "$KW" | grep -E "^(ok|FAIL)"
if grep -q "^FAIL" <<<"$KW"; then fail=1; fi
kwcheck "^ok   expect_objects 4" "kernel-wiring script: the merged surface is the only surface left (plus the three boxes BoundingBox leaves behind)"
kwcheck "^ok   expect_objects 0 (got 0)" "kernel-wiring script ended with every section's own objects cleaned up"
kwcheck "MergeSrf: merged 2 surfaces into one (exact merge: control nets spliced across the shared edge, 7 x 4 control points, no refit)" "MergeSrf on the two halves SplitFace cut from a non-planar bicubic reaches kernel NurbsSurface::Join and says so: an exact merge, not '(refit through samples)'"
kwcheck "degree 3 x 3, CVs 7 x 4" "the merged surface's control net is exactly 7 x 4 (two 4x4 halves sharing one boundary row), not the 25 x 17 sample grid the old refit built"
kwcount "Bounding box min 0,0,0 max 9,9,3" 3 "the original bicubic, its two halves and the merged surface all report the identical bounding box"
kwcount "Area = 84.57 square" 3 "...and the identical area (84.57): the exact merge reproduces the original surface"
kwcheck "! MergeSrf: the surfaces do not share an edge" "MergeSrf on two planes with no shared edge is still refused with the original diagnostic after the Join attempt throws"
# MergeSrf compatible-form merges: pairs that are NOT already in splice-ready form
# (degree mismatch, different knot spacing along the edge, edge walked in opposite
# directions) now still merge exactly instead of dropping to the sample-and-refit;
# the refit survives only for the one pair whose edge is parameterized differently.
kwcount "exact merge: control nets spliced across the shared edge, 7 x 4 control points, no refit)" 2 "MergeSrf on a bicubic + a biquadratic patch sharing an edge merges exactly into a 7 x 4 net (the second 7 x 4 besides the SplitFace halves above): the lower degree is raised in both directions instead of refitting"
kwcheck "made the pair compatible along the shared edge first (.*degree along the shared edge 2 -> 3.*degree across the shared edge 2 -> 3); the merged surface reproduces both inputs to" "...and says what it did: the quadratic patch's degree raised 2 -> 3 along and across the edge, the result reproducing both inputs"
kwcheck "exact merge: control nets spliced across the shared edge, 7 x 7 control points, no refit)" "MergeSrf on two bicubics whose shared edge carries different knots (interior knot at 1/2 vs 1/3 and 2/3) merges exactly into a 7 x 7 net: the union {1/3, 1/2, 2/3} inserted into both"
kwcheck "inserted 2 knot(s) along the shared edge into the .* surface" "...and reports the two knots it inserted into one patch"
kwcheck "inserted 1 knot(s) along the shared edge into the .* surface" "...and the one knot it inserted into the other"
kwcheck "exact merge: control nets spliced across the shared edge, 4 x 7 control points, no refit)" "MergeSrf on two bicubics meeting along y = 3 with one of them Flip'd (so they walk the shared edge in opposite directions) merges exactly into a 4 x 7 net"
kwcheck "reversed the second surface along the shared edge so both run the same way" "...and reports turning the second patch back along the edge"
kwcheck "swapped the second surface's U and V so its shared edge is a U side" "...and swapping its U/V (the shared edge sits on a V side of the second patch)"
kwcount "refit through samples" 1 "the sample-and-refit fallback ran exactly once in the whole kernel-wiring script: the three compatible-form merges above did NOT fall back to it"
kwcheck "refit through samples; the exact kernel merge refused this pair: the two surfaces do not share an edge (closest pair of sides 0.05" "the one pair that still refits (a shared segment traced with a different parameterization, 0.05 apart) says WHY the exact merge refused it"
# Rim chamfers: Volume lines in order = plain cylinder, ChamferEdge top rim
# 0.6/0.4, swapped 0.4/0.6, bottom rim 0.6/0.4, ChamferSrf 0.5, Distance/Angle refusal.
KW_VOLS="$(echo "$KW" | grep -o "Volume = [0-9.]* cubic" | awk '{printf "%s ", $3}')"
if echo "$KW_VOLS" | awk 'function abs(x) { return x < 0 ? -x : x } { exit !(abs($1-62.7)<0.03 && abs($2-61.3)<0.03 && abs($3-61.35)<0.03 && abs($4-61.3)<0.03 && abs($5-61.26)<0.03 && abs($6-60.75)<0.15) }'; then
  echo "ok   cylinder rim volumes read 62.7 (plain), 61.3 (top 0.6/0.4), 61.35 (swapped 0.4/0.6), 61.3 (bottom rim), 61.26 (ChamferSrf 0.5), 60.75 (Angle 45 / 0.6: CHANGED PIN, KWR wiring - was 62.7, refused and untouched; Pappus 62.83 - 2*pi*1.8*0.18 = 60.79)"
else
  echo "FAIL cylinder rim volumes unexpected: $KW_VOLS"; fail=1
fi
if echo "$KW_VOLS" | awk 'function abs(x) { return x < 0 ? -x : x }
  function rem(dw, dc,   R) { R = 2; return (2 * 3.14159265358979 * dw / dc) * (R * R * R / 3 - (R - dc) * R * R / 2 + (R - dc) ^ 3 / 6) }
  { exit !(abs(($1 - $2) - rem(0.6, 0.4)) < 0.05 && abs(($1 - $3) - rem(0.4, 0.6)) < 0.05 && abs(($1 - $4) - rem(0.6, 0.4)) < 0.05 && abs(($1 - $5) - rem(0.5, 0.5)) < 0.01) }'; then
  echo "ok   the volume each rim chamfer removes matches the revolved-triangle closed form (2*pi*dw/dc)*(R^3/3-(R-dc)*R^2/2+(R-dc)^3/6): 1.407 (0.6/0.4), 1.357 (0.4/0.6), 1.440 (0.5/0.5)"
else
  echo "FAIL rim chamfer removed volumes do not match the closed form: $KW_VOLS"; fail=1
fi
kwcheck "ChamferEdge: edge .* of object .* replaced with an exact chamfer (distance1 0.6, distance2 0.4; exact cone on the cylinder rim" "ChamferEdge Distance1=0.6 Distance2=0.4 on a cylinder rim reaches kernel::ChamferCylinderRim (wall 0.6 / cap 0.4)"
kwcheck "ChamferEdge: edge .* of object .* replaced with an exact chamfer (distance1 0.4, distance2 0.6; exact cone on the cylinder rim" "...and the swapped distances are a different, equally exact chamfer"
kwcheck "ChamferSrf: faces .* and .* of object .* replaced with an exact chamfer (distance 0.5; exact cone on the cylinder rim)" "ChamferSrf on a cylinder's cap and wall now reaches the exact cone instead of the approximate 'contact points off by' ruled surface"
kwcount "4 faces, 7 edges, closed solid" 4 "every rim chamfer (top, bottom, ChamferSrf, and since the KWR wiring the Distance/Angle bevel: count was 3) is a true closed 4-face/7-edge solid with exact circular caps, not the kernel's raw 261-edge open polygon shell"
kwcheck "Area = 84.01 square" "the top-rim chamfer's area (84.01) matches the closed form 2*pi*R*(L-dw)+pi*R^2+pi*(R-dc)^2+pi*(2R-dc)*sqrt(dw^2+dc^2) = 84.056 to the display mesh's 0.05"
kwcheck "ChamferSrf: built between object .* and .*, radius 3" "a ChamferSrf cap setback of 3 on the R=2 cylinder is refused by the kernel and falls through to the approximate surface exactly as before"
kwcheck "ChamferEdge: edge .* of object .* replaced with an exact chamfer (distance1 0.6, angle 45 degrees from face 1; exact kernel cap-rim bevel (cone), distance 0.6 across the cap, 45 degrees from the cap plane)" "ChamferEdge Angle= on a cylinder rim is now an exact kernel::ChamferCapRimAngle bevel (CHANGED PIN, KWR wiring: it used to be refused with 'cylinder-rim attempt: Distance/Angle mode has no cylinder-rim construction' and leave the cylinder untouched)"
# Curve MakeUniform
kwcheck "! MakeUniform: curve .* left unchanged - uniform knots would move it by up to 0.5, more than Tolerance 0.001" "curve MakeUniform at the default (document) Tolerance refuses a re-knot that would move the curve 0.5 and reports the measured 0.5 - the old call shipped it unmeasured"
kwcheck "! MakeUniform: curve .* left unchanged - uniform knots would move it by up to 0.5, more than Tolerance 0.4" "...and Tolerance=0.4 still refuses (0.5 > 0.4)"
kwcheck "MakeUniform: 1 curve(s) now have uniform knots (largest measured shape change 0.5, domain preserved)" "Tolerance=0.6 commits, reporting the exact closed-form 0.5 shift"
kwcount "Curve .* domain: 0 to 1" 3 "the curve's domain is 0 to 1 before, after the refused runs and after the committed re-knot (the old call re-domained it to 0 to 2)"
kwcheck "MakeUniform: 0 curve(s) now have uniform knots; 1 already uniform" "a second MakeUniform finds the curve already uniform (NoOpAlreadySatisfied) and changes nothing"

# Surface construction commands (last section of kernel_wiring_script.txt):
# NetworkSrf with 3 curves -> NurbsSurface::CoonsPatchTriangular (closure
# against the DOCUMENT tolerance, order/direction resolved, measured boundary
# deviation printed, old fitted patch kept as the printed fail-open path),
# Sweep2 with several cross-sections -> Brep::Sweep2Sections, and Patch of
# non-planar data -> NurbsSurface::FitPatch + Brep::TrimmedPatchFace. Everything
# below is read only from this section's own output (from its first NetworkSrf
# on), so the earlier sections' areas and boxes cannot satisfy these.
KW3="$(echo "$KW" | sed -n '/Command: NetworkSrf/,$p')"
kw3check() { if echo "$KW3" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$KW3" "$1"; fail=1; fi; }
kw3count() { local n; n="$(echo "$KW3" | grep -c "$1" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$KW3" "$1"; fail=1; fi; }
kw3count "NetworkSrf: exact 3-sided Coons patch through 3 curves (all 3 boundaries reproduced exactly)" 3 "NetworkSrf with exactly 3 curves reaches the kernel's CoonsPatchTriangular three times (scrambled straight triangle, curved out-of-plane third edge, open corner inside tolerance) and says so"
kw3check "Area = 50 square" "the scrambled straight triangle (two edges drawn the wrong way round) gives the closed-form area 50 of the triangle (0,0) (10,0) (10,10)"
KW3_DEVS="$(echo "$KW3" | grep -o "measured boundary deviation from the closed loop [0-9.e-]*" | awk '{print $NF}')"
if [ "$(echo "$KW3_DEVS" | wc -l)" = "4" ] && echo "$KW3_DEVS" | awk '{ if ($1 + 0 > 1e-12) bad = 1 } END { exit bad }'; then
  echo "ok   all 4 exact Coons results (3 triangular + 1 four-curve) print a MEASURED boundary deviation from their closed loop below 1e-12 (got: $(echo $KW3_DEVS))"
else
  echo "FAIL the exact Coons boundary deviations are not all 4 values below 1e-12: $KW3_DEVS"; fail=1
fi
kw3check "corners closed within the document tolerance 0.001 (largest gap 0.0005 split between the two ends)" "a 3-curve loop open by 0.0005 is closed against the document tolerance 0.001 (ends moved to their midpoint) and still gets the exact patch"
kw3check "NetworkSrf: exact Coons patch through 4 curves (all 4 boundaries reproduced exactly), corners closed within the document tolerance 0.001 (largest gap 0.0004" "...and so does a 4-curve loop open by 0.0004"
kw3check "NetworkSrf: fitted bilinear Coons patch through 3 curves (approximate fallback: the 3 curves do not close into a loop within the document tolerance 0.001 (largest corner gap 0.5))" "a 3-curve set open by 0.5 is NOT a loop: the old fitted patch runs and the printed reason is the measured gap against the tolerance"
kw3count "fitted bilinear Coons patch" 1 "the old fitted bilinear Coons patch ran exactly once in the section: the four loops above did not fall back to it"
# Sweep2, several cross-sections
kw3check "Sweep2: exact kernel multi-section sweep (3 sections, 33 rail stations); measured: sections reproduced to [0-9.e-]*, wall edges within [0-9.e-]* of the rails; document tolerance 0.001" "Sweep2 with 3 cross-sections between straight diverging rails reaches the kernel's Brep::Sweep2Sections and prints its measured accuracy"
kw3count "Area = 57.55 square" 2 "the 3-section wall and the one-section exact Brep::Sweep2 wall (same rails, first section only) have the identical area 57.55 - three same-shaped sections reduce to the one-section sweep"
kw3check "Bounding box min 0,0,0 max 6,1.5,10" "the 3-section wall's box is the closed form: x to 6 (the far rail), y to 1.5 (apex of the z = 10 arc, control height 3), z to 10"
kw3check "Sweep2: exact kernel sweep (two-rail frame transport)" "the one-section comparison sweep still takes the existing exact Brep::Sweep2 path"
KW3_SW="$(echo "$KW3" | grep -o "(3 sections, 32 rail stations); measured: sections reproduced to [0-9.e-]*, wall edges within [0-9.e-]* of the rails" | head -1)"
if [ -n "$KW3_SW" ] && echo "$KW3_SW" | awk '{ s = $10; e = $14; exit !(s + 0 < 1e-12 && e + 0 < 1e-4) }'; then
  echo "ok   Sweep2 on cubic rails with three different sections: sections reproduced below 1e-12 and wall edges within 1e-4 of the rails, measured by the kernel ($KW3_SW)"
else
  echo "FAIL Sweep2 on cubic rails: accuracy line missing or out of bounds: $KW3_SW"; fail=1
fi
kw3check "Sweep2: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep2Sections: the sections are not ordered consistently along the two rails (their anchors cross)); using the scaled-frame fit" "Sweep2 with two sections whose anchors cross is refused by the kernel, the reason is printed and the scaled-frame fit takes over"
kw3check "Sweep2: 2 section(s) along 2 rail stations" "...and that fallback still builds its surface exactly as before"
kw3count "Sweep2: exact kernel multi-section sweep" 2 "exactly the two well-formed multi-section sweeps (straight and cubic rails) reached the kernel"
# Patch, non-planar data
kw3count "Patch: non-planar data - kernel least-squares NURBS" 2 "exactly two Patch inputs reached the kernel's least-squares fit: the closed saddle curve and the nine non-coplanar points"
kw3check "Patch: non-planar data - kernel least-squares NURBS patch (5 x 5 net, worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1.5) trimmed by the closed curve; the face's edge is within [0-9.e-]* of the curve" "Patch of a closed saddle-shaped curve (best-fit plane misses it by 1.5) fits a 5 x 5 NURBS patch within the tolerance and trims it by the curve"
KW3_PATCH="$(echo "$KW3" | grep -o "worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1.5) trimmed by the closed curve; the face's edge is within [0-9.e-]* of the curve" | head -1)"
if [ -n "$KW3_PATCH" ] && echo "$KW3_PATCH" | awk '{ d = $4; e = $(NF-3); exit !(d + 0 < 1e-3 && e + 0 < 1.5e-3) }'; then
  echo "ok   ...with the printed data deviation below the 0.001 tolerance and the trimmed edge within 1.5e-3 of the curve ($KW3_PATCH)"
else
  echo "FAIL saddle Patch: deviation/edge figures out of bounds: $KW3_PATCH"; fail=1
fi
KW3_AREA="$(echo "$KW3" | grep -o "Area = [0-9.]* square" | sed -n '5p' | awk '{print $3}')"
if echo "$KW3_AREA" | awk '{ exit !($1 > 83 && $1 < 87) }'; then
  echo "ok   the trimmed saddle patch has area $KW3_AREA, the saddle disc's (about 85.2 for r = 5; the flat disc the old command made is 78.5)"
else
  echo "FAIL the trimmed saddle patch area is $KW3_AREA, expected 83-87 (flat disc: 78.5)"; fail=1
fi
KW3_Z="$(echo "$KW3" | grep -o "Bounding box min -[0-9.]*,-[0-9.]*,-[0-9.]* max [0-9.]*,[0-9.]*,[0-9.]*" | head -1)"
if [ -n "$KW3_Z" ] && echo "$KW3_Z" | awk '{ split($4, lo, ","); split($6, hi, ","); exit !(lo[3] < -1.3 && hi[3] > 1.3 && hi[1] > 4.9 && lo[1] < -4.9) }'; then
  echo "ok   the trimmed saddle patch (the curve deleted first, so the patch alone) really leaves the plane: its box spans x -5..5 and z from below -1.3 to above 1.3 ($KW3_Z), a flat patch would be z = 0"
else
  echo "FAIL the trimmed saddle patch box does not span z -1.4..1.5: $KW3_Z"; fail=1
fi
kw3check "Patch: non-planar data - kernel least-squares NURBS surface through 0 curve(s) and 9 point(s) (2 x 2 net, worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1); untrimmed, spanning the data's extent" "Patch through nine non-coplanar points on z = x y / 4 fits a bilinear 2 x 2 NURBS surface through all of them (best-fit plane misses them by 1)"
kw3check "Area = 17.27 square" "...whose area is the closed-form integral of sqrt(1 + (x^2 + y^2) / 16) over the square, 17.2646 (display mesh 17.27), not the 16 of a flat rectangle"
kw3check "Patch: least-squares plane through 0 curve(s) and 3 point(s)" "Patch of three coplanar points keeps the planar construction (no kernel fit attempted)"
kw3check "! Patch: the input is collinear" "Patch of collinear points keeps its original diagnostic"

# Section-anchored single-section Sweep1/Sweep2 and the exact interpolating Loft
# (the second half of kernel_wiring_script.txt; read its comments for each case).
# kwdist START NTH SKIP N TARGET LIMIT DESC: after the NTH line matching START,
# skip the next SKIP "Closest point" lines, then every one of the following N
# must read a distance within LIMIT of TARGET (the worst one is reported).
kwdist() {
  local r
  r="$(awk -v start="$1" -v nth="$2" -v skip="$3" -v n="$4" -v target="$5" -v lim="$6" '
    !on && $0 ~ start { if (++hits == nth) on = 1; next }
    on && /Closest point/ { idx++; if (idx > skip && idx <= skip + n) { cnt++; e = $NF - target; if (e < 0) e = -e; if (e > worst) worst = e } }
    END { if (!on) print "NOSTART"; else if (cnt != n) print "COUNT " cnt; else if (worst < lim) print "OK " worst + 0; else print "BAD " worst + 0 }' <<<"$KW")"
  case "$r" in OK*) echo "ok   $7 (worst ${r#OK })" ;; *) echo "FAIL $7 ($r)"; near "$KW" "$1"; fail=1 ;; esac
}
KWTINY='\(e-\(0[7-9]\|[1-9][0-9]\)\|e+00\)$'
kwcount "Sweep1: the section is at the rail start; the section's isocurve on the result deviates by [0-9.]*$KWTINY" 2 "Sweep1 with the section AT the rail start (0%) keeps the kernel call unchanged and measures the section's isocurve on the result: < 1e-6 (straight rail and curved rail)"
kwcount "Sweep1: the section sits 40.0% along the rail; the rail was split there and both sides swept from the section and joined; the result reproduces the section to [0-9.]*$KWTINY" 2 "Sweep1 with the section 40% along the rail splits the rail there, sweeps both sides from the section, joins them, and reports the result reproducing the section to < 1e-6 (straight rail and curved rail)"
kwcount "Sweep1: the section sits 100.0% along the rail; swept back along the rail from the section; the result reproduces the section to [0-9.]*$KWTINY" 2 "Sweep1 with the section AT the rail end (100%) sweeps back along the reversed rail and reproduces the section to < 1e-6 (straight rail and curved rail)"
kwcount "Bounding box min -2,-1.912,0 max 2,1.912,10" 3 "a radius-2 circle swept along a straight z = 0..10 rail covers exactly the rail's z = 0..10 whether the circle sits at 0%, 40% or 100% of it (before: z = 0..10, 4..14 and 10..20)"
kwcheck "Bounding box min 0,0,0 max 5,0,12" "Sweep2 along two straight rails with the section 40% of the way up spans the rails' own z = 0..10 (the polyline's 2-high apex rises to 12 at the far end; before: z = 4..16)"
# CHANGED with the SCP_ work (see the SCP_ section at the end of this file): this closed rail is an exact circle, so the
# sweep is no longer the kernel's re-seamed 32-station skin but the section revolved once about the rail's axis (an exact
# rational surface; the command measures 2145 wall points against the revolved section and prints it, then still verifies
# the section reproduced at the 40% station). The old text "the closed rail was re-seamed there" is now printed only for a
# closed rail that is NOT a circle (SCP_9 pins the control).
KWTINYI='\(e-\(0[7-9]\|[1-9][0-9]\)\|e+00\)'
kwcheck "Sweep1: the section sits 40.0% along the rail; the closed rail is an exact circle, so the sweep is the section revolved once about the rail's axis (exact rational surface, not a skin; measured distance of 2145 wall points from the revolved section [0-9.]*$KWTINYI); the result reproduces the section to [0-9.]*$KWTINY" "Sweep1 along a CLOSED circular rail is now the exact surface of revolution (was: re-seamed skin) - the wall is measured < 1e-7 from the revolved section and reproduces the section at 40% to < 1e-6"
kwdist "the closed rail is an exact circle, so the sweep is the section revolved once" 1 0 6 1 0.001 "...and the revolved tube is the section's radius (1) from the rail at 0, 36, 90, 144, 200 and 300 degrees"
kwcheck "Sweep2: exact sweep not used - the section sits at the start of rail 1 but at the interior of rail 2, so one rail has nothing to sweep on one side of it; falling back to the approximate section-anchored sweep" "Sweep2 with the section at the start of rail 1 but interior to rail 2 refuses the exact path, prints why, and falls back"
kwcheck "Sweep2: 1 section(s) along 2 rail stations" "...and the older approximate section-anchored sweep still produces the surface"
kwdist "Sweep1: the section is at the rail start" 2 0 8 0 0.000001 "curved rail, section at 0%: 8 points on the section circle lie on the swept surface to < 1e-6"
kwdist "Sweep1: the section is at the rail start" 2 8 6 1.5 0.001 "...and the rail's points at 0, 20, ..., 100% are all the tube radius (1.5) from it"
kwdist "Sweep1: the section sits 40.0% along the rail; the rail was split" 2 0 8 0 0.000001 "curved rail, section at 40%: 8 points on the section circle lie on the joined surface to < 1e-6"
kwdist "Sweep1: the section sits 40.0% along the rail; the rail was split" 2 8 6 1.5 0.001 "...and ALL six rail points (0..100%) are exactly the tube radius (1.5) from it - a tube around the whole rail (before: 7.2, 4.0, 1.5, 1.2, 0.46, 0.28)"
kwdist "Sweep1: the section sits 100.0% along the rail" 2 0 8 0 0.000001 "curved rail, section at 100%: 8 points on the section circle lie on the surface to < 1e-6"
kwdist "Sweep1: the section sits 100.0% along the rail" 2 8 6 1.5 0.001 "...and all six rail points are the tube radius (1.5) from it (before: 16.1, 14.1, 11.2, 7.8, 4.2, 1.4)"
kwdist "Sweep2: the section is at the start of both rails" 2 0 5 0 0.000001 "Sweep2, curved rails, section at 0%: 5 points on the polyline section lie on the surface to < 1e-6"
kwdist "Sweep2: the section is at the start of both rails" 2 5 12 0 0.05 "...and both rails sampled at 0..100% lie within 0.05 of the surface (they are its sides, to within the 32-station skin)"
kwcheck "Sweep2: the section sits 40.0% along rail 1 and 40.0% along rail 2; both rails were split there and both sides swept from the section and joined; the result reproduces the section to [0-9.]*$KWTINY" "Sweep2 with the section 40% along both rails splits both, sweeps and joins, reproducing the section to < 1e-6"
kwdist "Sweep2: the section sits 40.0% along rail 1 and 40.0% along rail 2" 2 0 5 0 0.000001 "Sweep2, curved rails, section at 40%: 5 points on the section lie on the joined surface to < 1e-6"
kwdist "Sweep2: the section sits 40.0% along rail 1 and 40.0% along rail 2" 2 5 12 0 0.05 "...and both rails, 0..100%, lie within 0.05 of it (before: up to 7.8 away)"
kwdist "Sweep2: the section sits 100.0% along rail 1 and 100.0% along rail 2; swept back" 1 0 5 0 0.000001 "Sweep2, curved rails, section at 100%: 5 points on the section lie on the surface to < 1e-6"
kwdist "Sweep2: the section sits 100.0% along rail 1 and 100.0% along rail 2; swept back" 1 5 12 0 0.05 "...and both rails, 0..100%, lie within 0.05 of it"
# Loft
kwcheck "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.]*${KWTINY%\$}; aligned first: 1 curve(s) reversed, 0 seam(s) moved" "Loft through three lines (the middle one drawn the other way) is the exact interpolating kernel loft: the middle line is reversed to run with the others and every section is reproduced to < 1e-6"
kwcheck "Area = 147.9 square" "...and the sheet has the exact area 5(sqrt5 + asinh 2) * 10 = 147.9 (before: the ribbon along the sample polyline measured 6.7)"
kwdist "aligned first: 1 curve.s. reversed, 0 seam.s. moved" 1 0 11 0 0.000001 "...and all 11 sampled points of the three lines (both ends and the middle of each) lie on the lofted surface to < 1e-6 (before: the line ends were 0.88 off and the sheet never spanned the lines)"
kwcheck "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.]*${KWTINY%\$}; aligned first: 1 curve(s) reversed, 2 seam(s) moved; end caps added (Cap=Yes), a closed polysurface" "Loft through three circles, the middle one rotated a quarter turn and reversed and the last one rotated 200 degrees: reverses one curve, moves two seams, caps the ends into a closed polysurface"
kwcheck "Volume = 433" "...whose volume is the exact 10 pi * 13.8 = 433.5 (before: a mesh of volume 165.6)"
kwcount "3 faces, 3 edges, closed solid" 3 "the three capped lofts (three circles, the radius-5-to-3 frustum, two squares) are real closed-solid polysurfaces with one planar trimmed face per end (wall + 2 caps, 3 edges: two cap circles/loops and the seam), not meshes; CHANGED PIN (KWR wiring): the count was 4 because the 4th match was the cylinder of the ChamferEdge Distance/Angle case, which used to be refused and left as the untouched 3-face cylinder - it now gets the exact kernel bevel (4 faces, 7 edges) and is counted by the rim-chamfer pin above instead"
kwcheck "! Loft: curve 2 is closed but curve 1 is open - a loft needs all open or all closed curves (an open and a closed curve have no point-for-point correspondence)" "Loft of a line and a circle is refused with the reason printed (and creates nothing: expect_objects 2 above)"
kwcheck "Loft: exact interpolating kernel loft through 2 curves (degree 1 in the loft direction); every section reproduced, max deviation [0-9.]*${KWTINY%\$}; uncapped (Cap=No)" "Loft Style=Straight Cap=No between two circles is degree 1 in the loft direction and uncapped"
kwcheck "Area = 25[0-9]" "...a surface with the exact frustum lateral area pi (5+3) sqrt(104) = 256.3"
kwcheck "Volume = 51[0-9]" "...and capped (Cap=Yes) it is the exact frustum solid pi 10/3 (25+15+9) = 513.2"
kwcheck "Loft: exact kernel loft not used (dino8::kernel::Brep::Loft: every section coincides with every other one - nothing to loft); using the older control-point fit instead" "Loft of two coincident circles: the kernel refuses, the reason is printed, the older control-point fit is kept as the fail-open path"
kwcheck "Area = 600 square" "Loft Style=Straight between two squares (second starting at a different corner) is the exact capped box: lateral + cap area 600"
kwcount "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.]*$KWTINY" 3 "Loft with History On: built once, re-lofted automatically when the middle line moved (no UpdateHistory call), and re-lofted again by the explicit UpdateHistory (three kernel lofts)"
kwcheck "Closest point 5,7,5 distance 0" "...and after the middle line moves +2 in y, UpdateHistory's re-loft passes through (5,7,5)"
kwcheck "Area = 114.8 square" "SubDLoft through three lines still builds the control-point-fit NURBS surface, now laid out correctly (area 114.8; before: a ribbon of area 6.7)"
kwcheck "140 faces, 210 edges, 72 vertices, 0 creases" "SubDLoft through three circles still builds a SubD"
kwcheck "through 4 curves (degree 3 in the loft direction); every section reproduced, max deviation [0-9.]*e-\(0[6-9]\|[1-9][0-9]\)$" "Loft through four lines is cubic in the loft direction and reproduces every section"
kwdist "through 4 curves .degree 3 in the loft direction." 1 0 3 0 0.000001 "...and the middle points of the three non-trivial lines lie on the surface to < 1e-6"
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

exit $fail
