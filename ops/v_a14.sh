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
# Solids: Ellipsoid/SubDEllipsoid (real axis picking), Pyramid (NumSides=),
# Loft (Normal vs Style=Straight), Cap (multiple separate openings) (see solids_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SO="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/solids_script.txt" 2>&1)" || { echo "$SO"; echo "FAIL: solids script exited non-zero"; exit 1; }
else
  SO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/solids_script.txt" 2>&1)" || { echo "$SO"; echo "FAIL: solids script exited non-zero"; exit 1; }
fi
socheck() { if echo "$SO" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SO" "$1"; fail=1; fi; }
socheck "Volume = 132 cubic" "Ellipsoid volume is close to the analytic 4/3*pi*5*3*2 (~125.7)"
socheck "48 faces, 72 edges, 26 vertices, 0 creases" "SubDEllipsoid built a SubD from the same three axes"
socheck "7 vertices, 10 faces" "Pyramid NumSides=6 built a 7-vertex hexagonal-base mesh"
socheck "degree 1 x 2, CVs 2 x 3" "Loft (Normal) of three straight lines is the exact interpolating kernel loft: degree 1 along the lines (the old 24 x 3 control-point fit was cubic along them), degree 2 (sections - 1) through the 3 sections"
socheck "degree 1 x 1, CVs 2 x 3" "Loft Style=Straight keeps degree 1 in the loft direction (a ruled loft with a sharp edge at the middle section)"
socheck "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.e+-]*" "Loft (Normal) prints that it is the exact interpolating kernel loft and the measured section deviation"
socheck "Loft: exact interpolating kernel loft through 3 curves (degree 1 in the loft direction); every section reproduced" "Loft Style=Straight prints that it is the exact kernel loft at degree 1 in the loft direction"
socheck "4 faces, 12 edges, open" "DeleteFaces removed the box's top and bottom (two separate naked-edge loops)"
socheck "Capped 1 object(s), 2 opening(s)" "Cap closed both separate openings in one call"
socheck "6 faces, 76 edges, open" "Cap added both cap faces back (4 sides + 2 caps)"
socheck "Volume = 17[4-6][0-9] cubic" "Torus volume is close to the analytic 2*pi^2*10*9 (~1776.5)"
socheck "Volume = 50[0-2].[0-9] cubic" "Tube volume is close to the analytic pi*(5^2-3^2)*10 (~502.7)"
socheck "smoke: frames=150 objects=14" "solids script produced the expected object count"
# Surface editing: ExtractSrf, DeleteFaces, DupBorder/DupEdge, Untrim, isocurves, ExtendSrf, UnrollSrf, Silhouette, RailRevolve, Fin/Ribbon, grids (see srfedit_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SE="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/srfedit_script.txt" 2>&1)" || { echo "$SE"; echo "FAIL: surface-edit script exited non-zero"; exit 1; }
else
  SE="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/srfedit_script.txt" 2>&1)" || { echo "$SE"; echo "FAIL: surface-edit script exited non-zero"; exit 1; }
fi
secheck() { if echo "$SE" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SE" "$1"; fail=1; fi; }
secheck "ExtractSrf: face 5 extracted from object 1" "ExtractSrf pulled the top face off the box"
secheck "5 faces, 12 edges, open" "ExtractSrf left a 5-face open polysurface"
secheck "DeleteFaces: face 4 deleted, 4 face(s) left" "DeleteFaces removed the bottom face"
secheck "DupBorder: 3 border curve(s)" "DupBorder found the naked edge loops"
secheck "DupEdge: edge 0 of object 1 duplicated" "DupEdge copied an edge"
secheck "DupFaceBorder: 1 curve(s)" "DupFaceBorder copied the face loop"
secheck "Untrim: face 0 replaced by its untrimmed surface" "Untrim removed the circular trim"
secheck "ExtractIsocurve: 2 curve(s)" "ExtractIsocurve extracted U and V isocurves"
secheck "ExtractWireframe: 6 curve(s)" "ExtractWireframe extracted the cylinder wires"
secheck "Bounding box min 200,0,0 max 220,10,0" "ExtendSrf grew the plane by 10"
secheck "UnrollSrf: face 0 unrolled exactly (a real plane/cylinder/cone - zero distortion), area 314.2" "UnrollSrf now uses the kernel's exact NurbsSurface::UnrollDevelopable() on a real cylinder wall (radius 5, height 10: true area 2*pi*5*10 = 314.16, exact - not the old heuristic's own approximate 313)"
secheck "Silhouette: [0-9]* curve(s)" "Silhouette produced outline curves"
secheck "RailRevolve: genuine B-rep solid/shell built (profile planar through the picked axis)" "RailRevolve built a real B-rep solid/shell, not just an approximate surface - this fixture's own circle profile and axis genuinely satisfy kernel::Brep::RailRevolve()'s own planar-through-axis case, a staleness correction: this test's own expectation was never updated for that round's new 'exact first, fail open' path (railrevolve_solid_script.txt's own rrvcheck tests the surface-fallback case on a genuinely different, non-coplanar fixture instead)"
secheck "Ribbon: 1 ribbon surface(s), width 5" "Ribbon built a ribbon surface"
secheck "SrfControlPtGrid: surface from 2 x 2 points" "SrfControlPtGrid built a surface from points"
secheck "UntrimBorder: face 0's outer trim removed (holes kept)" "UntrimBorder removed only the outer trim"
secheck "JoinEdge: 1 naked edge pair(s) joined" "JoinEdge force-joined two just-touching planes"
secheck "MoveFace: 1 object(s) updated" "MoveFace ran"
secheck "Bounding box min 1100,0,0 max 1110,10,15" "MoveFace actually raised the box's top face"
secheck "MoveEdge: 1 object(s) updated" "MoveEdge ran"
secheck "Bounding box min 1200,0,0 max 1210,10,15" "MoveEdge actually raised the picked edge"
secheck "MoveUntrimmedFace: 1 object(s) updated" "MoveUntrimmedFace ran"
secheck "Bounding box min 1300,0,0 max 1310,10,20" "MoveUntrimmedFace actually raised the untrimmed top face"
secheck "MoveUntrimmedEdge: 1 object(s) updated" "MoveUntrimmedEdge ran"
secheck "Bounding box min 1400,0,0 max 1410,10,25" "MoveUntrimmedEdge actually raised the picked iso edge"
secheck "MoveUVN: control point (0,0) moved u=0 v=0 n=7" "MoveUVN moved a surface CV along its local normal"
secheck "FoldFace: face 5 folded 30 degree" "FoldFace rotated a face about its hinge edge"
secheck "Bounding box min 1600,-5,0 max 1610,10,13.66" "FoldFace actually moved the folded face's geometry"
secheck "SetPlanar: 2 object(s) projected" "SetPlanar ran"
secheck "Bounding box min 1700,0,0 max 1710,0,0" "SetPlanar actually flattened the points onto z=0"
secheck "volume 1000, centroid 1805,5,5" "VolumeMoments reported the box's real volume and centroid"
secheck "radii of gyration about centroid: x=4.082 y=4.082 z=4.082" "VolumeMoments computed real radii of gyration for a 10-cube (sqrt(1000\*6/60/10)=4.082 exactly for a cube)"
secheck "area 100, centroid 1905,5,0" "AreaMoments reported the plane's real area and centroid"
secheck "displacement (below the construction plane): 26" "Hydrostatics computed a real submerged volume (half of a r=5 sphere is 4/3*pi*125/2 = 261.8)"
secheck "waterplane area 78.[0-3]" "Hydrostatics computed the real waterplane cross-section area (pi\*5\^2 = 78.5, mesh-sampled - widened from a bare 78.3 to tolerate the small platform-dependent tessellation variance also seen in ArrayHole/ArrayHolePolar's face counts, e.g. Windows sampling 78.15)"
secheck "prismatic coefficient Cp 0.3333, vertical prismatic coefficient Cvp 0.52" "Hydrostatics computed real Cp/Cvp for a half-cone (exact Cp = 1/3; Cvp = pi/6 =~ 0.5236, mesh-sampled to 0.5231)"
secheck "trim 0 deg, heel 0 deg" "Hydrostatics' trim/heel solver correctly found the half-cone already level (symmetric about its own axis)"
secheck "trim 20 deg, heel [-0-9.]*e-0" "Hydrostatics' Newton trim solver recovered the exact 20 degree pitch a cube was rotated by (heel ~0, as expected from the pitch-only rotation)"
secheck "ExtractBadSrf: 0 invalid polysurface(s) extracted as copies" "ExtractBadSrf found no invalid polysurfaces in a valid box"
secheck "RemoveAllNakedMicroEdges: no naked edges shorter than" "RemoveAllNakedMicroEdges scanned a closed box and found none"
secheck "ShrinkTrimmedSrf: 0 polysurface(s) shrunk" "ShrinkTrimmedSrfToEdge ran (this trimmed disk is already shrunk tight)"
secheck "SrfSeam: seam moved to" "SrfSeam rotated a real closed surface's periodic seam"
secheck "SphereTangentToThreeSurfaces: sphere at" "SphereTangentToThreeSurfaces solved a real equidistant sphere"
secheck "SetSurfaceTangent: 2 boundary tangent-row control point" "SetSurfaceTangent rotated the tangent row to match the target's normal"
secheck "VariableOffsetSrf: offset 1 at the U-min edge to 3 at U-max" "VariableOffsetSrf built a real per-CV linearly-varying offset"
secheck "FitCurveToSurface: fitted through 13 points" "FitCurveToSurface pulled a coarse fit onto the surface"
secheck "PatchSingleFace: face 5 of object" "PatchSingleFace replaced a box face with a real Coons patch"
secheck "Volume = 1000 cubic" "PatchSingleFace's Coons patch kept the box's exact volume (still flat)"
secheck "Flow: base length 10 -> target length 99.35" "ApplyCrv aliased into Flow's real curve deformation"
secheck "ApplyMesh: 1 object(s) reshaped via nearest-triangle barycentric" "ApplyMesh reshaped a mesh sphere onto a same-topology target"
secheck "ApplyMeshUVN: 1 object(s) reshaped via nearest-triangle barycentric" "ApplyMeshUVN ran the same real mesh mapping"
secheck "Boss: protrusion of height 5 built following the base's local surface normal at 48 points along the curve; unioned with the base solid" "Boss built a real solid protrusion and unioned it with the box"
secheck "Volume = 1063 cubic" "Boss's union really added the r=2 h=5 cylinder's volume (1000 + pi*4*5 = 1062.8)"
secheck "Rib: tapered wall of height 2 built following the base's local surface normal at 64 points along the curve; unioned with the base solid" "Rib built a real tapered wall and unioned it with the box"
secheck "Volume = 1006 cubic" "Rib's union really added the tapered wall's volume"
secheck "FilletSrfToRail: fillet surface built along the rail's own points" "FilletSrfToRail built real rolling-ball arcs along a picked rail"
secheck "FilletSrfToRail:.*; both surfaces trimmed" "FilletSrfToRail now real-trims both picked surfaces along their own contact curves by default (TrimRailWholeLoop/TrimRailBySplit), PARITY_MAP.md's own 'no trimming' gap for this command"
FSR_TRIM="$(echo "$SE" | grep -c "FilletSrfToRail:.*; both surfaces trimmed")"
[ "$FSR_TRIM" = "1" ] \
  && echo "ok   exactly one FilletSrfToRail call trimmed both surfaces (the Trim=No call below must not)" \
  || { echo "FAIL expected exactly 1 'both surfaces trimmed' FilletSrfToRail line, got $FSR_TRIM"; fail=1; }
secheck "FilletSrfToRail: fillet surface built along the rail's own points (radius 1; contact points off the exact radius by up to 1 - the rail is used directly as the spine, rather than the SSX-offset spine FilletSrf computes)$" "FilletSrfToRail's own Trim=No negative control prints no trim suffix at all (neither trimmed nor a fallback message) - the two picked surfaces are left genuinely untouched"
secheck "FilletSrfCrv: fillet surface built tangent to the surface and osculating-tangent to the curve" "FilletSrfCrv built a real surface/curve rolling-ball fillet"
FSC_GAP="$(echo "$SE" | sed -n 's/.*FilletSrfCrv:.*contact points off the exact radius by up to \([0-9.eE+-]*\);.*/\1/p' | head -1)"
python3 -c "import sys; v=float('$FSC_GAP'); sys.exit(0 if v < 1e-4 else 1)" \
  && echo "ok   FilletSrfCrv contact-radius gap ($FSC_GAP) is essentially zero - contact points really sit at the exact radius" \
  || { echo "FAIL FilletSrfCrv contact-radius gap ($FSC_GAP) is not near zero"; fail=1; }
FSC_TANG="$(echo "$SE" | sed -n 's/.*arc tangent matches the curve.s own tangent to within \([0-9.eE+-]*\) degrees.*/\1/p' | head -1)"
python3 -c "import sys; v=float('$FSC_TANG'); sys.exit(0 if v < 0.01 else 1)" \
  && echo "ok   FilletSrfCrv tangent-direction error ($FSC_TANG degrees) is essentially zero - the arc is genuinely tangent to the curve, not merely touching it (the exact gap the old Partial note described)" \
  || { echo "FAIL FilletSrfCrv tangent-direction error ($FSC_TANG degrees) is not near zero - arc is not genuinely tangent to the curve"; fail=1; }
secheck "SoftEditSrf: 4 control point(s) moved with a cosine falloff within radius 8 (max displacement 3)" "SoftEditSrf moved control points with a real falloff"
secheck "^ok   expect_objects 104" "surface-edit script produced the expected object count halfway through (before UnjoinEdge/ReplaceEdge)"
secheck "ShowEdges: 1 object(s), 7 edge(s), 6 naked edge(s)" "ShowEdges found the joined planes' 1 shared and 6 naked edges before unjoining"
secheck "UnjoinEdge: edge [0-9]* split into two naked, coincident edges - both faces remain in the same polysurface" "UnjoinEdge split the shared edge in place via real Brep::UnjoinEdge()"
secheck "ShowEdges: 1 object(s), 8 edge(s), 8 naked edge(s)" "ShowEdges confirms exactly 2 more naked edges after unjoining - the old shared edge, now two coincident naked ones"
secheck "ReplaceEdge: edge [0-9]* re-trimmed against the picked curve's own shape, every affected face re-projected onto it" "ReplaceEdge re-trimmed a naked edge against a bowed substitute curve via real Brep::ReplaceEdgeCurve()"
secheck "2 faces, 9 edges, open" "the re-trimmed polysurface keeps its same topology (2 faces) after ReplaceEdge - only the one edge's own shape changed"
secheck "^ok   expect_objects 106" "surface-edit script produced the expected final object count"
secheck "Squish: face 0 flattened, area 100 (whole object 3D area 100), distortion max 0% avg 0%" "Squish flattened an already-flat plane with exactly zero distortion either way"
secheck "SquishInfo: object [0-9]* - flat area 100 (3D area 100), distortion max 0% avg 0%" "SquishInfo reprinted Squish's own stored report (area + distortion) instead of recomputing it"
secheck "SquishBack: 1 curve(s) projected back onto the source surface via the flat pattern's own per-vertex (u,v) map" "SquishBack projected a curve on the flat pattern back onto the source surface via the stored (u,v) map"
secheck "Bounding box min 3702,2,0 max 3708,8,0" "SquishBack's round trip landed the projected curve exactly back on the source plane's own diagonal"
secheck "DeleteFaces: face [0-9]* deleted, 5 face(s) left" "DeleteFaces opened the fresh box for the naked-micro-edge fixture"
secheck "RemoveAllNakedMicroEdges: 2 naked micro edge(s) removed (endpoints welded, the two loop-adjacent naked edges re-trimmed to close the gap)" "RemoveAllNakedMicroEdges closed both the isolated sliver and the corner-adjacent one (real Brep::RemoveNakedMicroEdge, now relaxed to nudge a shared-trim or third-face-pinched neighbor too, mirroring RemoveSharedMicroEdge's own relaxation)"
secheck "^ok   expect_objects 116" "surface-edit script produced the expected object count after the Squish/SquishBack/RemoveAllNakedMicroEdges additions"
secheck "SplitRefitSurface: 1 surface(s) split into 2 piece(s), each refit to a clean untrimmed NURBS surface" "SplitRefitSurface split the plane at the curve's crossing and refit both pieces"
secheck "degree 3 x 3, CVs 4 x 4" "SplitRefitSurface's refit pieces are genuinely rebuilt to a fresh 4x4-CV surface, not left at Split()'s own original 2x2 CVs"
secheck "Bounding box min 4400,0,0 max 4410,10,0" "SplitRefitSurface's two refit pieces still exactly cover the original plane end to end (west [4400,4405] + east [4405,4410])"
secheck "HBar: locked the distance between control points 0 and 1 of '(unnamed)' at 10" "HBar locked the real distance (10) between a 2-CV line's own two control points"
secheck "HBarSetDistance: locked distance set to 20 - control point 1 moved to match" "HBarSetDistance changed the locked value and re-applied the constraint"
secheck "HBarDragSelfTest: moved anchor control point 0 by 5,0,0; anchor-handle distance is now 20 (locked at 20)" "HBarDragSelfTest exercised the exact TransformSubObjects+ApplyHBarConstraint call sequence a real mouse drag makes, and the handle swung to keep the locked distance"
secheck "Bounding box min 4205,0,0 max 4225,0,0" "BoundingBox independently confirms the curve's own control points actually moved to where the constraint math says they should (anchor 4200+5=4205, handle 4205+20=4225) - not just HBarDragSelfTest's own report"
secheck "ExtendSrf: extended by 3 along V (linear)" "ExtendSrf Type=Linear ran on a curved sphere - the flat Plane fixture earlier in this script can't tell Type=Linear apart from the default Type=Smooth"
secheck "Area = 331.8" "ExtendSrf Type=Linear produced a genuinely different area (331.8) than Type=Smooth's 334.6 on the same sphere/pick/distance - the two extension modes are not just differently labelled, they build different geometry"
secheck "MergeSrf: merged 2 surfaces into one" "MergeSrf ran on two adjacent planar rectangles"
secheck "Area = 200 square" "MergeSrf's refit surface has the exact union area (10x20), not an approximation artifact - a flat plane is exactly representable at any degree"
secheck "Bounding box min 4600,0,0 max 4620,10,0" "MergeSrf's refit surface exactly spans both source rectangles, corner to corner"
secheck "smoke: frames=[0-9]* objects=127" "surface-edit script's final object count includes the MergeSrf fixture (2 rectangles + 2 planar surfaces, merged down to 1)"

# Mesh tools: deformations, mesh editing and mesh primitives (see meshtools_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  MT="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/meshtools_script.txt" 2>&1)" || { echo "$MT"; echo "FAIL: mesh-tools script exited non-zero"; exit 1; }
else
  MT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/meshtools_script.txt" 2>&1)" || { echo "$MT"; echo "FAIL: mesh-tools script exited non-zero"; exit 1; }
fi
mtcheck() { if echo "$MT" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$MT" "$1"; fail=1; fi; }
mtcheck "Twist: 90 degrees over 20 units" "Twist read its axis and angle"
mtcheck "Twist: deformed 1 object(s)" "Twist deformed the mesh cylinder"
mtcheck "Bend: deformed 1 object(s) (1 converted to meshes)" "Bend converted the box to a mesh and bent it"
mtcheck "Taper: 5 -> 2" "Taper read both distances"
mtcheck "Stretch: 20 -> 30" "Stretch lengthened the line"
mtcheck "Shear: deformed 1 object(s)" "Shear ran with three points"
mtcheck "Maelstrom: deformed 1 object(s)" "Maelstrom ran"
mtcheck "SoftMove: 4 units with falloff radius 5" "SoftMove took its Radius option"
mtcheck "Smooth: smoothed 1 object(s), factor 0.5" "Smooth ran on the mesh sphere"
mtcheck "SoftTransform (Rotate): 45 degrees about the CPlane normal" "SoftTransform Rotate mode ran"
mtcheck "SoftTransform (Scale): factor 1.5 from" "SoftTransform Scale mode ran"
mtcheck "ExtrudeMesh: extruded open mesh into a closed solid" "ExtrudeMesh closed the open mesh plane"
mtcheck "Volume = 300" "the extruded 10x10x3 mesh has volume 300"
mtcheck "OffsetMesh: solid shell" "OffsetMesh built a solid shell"
mtcheck "FillMeshHoles: filled 1 hole(s)" "FillMeshHoles closed the naked loop"
mtcheck "Unweld: added 72 vertex copy(ies)" "Unweld split the sharp edges"
mtcheck "Weld: merged 72 vertex(es)" "Weld merged them back"
mtcheck "0 naked edge(s), 0 non-manifold edge(s), closed" "MeshRepair reports a closed mesh"
mtcheck "MeshEllipsoid: radii 10, 7, 5" "MeshEllipsoid built"
mtcheck "MeshTruncatedCone: 96 faces, closed" "MeshTruncatedCone is closed"
mtcheck "TruncatedPyramid: 12 faces, closed" "TruncatedPyramid is closed"
mtcheck "Paraboloid: NURBS surface of revolution, radius 10, height 10, 2 face(s), closed" "Paraboloid built a closed NURBS surface of revolution"
mtcheck "PlanarMesh: created 1 mesh(es)" "PlanarMesh triangulated the circle"
mtcheck "Slab: created 1 mesh(es)" "Slab thickened the rectangle"
mtcheck "ExtractMeshPart: all 6 faces extracted" "ExtractMeshPart extracted the box"
mtcheck "MeshIntersect: 14 segment(s) in 2 polyline(s)" "MeshIntersect found the box/box intersection"
mtcheck "MeshPatch: 3 triangles from 4 points" "MeshPatch triangulated the points"
mtcheck "MeshOutline: created 1 outline curve(s)" "MeshOutline built the outline"
mtcheck "Drape: 20x20 grid draped over" "Drape hit the visible meshes"
mtcheck "TriangulateRenderMeshes: 12 triangles" "TriangulateRenderMeshes split the box's quads"
mtcheck "AddNgonsToMesh: object [0-9]*: 6 ngon(s) from coplanar face groups" "AddNgonsToMesh grouped the box's triangle pairs back into ngons"
mtcheck "ComputeVertexColors: coloured 1 mesh(es) by vertex normal" "ComputeVertexColors coloured the mesh"
mtcheck "UnweldEdge: unwelded the edge nearest the pick" "UnweldEdge separated a single picked edge"
mtcheck "CollapseMeshVertex: collapsed the vertex nearest the pick into its nearest neighbour" "CollapseMeshVertex picked a vertex"
mtcheck "CollapseMeshFace: collapsed the face nearest the pick into its centroid" "CollapseMeshFace picked a face"
mtcheck "CollapseMeshEdge: collapsed the edge nearest the pick into its midpoint" "CollapseMeshEdge picked an edge"
mtcheck "DupMeshEdge: 1 edge(s) duplicated so far" "DupMeshEdge duplicated the single picked edge"
mtcheck "ExtractMeshFaces: extracted 1 of 6 faces" "ExtractMeshFaces extracted the single picked face"
mtcheck "FlatShade: added 16 vertex copy(ies)" "FlatShade fully unwelded the box for faceted shading"
mtcheck "Weld: merged 0 vertex(es); 6 vertices remain" "Weld did not merge a pair that rounds into the same quantization bucket but is actually farther apart than tolerance"
mtcheck "Weld: merged 1 vertex(es); 5 vertices remain" "Weld merged a genuinely coincident pair even though they round into adjacent quantization buckets"
echo "$MT" | grep -E "^(ok|FAIL)"
if echo "$MT" | grep -q "^FAIL"; then fail=1; fi
mtcheck "smoke: frames=[0-9]* objects=43" "mesh-tools script produced the expected object count"

# SubD editing: Crease, ExtrudeSubD, Inset, Bridge, OffsetSubD, RepairSubD, InsertEdge,
# DivideAlongCreases, Fill, AutomaticSubDFromMesh, SubDTruncatedCone, ShrinkWrap (see subd_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SD="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/subd_script.txt" 2>&1)" || { echo "$SD"; echo "FAIL: subd script exited non-zero"; exit 1; }
else
  SD="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/subd_script.txt" 2>&1)" || { echo "$SD"; echo "FAIL: subd script exited non-zero"; exit 1; }
fi
sdcheck() { if echo "$SD" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SD" "$1"; fail=1; fi; }
sdcheck "Crease: 2 edge(s) creased on 1 SubD(s)" "Crease tagged the two picked edges"
sdcheck "Crease edges: 2" "What reports the crease edges on the control net"
sdcheck "ExtrudeSubD: extruded 1 face(s) by 3 on 1 SubD(s), 4 side face(s) added" "ExtrudeSubD extruded the top face with four side faces"
sdcheck "Inset: 1 face(s) inset by 1" "Inset built an inner face and ring"
sdcheck "Bridge: joined 2 faces with a tube of 4 quads, 2 SubDs merged" "Bridge joined the two boxes"
sdcheck "Faces: 22" "the bridged SubD has 22 control faces (6+4+5 for the boxes and tube, plus the inset)"
sdcheck "OffsetSubD: solid shell, distance 1, 1 SubD(s)" "OffsetSubD Solid=Yes built a shell"
sdcheck "44 face(s) (was 44), 0 naked edge(s), 0 non-manifold edge(s), closed" "RepairSubD reports the offset shell closed"
sdcheck "InsertEdge: 4 edge(s) inserted at 0.5 along the ring" "InsertEdge inserted an edge loop around the box"
sdcheck "Crease: 6 edge(s) creased on 1 SubD(s)" "Crease tagged the loop around the split top face"
sdcheck "DivideAlongCreases: 1 SubD(s) divided into 2 piece(s)" "DivideAlongCreases split the box at the crease loop"
sdcheck "Fill: 1 hole(s) filled with a face" "Fill closed the naked loop"
sdcheck "AutomaticSubDFromMesh: SubD with 6 face(s), 12 crease edge(s) sharper than 30 degrees" "AutomaticSubDFromMesh creased the box edges"
sdcheck "SubDTruncatedCone: base radius 5, top radius 2.5, height 10, 32 faces" "SubDTruncatedCone built its control net"
sdcheck "SubDDisplayToggle: 4 SubD(s) show the control polygon" "SubDDisplayToggle switched the closed SubDs to the control polygon"
sdcheck "ShrinkWrap: signed-distance wrap with [0-9]* vertices, [0-9]* faces (closed)" "ShrinkWrap built a closed signed-distance wrap"
sdcheck "Volume = 3[0-9][0-9][0-9] cubic" "ShrinkWrap volume is close to the union of the wrapped solids"
sdcheck "InsertPoint: 1 point(s) inserted on edges" "InsertPoint split an edge on the new box"
sdcheck "Slide: vertex moved" "Slide moved the picked vertex along its best-aligned edge"
sdcheck "SubDSpinEdge: 1 edge(s) spun" "SubDSpinEdge spun the picked edge"
sdcheck "SubDExpandEdges: 2 strip face(s) added, width 1" "SubDExpandEdges added a strip on both sides of the picked edge"
# PackSubDFaces: a real per-face planar-unwrap + shelf-bin-packing UV atlas,
# not just a face count. These checks are programmatic, not "didn't crash":
# the command's own printed UV bounds/overlap-count/coverage are themselves
# computed directly from the packed rectangles (UnwrapFacesLocally/
# ShelfPackFaces in cmd_subd.cpp) - "within [0,1]x[0,1]" is a real bounds
# check against every placed corner, "0 overlapping island pair(s)" a real
# brute-force pairwise rectangle-overlap check, and the coverage percentage
# the actual packed-content-area fraction of the unit square, not eyeballed.
sdcheck "PackSubDFaces: object 11: 6 face(s) packed independently (own island each, no adjacent-face grouping) via per-face planar unwrap + shelf bin-packing; UV bounds \[0\.[0-9]*,0\.[0-9]*\]x\[0\.[0-9]*,0\.[0-9]*\] within \[0,1\]x\[0,1\], 0 overlapping island pair(s), coverage 5[0-9]\.[0-9]*%" "PackSubDFaces built a real, non-overlapping, in-bounds UV atlas for a plain SubD box (6 faces) with reasonable (~53%) coverage"
sdcheck "PackSubDFaces: object 12: 48 face(s) packed independently (own island each, no adjacent-face grouping) via per-face planar unwrap + shelf bin-packing; UV bounds \[0\.[0-9]*,0\.[0-9]*\]x\[0\.[0-9]*,0\.[0-9]*\] within \[0,1\]x\[0,1\], 0 overlapping island pair(s), coverage [3-9][0-9]\.[0-9]*%" "PackSubDFaces built a real, non-overlapping, in-bounds UV atlas for a SubD sphere (48 faces) with reasonable (>=30%) coverage"
sdcheck "gl_error=0" "subd script ran without OpenGL errors"
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

# SubD parity (app_subd_mesh): ToNURBS closes a SubD into a watertight solid,
# ToSubD verifies a smooth Brep and creases feature edges, SubD booleans work
# on the operands' limit surfaces with a creased cut, and SubD symmetry
# (radial / two-plane / welded live copy / crease-preserving Reflect) - all
# measured through the real app (see subd_parity_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SPAR="$(timeout 900 "$BIN" --smoke 300 --script "$HERE/subd_parity_script.txt" 2>&1)" || { echo "$SPAR"; echo "FAIL: subd parity script exited non-zero"; exit 1; }
else
  SPAR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 300 --script "$HERE/subd_parity_script.txt" 2>&1)" || { echo "$SPAR"; echo "FAIL: subd parity script exited non-zero"; exit 1; }
fi
sparcheck() { if grep -q -- "$1" <<<"$SPAR"; then echo "ok   $2"; else echo "FAIL $2"; near "$SPAR" "$1"; fail=1; fi; }
# (1) ToNURBS: closed SubD -> closed polysurface (was: 240 faces, open, Volume refused)
sparcheck "ToNURBS: watertight conversion of a 6-face SubD (3 Catmull-Clark refinement round(s) first): 384 bicubic patches (360 exact limit patches, 24 Coons patches on the shared edge curves; 744 exact + 24 Hermite edge curves), joined 768 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes, manifold; max distance of 3456 patch samples from the Subdivide(+2) limit reference 0\.00[0-9]*" "ToNURBS turns SubDBox into 384 bicubic patches (360 exact + 24 Coons) joined at 1e-6 into a closed manifold solid with 0 naked edges, within 0.01 of the limit surface"
sparcheck "384 faces, 1536 edges, closed solid" "the ToNURBS result of SubDBox lists as a closed solid (before: 240 faces, open)"
sparcheck "ToNURBS: watertight conversion of a 48-face SubD (3 Catmull-Clark refinement round(s) first): 2304 bicubic patches (2016 exact limit patches, 288 Coons patches on the shared edge curves; 4320 exact + 288 Hermite edge curves), joined 4608 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes, manifold" "ToNURBS closes the triangulated-cage SubD sphere (almost every vertex extraordinary) into a closed manifold solid with 0 naked edges (before: 2304 faces, open)"
sparcheck "2304 faces, 9216 edges, closed solid" "the ToNURBS result of the SubD sphere lists as a closed solid"
sparcheck "384 bicubic patches (312 exact limit patches, 72 Coons patches on the shared edge curves; 696 exact + 72 Hermite edge curves), joined 768 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes" "ToNURBS of a box with 4 creased edges is also a closed solid (crease chains are shared exact cubic B-spline curves: 696 exact edge curves)"
# (2) Brep -> SubD
sparcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); cage interpolated onto the Brep surface (limit surface passes through every cage vertex: [0-9]* iteration(s), residual 0\.0000[0-9]*), 0 feature edge(s) creased" "ToSubD on a Brep sphere VERIFIES: measured limit-surface deviation < 0.001 (before: 0 of 1 verified, 0.0202) with the cage interpolated onto the surface"
sparcheck "18240 faces, 27360 edges, 9122 vertices, 0 creases" "the verified sphere SubD is the 96 x 96 grid cage (Euler 9122 - 27360 + 18240 = 2)"
sparcheck "64 feature edge(s) creased" "ToSubD on a cylinder creases its 64 rim edges (two 32-segment circles) instead of rounding them off (before: 512 rim edges of the 256-segment mesher cage)"
sparcheck "352 faces, 704 edges, 354 vertices, 64 creases" "the cylinder SubD is the analytic 352-face cage (32 x 5 wall + two 64-face O-grid caps, Euler 354 - 704 + 352 = 2) with the 64 rim creases (before: 11894 faces, 512 creases)"
sparcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); analytic revolved-solid cage (32 segments around x 5 along the wall" "the cylinder (trimmed planar caps the grid tessellation cannot weld) is now built as an analytic wall + cap cage and VERIFIED, deviation measured against the exact surface (before: 0 of 1 verified, 0.02x)"
# (3) SubD booleans on the limit surfaces
sparcheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), 815 face(s), 158 crease edge(s) (158 on the cut seam, 0 along operand creases, 0 sharp-angle); cage interpolated onto the Boolean surface" "BooleanUnion of two overlapping SubD boxes: 815 faces, the 158 edges of the cut seam are creases"
sparcheck "BooleanDifference: SubD boolean (operands refined to their limit surfaces, seam creased), 640 face(s), 160 crease edge(s) (160 on the cut seam" "BooleanDifference: 640 faces, 160 seam creases"
sparcheck "BooleanIntersection: SubD boolean (operands refined to their limit surfaces, seam creased), 462 face(s), 159 crease edge(s) (159 on the cut seam" "BooleanIntersection: 462 faces, 159 seam creases"
sparcheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), [0-9]* face(s), 64 crease edge(s) (0 on the cut seam, 64 along operand creases" "a creased operand's 8 crease edges survive the union (64 crease edges along operand creases after 3 refinement rounds)"
sparcheck "Crease edges: 158" "the union SubD reports its 158 crease edges in What"
# volumes in script order: ToNURBS x3, ToSubD x2, union, difference, intersection, Reflect, Weld=No
mapfile -t SPAR_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SPAR" | awk '{print $3}')
if [ "${#SPAR_VOLS[@]}" -ge 10 ]; then
  echo "ok   subd parity script printed ${#SPAR_VOLS[@]} volumes"
  # The two boxes are translates of each other, so |A union B| = |A-B| + |A intersect B| + |B-A| = 2|A-B| + |A intersect B|.
  SPAR_RES="$(awk -v u="${SPAR_VOLS[5]}" -v d="${SPAR_VOLS[6]}" -v i="${SPAR_VOLS[7]}" 'BEGIN{r=u-(2*d+i); if(r<0) r=-r; printf "%.4f", r}')"
  if awk -v r="$SPAR_RES" 'BEGIN{exit !(r<0.05)}'; then echo "ok   SubD booleans are mutually consistent: union ${SPAR_VOLS[5]} = 2 x difference ${SPAR_VOLS[6]} + intersection ${SPAR_VOLS[7]} (residual $SPAR_RES < 0.05)"; else echo "FAIL SubD boolean volumes inconsistent: union ${SPAR_VOLS[5]}, difference ${SPAR_VOLS[6]}, intersection ${SPAR_VOLS[7]} (residual $SPAR_RES)"; fail=1; fi
  if awk -v a="${SPAR_VOLS[0]}" 'BEGIN{exit !(a>300 && a<340)}'; then echo "ok   ToNURBS SubDBox volume ${SPAR_VOLS[0]} (a smooth cube blob, in 300..340)"; else echo "FAIL ToNURBS SubDBox volume ${SPAR_VOLS[0]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[3]}" 'BEGIN{exit !(a>523 && a<525)}'; then echo "ok   verified sphere SubD encloses ${SPAR_VOLS[3]} (true sphere 523.6)"; else echo "FAIL sphere SubD volume ${SPAR_VOLS[3]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[8]}" 'BEGIN{exit !(a>1999 && a<2001)}'; then echo "ok   Reflect of a closed SubD box across its far face has volume ${SPAR_VOLS[8]} (two boxes, one body)"; else echo "FAIL Reflect volume ${SPAR_VOLS[8]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[9]}" 'BEGIN{exit !(a>999 && a<1001)}'; then echo "ok   Symmetry Weld=No mirror copy has positive volume ${SPAR_VOLS[9]} (outward winding)"; else echo "FAIL Weld=No mirrored copy volume ${SPAR_VOLS[9]}"; fail=1; fi
else
  echo "FAIL subd parity script printed only ${#SPAR_VOLS[@]} volumes (expected 10)"; fail=1
fi
# (4) symmetry
sparcheck "Symmetry: 1 live radial copy created (1 welded into one SubD with creases kept \[128 faces, 32 crease edges\])" "Symmetry Mode=Radial Count=4 welds a 32-face triangulated sector into one 128-face SubD"
sparcheck "Bounding box: (290, -10, 0) to (310, 10, 0)" "the radial SubD spans the full 20 x 20 about the axis through (300, 0)"
sparcheck "Symmetry: 1 live two-plane copy created (1 welded into one SubD with creases kept \[128 faces, 32 crease edges\])" "Symmetry Mode=TwoPlane mirrors the sector across two perpendicular planes into one 128-face SubD"
sparcheck "Bounding box: (390, -10, 0) to (410, 10, 0)" "the two-plane SubD spans the full 20 x 20"
sparcheck "Reflect: mirrored across the plane through 510,0,0 and welded original . mirror image into one symmetric SubD (10 faces)" "Reflect of a closed SubD box across its own far-face plane drops the shared wall: 10 faces"
sparcheck "10 faces, 20 edges, 12 vertices, 0 creases" "the reflected box is one closed body (Euler 12 - 20 + 10 = 2)"
sparcheck "Crease edges: 8" "Reflect mirrors the 4 creased edges of the source onto the other half (4 + 4 = 8 crease edges)"
sparcheck "Symmetry: 1 live mirrored copy created (1 welded into one SubD with creases kept \[64 faces, 32 crease edges\])" "Symmetry on a SubD plane welds source + mirror into one 64-face SubD by default"
sparcheck "Bounding box: (785, 0, 0) to (815, 10, 0)" "the live symmetric copy first spans the source plus its mirror about x = 800"
sparcheck "Bounding box: (775, 0, 0) to (825, 10, 0)" "after the source is MOVED +10 the live symmetric copy re-derived itself and now spans (775 .. 825) - a live link, rebuilt from the changed cage"
sparcheck "Bounding box: (730.608[0-9]*, 0.60763[0-9]*, 0.60763[0-9]*) to (739.39[0-9]*, 9.3923[0-9]*, 9.3923[0-9]*)" "Symmetry Weld=No gives a separate mirror copy on the other side of the plane (x 730.6 .. 739.4)"
sparcheck "gl_error=0" "subd parity script ran without OpenGL errors"
sparcheck "smoke: frames=[0-9]* objects=24" "subd parity script produced the expected object count"

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
sxcheck B_box_minus_cyl "BooleanDifference: exact B-rep boolean (no tessellation, general engine), 7 face(s), sealed: valid B-rep with real inner loops" "box minus a through-hole cylinder is the General engine's result sewn into a closed solid (before: an 'open' polysurface that Volume refused)"
sxcheck B_box_minus_cyl "(polysurface)" "...and stays a polysurface (not a mesh)"
sxcheck B_box_minus_cyl "faces, [0-9]* edges, closed solid" "...List reports it as a closed solid (before: 188 edges, open)"
sxvol B_box_minus_cyl 873.5 875.5 "box minus a through-hole cylinder: Volume = 1000 - pi*2^2*10 = 874.34 (before: 'Object 3 is not closed', Volume 0)"
sxcheck B_box_minus_cyl "mesh cross-check" "...every accepted exact result prints its independent mesh-boolean cross-check volume"
sxcheck B_box_minus_cyl "Area = " "...and Area works on it"
sxcheck B_box_minus_blind "8 face(s), sealed: valid B-rep with real inner loops" "blind hole: exact, closed"
sxvol B_box_minus_blind 936.2 938.2 "blind hole Volume = 1000 - pi*4*5 = 937.17"
sxcheck B_box_plus_boss "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sealed: valid B-rep with real inner loops" "boss: exact, closed"
sxvol B_box_plus_boss 1139.5 1143 "cylindrical boss Volume = 1000 + pi*9*5 = 1141.37"
sxcheck B_tube "4 face(s), sealed: valid B-rep with real inner loops" "tube (cylinder minus coaxial cylinder): exact, closed"
sxvol B_tube 656 662 "tube Volume = pi*(25-4)*10 = 659.73"
sxcheck B_cyl_stack "5 face(s), sealed: valid B-rep with real inner loops" "stacked cylinders union: exact, closed"
sxvol B_cyl_stack 343 347.5 "stacked cylinders Volume = pi*9*10 + pi*4*5 = 345.58"
sxcheck B_cyl_minus_sphere "4 face(s), sealed: valid B-rep with real inner loops" "cylinder minus a dome-cutting sphere: exact, closed"
sxvol B_cyl_minus_sphere 649 653.5 "dome cut Volume = 250*pi - 2/3*pi*64 = 651.36"
sxcheck B_two_holes_at_once "8 face(s), sealed: valid B-rep with real inner loops" "two holes cut in one Boolean (cutters selected together): exact, closed"
sxvol B_two_holes_at_once 857.5 860.5 "two holes Volume = 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_small "closed solid" "the same hole at 1/10 size is still exact and closed"
sxvol B_scale_small 0.870 0.880 "1/10-size hole Volume = 1 - pi*0.04*1 = 0.8743"
# --- Declined with a reason; the result is a closed mesh (never an open polysurface)
sxcheck B_sphere_plus_box "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 7 face(s), sealed: valid B-rep with real inner loops" "box + sphere is now an exact B-rep (before: declined 'the sewn result does not tessellate to a closed mesh' because the display mesh's keyhole-corridor gaps were only closeable by a weld that also fused the sphere's pole fan; the mesher now re-welds only boundary vertices)"
sxcheck B_sphere_plus_box "(polysurface)" "...and the result is a polysurface, not a mesh"
sxvol B_sphere_plus_box 1130 1136 "box + sphere exact result is a closed solid with Volume = 1000 + 2/3*pi*64 = 1134.04"
sxcheck B_cyl_offaxis "exact B-rep boolean declined (dino8::kernel::BooleanCombineGeneral: an edge is claimed by 3 or more fragment loops" "off-axis cylinder union: the engine's own refusal is printed as the reason"
sxcheck B_chain "re-evaluated from the recorded original operands (the base and 2 tool(s) in one pass" "a second SEQUENTIAL hole is now exact (before: declined 'gaps between faces that sewing could not close'): re-evaluated as base minus both cutters in one pass"
sxcheck B_chain "(polysurface)" "...and the result is a polysurface, not a mesh"
sxvol B_chain 857 861 "...and its Volume is 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_large "7 face(s), sealed: valid B-rep with real inner loops" "100x-size hole is now exact and closed (before: declined 'exact B-rep boolean declined' because the uniform re-weld could not close the display mesh; the boundary-only re-weld does)"
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
elif [ "${DINO8_REQUIRE_TUTORIALS:-0}" = "1" ]; then
  # CI sets DINO8_REQUIRE_TUTORIALS=1: a runner without ffmpeg must not silently stop testing the pipeline.
  echo "FAIL TUT_: the tutorial pipeline is required (DINO8_REQUIRE_TUTORIALS=1) but was skipped: needs Linux with ffmpeg, ffprobe and python3"; fail=1
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
# DINO8_REQUIRE_TOUCH=1 (set only by CI) turns every skip below into a FAIL, so a
# runner that lost node / playwright / xvfb-run cannot silently stop testing the PWA.
tch_skip() {
  if [ "${DINO8_REQUIRE_TOUCH:-0}" = "1" ]; then
    echo "FAIL TCH_touch: Dino 8 Touch PWA test is required (DINO8_REQUIRE_TOUCH=1) but was skipped: $1"
    fail=1
  else
    echo "skip TCH_ Dino 8 Touch PWA test ($1)"
  fi
}
if ! command -v node >/dev/null 2>&1; then
  tch_skip "node is not installed"
elif ! (cd "$HERE/../touch" && node -e "require('playwright')") >/dev/null 2>&1; then
  # Resolved from touch/ (where CI runs npm ci), the same place the test itself requires it from.
  tch_skip "the node 'playwright' package is not installed"
elif ! command -v xvfb-run >/dev/null 2>&1; then
  tch_skip "xvfb-run is not installed"
elif [ ! -f "$TCH_TEST" ]; then
  tch_skip "$TCH_TEST not found"
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
b2s_check chain2 "exact B-rep boolean (no tessellation, general engine), 7 face(s), sealed: valid B-rep with real inner loops" "first hole is exact and closed"
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
b2s_check box_sphere "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 7 face(s), sealed: valid B-rep with real inner loops" "box + sphere is exact (before: declined, mesh)"
b2s_check box_sphere "7 faces, [0-9]* edges, closed solid" "...7 faces (5 box + box top with the circle removed + hemisphere), closed solid"
b2s_num box_sphere Volume 1130 1136 "box + upper hemisphere: 1000 + 2/3*pi*64 = 1134.04"
b2s_num box_sphere Area 646 655 "area = 600 - pi*16 + 2*pi*16 = 650.27"
b2s_check box_sphere_shell "Shell: thickness 0.5, closed, volume" "a Shell takes the box + sphere result as a closed solid (mesh construction: a curved face has no exact kernel shell)"
b2s_check box_sphere_sphere "re-evaluated from the recorded original operands" "box + sphere, then + a second sphere: exact"
b2s_check box_sphere_sphere "8 faces, [0-9]* edges, closed solid" "...8 faces, closed solid"
b2s_num box_sphere_sphere Volume 1264 1272 "1000 + 2*(2/3*pi*64) = 1268.08"
b2s_check box_two_spheres "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sealed: valid B-rep with real inner loops" "box + two spheres in one Boolean is exact (the left-to-right fold fails; the retry unites the spheres first)"
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
h2r_has "$H4R_E" "History: source object(s) 8 changed" "H4R_ext: moving the contoured second box is noticed"
h4r_sl "$H4R_E" 8 159.9 1 "H4R_ext: the second box's four contour curves are rebuilt, total loop length 4*40 (a box has no platform-dependent pieces)"
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

# SABF: ACIS SAB (.sab binary) through Import/Export/Open/SaveAs (sabf_script.txt,
# sabf_detect_script.txt; io/FileSat.cpp over the kernel's ReadAcis/WriteAcisSab).
# The SAB byte layout (token tags, header, bool encoding) is UNVERIFIED - no public
# description was reachable - and the writer has only been read back by this
# program's own reader, so these checks pin the app wiring and the honesty of the
# printed summary (UNVERIFIED notices, refusals with a reason), not compatibility
# with another CAD system. Ranges, not exact numbers.
printf 'this is not an ACIS binary file\n' > "$TMPW/sabf_bad.sab"
printf 'ACIS BinaryFile\274\002\000\000' > "$TMPW/sabf_trunc.sab"
sed "s|@TMP@|$TMPW|g" "$HERE/sabf_script.txt" > "$TMPW/sabf_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SABF="$(timeout 900 "$BIN" --smoke 40 --script "$TMPW/sabf_script.txt" 2>&1)" || { echo "$SABF"; echo "FAIL: sabf script exited non-zero"; exit 1; }
else
  SABF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 40 --script "$TMPW/sabf_script.txt" 2>&1)" || { echo "$SABF"; echo "FAIL: sabf script exited non-zero"; exit 1; }
fi
sabf_has() { if grep -qF -- "$1" <<<"$SABF"; then echo "ok   $2"; else echo "FAIL $2"; near "$SABF" "$1"; fail=1; fi; }
sabf_count() { local n; n="$(grep -cF -- "$1" <<<"$SABF" || true)"; if [ "${n:-0}" -ge "$2" ]; then echo "ok   $3 ($n >= $2)"; else echo "FAIL $3 (got ${n:-0}, expected >= $2)"; near "$SABF" "$1"; fail=1; fi; }
sabf_range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t SABF_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SABF" | awk '{print $3}' || true)
sabf_has "SAB export sabf_box.sab (ACIS 7.0 binary, version 700): 1 of 1 object(s) written" "SABF_box_export: Export of a box to .sab wrote 1 of 1 objects and says ACIS 7.0 binary"
sabf_has "SAB import sabf_box.sab: 1 Brep body(ies) read" "SABF_box_open: Open of the .sab box read one Brep body and names the SAB encoding"
sabf_has "closed solid" "SABF_box_solid: the imported box is reported as a closed solid"
sabf_count "SAB status: the binary token tags, header layout and two-valued-word encoding are UNVERIFIED" 6 "SABF_unverified_note: every SAB export and import summary carries the UNVERIFIED-byte-layout note"
sabf_count "never against a file from a real ACIS-based product" 6 "SABF_selftest_only: ...and says it was only tested against this program's own reader"
if [ "${#SABF_VOLS[@]}" -ge 4 ]; then
  sabf_range "${SABF_VOLS[0]}" 3999.5 4000.5 "SABF_box_vol_before: box Volume before export (20 x 20 x 10 = 4000)"
  sabf_range "${SABF_VOLS[1]}" 3999.5 4000.5 "SABF_box_vol_after: box Volume after .sab export and Open (4000)"
  sabf_range "${SABF_VOLS[2]}" 2090 2160 "SABF_sphere_vol: sphere Volume after .sab export and Import vs 4/3 pi r^3 = 2144.7"
  sabf_range "${SABF_VOLS[3]}" 770 800 "SABF_cyl_vol: cylinder Volume after .sab export and Open vs pi r^2 h = 785.4"
else
  echo "FAIL SABF script printed only ${#SABF_VOLS[@]} Volume lines (expected 4)"; fail=1
fi
sabf_has "SAB import sabf_sphere.sab: 1 Brep body(ies) read" "SABF_sphere_import: Import of the .sab sphere read one body"
sabf_count "UNVERIFIED LAYOUT: the bodies marked above" 2 "SABF_unverified_layout_export: sphere and cylinder .sab exports both disclose the UNVERIFIED surface layout"
sabf_count "UNVERIFIED LAYOUT: 1 of 1 bodies use cone/sphere/torus/ellipse entities" 2 "SABF_unverified_layout_import: sphere and cylinder .sab imports both disclose it"
sabf_has "SAB export wrote nothing" "SABF_mesh_refused: exporting only a mesh to .sab writes nothing"
sabf_has "SAB export writes Brep bodies only" "SABF_mesh_reason: ...and says why (no body representation for a mesh)"
sabf_has "SAT import refused (sabf_bad.sab)" "SABF_bad_text_refused: a text file under a .sab name is refused with the file name (and read as text, since the encoding comes from the content)"
sabf_has "SAB import refused (sabf_trunc.sab)" "SABF_truncated_refused: a truncated binary header is refused with the file name"
sabf_has "truncated file" "SABF_truncated_reason: ...and the reason says the file is truncated"

# SABF detection: encoding from content, not extension.
cp "$TMPW/satf_box.sat" "$TMPW/sabf_text_as.sab"
cp "$TMPW/sabf_box.sab" "$TMPW/sabf_bin_as.sat"
sed "s|@TMP@|$TMPW|g" "$HERE/sabf_detect_script.txt" > "$TMPW/sabf_detect_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SABFD="$(timeout 900 "$BIN" --smoke 40 --script "$TMPW/sabf_detect_script.txt" 2>&1)" || { echo "$SABFD"; echo "FAIL: sabf detect script exited non-zero"; exit 1; }
else
  SABFD="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 40 --script "$TMPW/sabf_detect_script.txt" 2>&1)" || { echo "$SABFD"; echo "FAIL: sabf detect script exited non-zero"; exit 1; }
fi
sabfd_has() { if grep -qF -- "$1" <<<"$SABFD"; then echo "ok   $2"; else echo "FAIL $2"; near "$SABFD" "$1"; fail=1; fi; }
sabfd_has "SAT import sabf_text_as.sab: 1 Brep body(ies) read" "SABF_detect_text: SAT text under a .sab name is read as text and the summary says SAT"
sabfd_has "SAB import sabf_bin_as.sat: 1 Brep body(ies) read" "SABF_detect_binary: SAB bytes under a .sat name are read as binary and the summary says SAB"
mapfile -t SABFD_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SABFD" | awk '{print $3}' || true)
if [ "${#SABFD_VOLS[@]}" -ge 2 ]; then
  sabf_range "${SABFD_VOLS[0]}" 3999.5 4000.5 "SABF_detect_text_vol: the text-as-.sab box has Volume 4000"
  sabf_range "${SABFD_VOLS[1]}" 3999.5 4000.5 "SABF_detect_binary_vol: the binary-as-.sat box has Volume 4000"
else
  echo "FAIL SABF detect script printed only ${#SABFD_VOLS[@]} Volume lines (expected 2)"; fail=1
fi


# ---------------------------------------------------------------------------
# PTF_: rolling-ball fillet of the SADDLE edge of a perpendicular pipe tee (ptf_script.txt).
# FilletEdge now ends its exact attempts with kernel::FilletPipeTee (cmd_fillet.cpp TryPipeTeeFillet / EdgeOnPipeTeeSaddle),
# tried ONLY after the capped-cylinder / frustum, hole-plate and revolve-rim paths declined. The fixture is the app's own
# sealed Boolean union (TryGeneralBrepBoolean, "5 face(s), sealed: valid B-rep") of a main cylinder (R = 2, z = -3 .. 3) and
# a branch cylinder (rb = 1, from the axis crossing along +y to y = 5, ending in its own planar cap).
# Independent values (a standalone program, not the kernel's code): the plain tee is V = pi R^2 H + pi rb^2 L - overlap,
# overlap = integral 2 sqrt(rb^2 - y^2) sqrt(R^2 - y^2) dy (2e6-point midpoint rule) -> V = 85.0260; the filleted solid adds
# dV by the divergence theorem, (1/3)[ integral over the blend of p.n dS - R^2 (main-wall strip area in (theta, z)) -
# rb^2 (branch-wall strip area) ], the blend sampled by the ball's arc ANGLE (not the kernel's rational quadratic):
#   r = 0.4: dV = 0.1257 -> 85.1517      r = 1.0: dV = 0.7685 -> 85.7945
# Volume is read from the display mesh, which measures 0.2-0.25% BELOW the analytic value here (84.81 against 85.026 for the
# unfilleted tee), so each window is the analytic value minus that bias (-0.25%) up to +0.05%. The r = 0.4 fillet adds only
# 0.15% (0.126), barely more than the mesh bias, so its window (84.92 .. 85.20) is only just clear of the unfilleted tee
# (84.81); the r = 1 window (85.45 .. 85.85, dV = 0.77) is clear of it by 0.64. Counts ("6 faces, 8 edges, closed solid",
# "Object 3: valid", objects) are topological and exact. The blend is a NURBS fit to the exact rolling-ball surface
# (tolerance 1e-6, sampled at interval midpoints), so every message says "fitted"; ptfdev reads the reported deviation back.
# The kernel result (tangency, ball radius and normals measured along the whole edge, exact volume) is pinned by
# pipe_tee_fillet_tests in dino8-kernel/tests/test_basic.cpp; this section pins the WIRING.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PTFO="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/ptf_script.txt" 2>&1)" || { echo "$PTFO"; echo "FAIL: ptf script exited non-zero"; exit 1; }
else
  PTFO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/ptf_script.txt" 2>&1)" || { echo "$PTFO"; echo "FAIL: ptf script exited non-zero"; exit 1; }
fi
ptfblock() { awk -v name="$1" '$0 ~ ("Unknown command: PTFBEGIN_" name "$") { on = 1; next } on && /Unknown command: PTFBEGIN_/ { exit } on { print }' <<<"$PTFO"; }
ptfcheck() { local blk; blk="$(ptfblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (FilletEdge|ChamferEdge|!|Object|  [0-9]|Volume)" <<<"$blk" | head -8 | sed 's/^/     actual:   /' || true; fail=1; fi; }
ptfnot() { local blk; blk="$(ptfblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "FAIL $3"; echo "     unexpected: $2"; fail=1; else echo "ok   $3"; fi; }
# ptfnum NAME MIN MAX DESC: the case's last "Volume = V" lies in [MIN, MAX]
ptfnum() {
  local blk v; blk="$(ptfblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# ptfobjs NAME N DESC: the case's List shows exactly N objects
ptfobjs() {
  local blk n; blk="$(ptfblock "$1")"
  n="$(grep -cE "^history: Object [0-9]+ \(" <<<"$blk" || true)"
  if [ "$n" = "$2" ]; then echo "ok   $3 ($n object(s))"; else echo "FAIL $3 ('$n' object(s), expected $2)"; fail=1; fi
}
# ptfdev NAME MAXDEV DESC: the reported "sampled deviation X over N intervals" has 0 < X <= MAXDEV and N >= 1
ptfdev() {
  local blk s d n; blk="$(ptfblock "$1")"
  s="$(grep -oE "sampled deviation [0-9.eE+-]+ over [0-9]+ intervals" <<<"$blk" | tail -1 || true)"
  d="$(sed -E 's/sampled deviation ([0-9.eE+-]+) over ([0-9]+) intervals/\1/' <<<"$s")"
  n="$(sed -E 's/sampled deviation ([0-9.eE+-]+) over ([0-9]+) intervals/\2/' <<<"$s")"
  if [ -n "$s" ] && awk -v d="$d" -v n="$n" -v hi="$2" 'BEGIN { exit !(d > 0 && d <= hi && n >= 1) }'; then echo "ok   $3 (deviation $d over $n intervals, <= $2)"; else echo "FAIL $3 (reported '${s:-none}', wanted deviation <= $2)"; fail=1; fi
}
PTF_MSG="saddle edge of pipe-tee object 3 replaced with a rolling-ball fillet"
# --- fixture: the sealed union of the two cylinders (no fillet)
ptfcheck base "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 5 face(s), sealed: valid B-rep" "PTF_base: the fixture is the app's SEALED Boolean union, 5 faces"
ptfcheck base "5 faces, [0-9]* edges, closed solid" "PTF_base: 5 faces, closed solid"
ptfcheck base "Object 3: valid" "PTF_base: Check valid"
ptfnum base 84.6 85.03 "PTF_base: unfilleted tee, analytic V = 85.026 (display mesh reads ~0.25% low)"
ptfnot base "pipe-tee" "PTF_base: ...no pipe-tee path involved"
# --- fillet r = 0.4
ptfcheck F_r04 "FilletEdge: saddle edge of pipe-tee object 3 staged for a kernel rolling-ball fillet (radius 0.4) - 1 staged, Enter to apply" "PTF_F_r04: the saddle pick is staged by the kernel pipe-tee path (before: mesh fallback)"
ptfcheck F_r04 "FilletEdge: $PTF_MSG (radius 0.4, main radius 2, branch radius 1; analytic cylinder walls, blend fitted to the exact rolling-ball surface with sampled deviation" "PTF_F_r04: applied, message states radii and that the blend is FITTED"
ptfdev F_r04 1e-6 "PTF_F_r04: reported fit deviation is within the 1e-6 tolerance"
ptfcheck F_r04 ", 6 faces, closed solid)" "PTF_F_r04: message states 6 faces, closed solid"
ptfcheck F_r04 "6 faces, 8 edges, closed solid" "PTF_F_r04: List: 6 faces (the 5 of the union + the blend), 8 edges, closed solid"
ptfcheck F_r04 "Object 3: valid" "PTF_F_r04: Check valid"
ptfobjs F_r04 1 "PTF_F_r04: replaced in place, no mesh object left behind"
ptfnum F_r04 84.92 85.20 "PTF_F_r04: independent V = 85.026 + 0.1257 = 85.152 (the unfilleted tee reads 84.81, outside)"
ptfnot F_r04 "mesh fallback" "PTF_F_r04: ...no mesh fallback"
# --- fillet r = 1, picked on the other side of the saddle
ptfcheck F_r1 "FilletEdge: $PTF_MSG (radius 1, main radius 2, branch radius 1;" "PTF_F_r1: r = 1 picked at (-1, sqrt 3, 0) is applied too"
ptfdev F_r1 1e-6 "PTF_F_r1: reported fit deviation is within the 1e-6 tolerance"
ptfcheck F_r1 "6 faces, 8 edges, closed solid" "PTF_F_r1: 6 faces, 8 edges, closed solid"
ptfcheck F_r1 "Object 3: valid" "PTF_F_r1: Check valid"
ptfobjs F_r1 1 "PTF_F_r1: one object"
ptfnum F_r1 85.45 85.85 "PTF_F_r1: independent V = 85.026 + 0.7685 = 85.794 (display mesh 0.2% low; the unfilleted tee 84.81 is outside)"
# --- the tee turned 37 degrees about its main axis (the kernel reads the frame back from the faces)
ptfcheck F_rot "FilletEdge: $PTF_MSG (radius 0.4, main radius 2, branch radius 1;" "PTF_F_rot: the tee turned 37 degrees about z is filleted"
ptfdev F_rot 1e-6 "PTF_F_rot: reported fit deviation is within the 1e-6 tolerance"
ptfcheck F_rot "6 faces, 8 edges, closed solid" "PTF_F_rot: 6 faces, 8 edges, closed solid"
ptfcheck F_rot "Object 3: valid" "PTF_F_rot: Check valid"
ptfnum F_rot 84.92 85.20 "PTF_F_rot: volume unchanged by the rotation (independent 85.152)"
# --- two picks on the saddle in one run: the whole edge is filleted once
ptfcheck F_two "the saddle edge of this pipe tee is already staged in this FilletEdge run" "PTF_F_two: the second pick on the same saddle is refused with the one-per-run explanation"
ptfcheck F_two "FilletEdge: $PTF_MSG (radius 0.4" "PTF_F_two: ...the first pick is still applied"
ptfcheck F_two "6 faces, 8 edges, closed solid" "PTF_F_two: 6 faces, closed solid"
ptfnum F_two 84.92 85.20 "PTF_F_two: filleted once (independent 85.152), not twice"
# --- refusals carry the kernel's reason and leave the solid alone (the old approximate attempts then run, as before)
ptfcheck R_toobig "kernel pipe-tee fillet not used (dino8::kernel::FilletPipeTee: the ball is too large for the main cylinder: the blend reaches z = +-(rb + r) = 4.000000 but the main cylinder ends at -3.000000 / 3.000000)" "PTF_R_toobig: r = 3 on a main cylinder with half-length 3 is refused WITH the kernel's reason (rb + r = 4 > 3)"
ptfnot R_toobig "$PTF_MSG" "PTF_R_toobig: ...no pipe-tee fillet is claimed"
ptfcheck R_toobig "5 faces, [0-9]* edges, closed solid" "PTF_R_toobig: ...and the tee is left unchanged (5 faces)"
ptfcheck R_shortbranch "kernel pipe-tee fillet not used (dino8::kernel::FilletPipeTee: the ball is too large for the branch: the blend reaches x = R + r = 2.400000 but the branch cap is at 2.200000)" "PTF_R_shortbranch: a branch ending at 2.2 < R + r = 2.4 is refused WITH the kernel's reason"
ptfnot R_shortbranch "$PTF_MSG" "PTF_R_shortbranch: ...no pipe-tee fillet is claimed"
ptfcheck R_nonperp "kernel pipe-tee fillet not used (dino8::kernel::FilletPipeTee: the cylinder axes are not perpendicular (|cos| = 0.342020); only a right-angle tee is supported)" "PTF_R_nonperp: a branch tilted 20 degrees is refused WITH the kernel's reason (|cos 70| = 0.342020)"
ptfnot R_nonperp "$PTF_MSG" "PTF_R_nonperp: ...no pipe-tee fillet is claimed"
ptfcheck R_boxboss "kernel pipe-tee fillet not used (dino8::kernel::FilletPipeTee: the faces are not exactly two distinct cylinders (found 1))" "PTF_R_boxboss: a box with a cylinder boss (curved edge, not a tee) is refused WITH the kernel's reason"
ptfnot R_boxboss "$PTF_MSG" "PTF_R_boxboss: ...no pipe-tee fillet is claimed"
ptfcheck R_offsaddle "kernel pipe-tee fillet not used (the picked edge is not on the saddle edge of the pipe tee" "PTF_R_offsaddle: an edge of the tee that is NOT the saddle (branch cap rim) is refused by the pick gate, with its reason"
ptfnot R_offsaddle "$PTF_MSG" "PTF_R_offsaddle: ...the rim is not hijacked by the tee fillet"
# --- negative controls: every existing exact rim / edge fillet is unchanged and never reaches the tee path
ptfcheck ctl_cyl "cylinder rim(s) of object 1 replaced with an exact fillet (top radius 1; exact quarter-torus patch, 4 faces, closed solid)" "PTF_ctl_cyl: plain cylinder rim fillet still gives the app's pinned message"
ptfnot ctl_cyl "pipe-tee" "PTF_ctl_cyl: ...and never reaches the tee path"
ptfnum ctl_cyl 306.7 308.7 "PTF_ctl_cyl: Pappus Volume = 307.718"
ptfcheck ctl_cyl "Object 1: valid" "PTF_ctl_cyl: Check valid"
ptfcheck ctl_tcone "cap rim(s) of object 1 replaced with an exact fillet (radius 1; exact kernel torus patch tangent to the cap and the wall, 4 faces, closed solid)" "PTF_ctl_tcone: cone frustum rim still takes the kernel cap-rim path"
ptfnot ctl_tcone "pipe-tee" "PTF_ctl_tcone: ...and never reaches the tee path"
ptfnum ctl_tcone 507.7 513.8 "PTF_ctl_tcone: Pappus Volume = 510.74"
ptfcheck ctl_rev "rim of solid-of-revolution object 1 replaced with an exact fillet (radius 3; exact kernel torus patch tangent to both faces at the rim, 5 faces, closed solid)" "PTF_ctl_rev: the chamfered cylinder's bevel rim still takes the kernel revolve-rim path"
ptfnot ctl_rev "pipe-tee" "PTF_ctl_rev: ...and never reaches the tee path"
ptfnum ctl_rev 293.7 295.7 "PTF_ctl_rev: Green volume = 294.723"
ptfcheck ctl_box "edge 5 of object 1 replaced with an exact fillet (radius 1)" "PTF_ctl_box: a box edge is still the kernel's exact planar fillet"
ptfnot ctl_box "pipe-tee" "PTF_ctl_box: ...with no pipe-tee message for an ordinary planar edge"
ptfnum ctl_box 142.5 142.9 "PTF_ctl_box: Volume = 144 - (1 - pi/4)*6 = 142.712"
ptfcheck ctl_box "Object 1: valid" "PTF_ctl_box: Check valid"
if grep -q "gl_error=0" <<<"$PTFO"; then echo "ok   PTF script ran without OpenGL errors"; else echo "FAIL PTF script ran without OpenGL errors"; fail=1; fi

# ---------------------------------------------------------------------------
# CNT_: G0 / G1 / G2 edge continuity on Loft, Patch and NetworkSrf (Continuity= / AngleTol= / CurvTol= options and a click
# on an adjacent surface edge) and the MeasureEdgeContinuity report (cnt_script.txt; kernel: NurbsSurface::LoftMatched,
# FitPatch / FitCurveNetwork with edges, MeasureEdgeContinuity). Every angle / gap / curvature checked here is a number the
# app printed from the kernel's MEASUREMENT of the finished surface against the flat adjacent plane (z = 0, x <= 0), and each
# window below is where the value was measured (+ margin) on this build, not a derived bound:
#   Loft  fixture (sections z = 0.004 x^2): plain 6.37e-05 rad, Tangency 0 rad, section deviation 1.59e-04 (limit 1e-3)
#   Patch fixture (edge line + 2 points at z = 0.5, x = 10): plain 0.05 rad (z = 0.05 x), Tangency 1.2e-12 rad
#   Network fixture (curves with zero slope at the edge): the exact Coons patch is ALREADY G1 (0 rad) - a negative control
#     that the option does not claim an improvement the data do not allow; the fitted result measures 5.9e-08 rad.
# Not verified here: Curvature (G2) on a curved adjacent surface from the app (the flat plane here is degree 1, so G2 is the
# refusal case); the kernel's own G2 numbers are pinned by edge_continuity_tests in dino8-kernel/tests/test_basic.cpp.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  CNTO="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/cnt_script.txt" 2>&1)" || { echo "$CNTO"; echo "FAIL: cnt script exited non-zero"; exit 1; }
else
  CNTO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/cnt_script.txt" 2>&1)" || { echo "$CNTO"; echo "FAIL: cnt script exited non-zero"; exit 1; }
fi
cntblock() { awk -v name="$1" '$0 ~ ("Unknown command: CNTBEGIN_" name "$") { on = 1; next } on && /Unknown command: CNTBEGIN_/ { exit } on { print }' <<<"$CNTO"; }
cntcheck() { local blk; blk="$(cntblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Loft|Patch|NetworkSrf|MeasureEdgeContinuity|!)" <<<"$blk" | head -6 | cut -c1-400 | sed 's/^/     actual:   /' || true; fail=1; fi; }
cntnot() { local blk; blk="$(cntblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "FAIL $3"; echo "     unexpected: $2"; fail=1; else echo "ok   $3"; fi; }
# cntval NAME LINE_REGEX PREFIX: the number right after PREFIX in the last line of the case matching LINE_REGEX (empty if none)
cntval() { local blk; blk="$(cntblock "$1")"; grep -E "$2" <<<"$blk" | tail -1 | sed -nE "s/.*$3([0-9.eE+-]+).*/\1/p" || true; }
# cntnum NAME LINE_REGEX PREFIX MIN MAX DESC
cntnum() {
  local v; v="$(cntval "$1" "$2" "$3")"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$4" -v hi="$5" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $6 ($3$v in [$4, $5])"; else echo "FAIL $6 ('$3${v:-none}' not in [$4, $5])"; fail=1; fi
}
# cntratio NAME_A LINE_A NAME_B LINE_B PREFIX FACTOR DESC: value in case A is below (value in case B) / FACTOR
cntratio() {
  local a b; a="$(cntval "$1" "$2" "$5")"; b="$(cntval "$3" "$4" "$5")"
  if [ -n "$a" ] && [ -n "$b" ] && awk -v a="$a" -v b="$b" -v f="$6" 'BEGIN { exit !(a < b / f) }'; then echo "ok   $7 (${5}${a} vs without the option ${b}, factor > $6)"; else echo "FAIL $7 ('${a:-none}' vs '${b:-none}', need factor > $6)"; fail=1; fi
}
cntobjs() {
  local n; n="$(cntblock "$1" | grep -cE "^history: Object [0-9]+ \(" || true)"
  if [ "$n" = "$2" ]; then echo "ok   $3 ($n object(s))"; else echo "FAIL $3 ('$n' object(s), expected $2)"; fail=1; fi
}
LOFTM="^history: Loft: G[012] continuity .*MEASURED"
PATCHM="^history: Patch: G[012] continuity .*MEASURED"
NETM="^history: NetworkSrf: G[012] continuity .*MEASURED"
REPM="^history: MeasureEdgeContinuity: object .*MEASURED"
# --- Loft: measured against the same loft without the option
cntcheck loft_plain "exact interpolating kernel loft through 3 curves" "CNT_loft_plain: no option -> the pinned plain loft message"
cntnot loft_plain "Loft: G[012] continuity" "CNT_loft_plain: ...and no continuity machinery runs"
cntnum loft_plain "$REPM" "tangent angle " 4e-5 9e-5 "CNT_loft_plain: MeasureEdgeContinuity measures the plain loft's tangent angle against the plane (6.37e-05 rad)"
cntcheck loft_plain "G1 (and angle <= 8.73e-06 rad) NOT met" "CNT_loft_plain: AngleTol=0.0005 deg (8.73e-06 rad) -> the plain loft is NOT G1"
cntcheck loft_plain "continuity achieved: G0" "CNT_loft_plain: ...it is G0 only"
cntobjs loft_plain 5 "CNT_loft_plain: plane + 3 sections + 1 loft"
cntcheck loft_g1 "Loft: G1 continuity to object 1, V=max edge: kernel LoftMatched through 3 curves (degree 2 in the loft direction), the first section made identical to the edge" "CNT_loft_g1: Continuity=Tangency picks the plane's edge and calls LoftMatched"
cntnum loft_g1 "$LOFTM" "tangent angle " 0 1e-6 "CNT_loft_g1: the loft's own MEASURED tangent angle is ~0 (printed 0 rad)"
cntnum loft_g1 "$REPM" "tangent angle " 0 1e-6 "CNT_loft_g1: MeasureEdgeContinuity run separately agrees (0 rad)"
cntratio loft_g1 "$REPM" loft_plain "$REPM" "tangent angle " 1000 "CNT_loft_g1: ... versus 6.37e-05 rad for the same loft without the option"
cntnum loft_g1 "$REPM" "position gap " 0 1e-6 "CNT_loft_g1: measured position gap"
cntnum loft_g1 "$LOFTM" "from the finished surface " 0 1e-3 "CNT_loft_g1: worst section deviation within the document tolerance 0.001 (printed 1.59e-04)"
cntnum loft_g1 "$LOFTM" "cross-edge curvature difference " 0.007 0.009 "CNT_loft_g1: G1 leaves the cross-edge curvature difference where the data put it (printed 0.00797; plain 0.00796)"
cntcheck loft_g1 "G1 (and angle <= 8.73e-06 rad) met" "CNT_loft_g1: ...so the report says G1 met at the tolerance the plain loft failed"
cntobjs loft_g1 5 "CNT_loft_g1: one new surface"
cntcheck loft_g0 "(position only: the tangent angle and curvature above are reported, not constrained)" "CNT_loft_g0: Continuity=Position says it constrains position only"
cntnum loft_g0 "$LOFTM" "tangent angle " 4e-5 9e-5 "CNT_loft_g0: G0 leaves the tangent angle where the plain loft has it (6.37e-05 rad)"
# refusals carry the kernel's reason and build nothing
cntcheck loft_g2_flat "refused by the kernel .*MatchEdge refused (non-clamped surface, adjacent surface of too low a degree, or a self-check failure); nothing was built" "CNT_loft_g2_flat: G2 against a degree-1 plane is refused WITH the kernel's reason"
cntobjs loft_g2_flat 4 "CNT_loft_g2_flat: nothing was built"
cntcheck loft_incompat "matching the adjacent surface moves section 2 by 0.0185" "CNT_loft_incompat: sections that do not leave the plane tangentially: refused, section 2 would move 0.0185 > 0.001"
cntnum loft_incompat "^history: ! Loft: " "moves section 2 by " 0.017 0.020 "CNT_loft_incompat: ...the stated section move"
cntobjs loft_incompat 4 "CNT_loft_incompat: nothing was built"
cntcheck loft_off "start section lies up to 5.000000 from the adjacent surface, more than the tolerance 0.001000: position (G0) continuity is not met" "CNT_loft_off: a section 5 off the picked edge: G0 not met, refused with the measured gap"
cntobjs loft_off 4 "CNT_loft_off: nothing was built"
cntcheck loft_nopick "no adjacent surface edge was picked, so nothing was built (G1 was requested)" "CNT_loft_nopick: Enter instead of an edge: nothing built, said so"
cntobjs loft_nopick 4 "CNT_loft_nopick: nothing was built"
cntcheck loft_badvalue "Continuity must be None, Position (G0), Tangency (G1) or Curvature (G2), not 'Bogus'" "CNT_loft_badvalue: a bad Continuity value is refused with its reason"
cntcheck loft_badvalue "exact interpolating kernel loft through 3 curves" "CNT_loft_badvalue: ...and the plain loft runs unchanged"
cntobjs loft_badvalue 5 "CNT_loft_badvalue: the plain loft was built"
cntcheck loft_tol "angle tolerance 1.75e-06 rad" "CNT_loft_tol: AngleTol=0.0001 degrees is carried as 1.75e-06 rad"
# History: a continuity result is not recorded, the reason is printed; the plain loft's recording path is untouched
cntcheck loft_hist "Loft: no history recorded - a G1 rebuild would need the adjacent surface edge as a recorded input" "CNT_loft_hist: History On + Continuity: recording refused, reason printed"
cntcheck loft_hist "exact interpolating kernel loft through 3 curves" "CNT_loft_hist: ...a plain loft in the same History On document still builds"
cntnot loft_hist_plain "no history recorded" "CNT_loft_hist_plain: History On + plain Loft prints no refusal"
cntcheck loft_hist_plain "exact interpolating kernel loft through 3 curves" "CNT_loft_hist_plain: ...and builds as before"
# --- Patch
cntcheck patch_plain "Patch: least-squares plane through 1 curve(s) and 2 point(s)" "CNT_patch_plain: no option -> the pinned plain Patch message"
cntnum patch_plain "$REPM" "tangent angle " 0.049 0.051 "CNT_patch_plain: the plain fit is the tilted plane z = 0.05 x: MEASURED 0.05 rad to the flat plane"
cntcheck patch_plain "continuity achieved: G0" "CNT_patch_plain: ...G0 only"
cntcheck patch_g1 "Patch: G1 continuity to object 1, V=max edge: selected curve 1 lies on the edge" "CNT_patch_g1: Continuity=Tangency picks the edge, finds the curve on it"
cntnum patch_g1 "$PATCHM" "tangent angle " 0 1e-6 "CNT_patch_g1: the patch's own MEASURED tangent angle (printed 1.22e-12 rad)"
cntnum patch_g1 "$REPM" "tangent angle " 0 1e-6 "CNT_patch_g1: MeasureEdgeContinuity run separately agrees"
cntratio patch_g1 "$REPM" patch_plain "$REPM" "tangent angle " 100000 "CNT_patch_g1: ... > 1e5 times smaller than the 0.05 rad of the same patch without the option"
cntnum patch_g1 "$PATCHM" "worst data deviation " 0 1e-3 "CNT_patch_g1: the fit still meets the document tolerance (printed 1.12e-08 vs 0.001)"
cntnum patch_g1 "$REPM" "position gap " 0 1e-3 "CNT_patch_g1: measured position gap within the document tolerance"
cntcheck patch_g1 "G1 (and angle <= 0.001 rad) met" "CNT_patch_g1: the report says G1 met"
cntobjs patch_g1 5 "CNT_patch_g1: plane + curve + 2 points + 1 patch"
cntcheck patch_g0 "(position only: the tangent angle and curvature above are reported, not constrained)" "CNT_patch_g0: Continuity=Position says it constrains position only"
cntnum patch_g0 "$PATCHM" "tangent angle " 0.049 0.051 "CNT_patch_g0: G0 leaves the 0.05 rad tilt"
cntcheck patch_g2_flat "curvature continuity requested but the adjacent surface is degree 1 (it has no curvature to continue); nothing was built" "CNT_patch_g2_flat: G2 against a degree-1 plane refused WITH the kernel's reason"
cntobjs patch_g2_flat 4 "CNT_patch_g2_flat: nothing was built"
cntcheck patch_off "the boundary samples lie up to 4.242641 from the adjacent surface, more than the tolerance 0.001000: position (G0) continuity is not met" "CNT_patch_off: the only curve is off the picked edge: refused with the measured distance"
cntobjs patch_off 4 "CNT_patch_off: nothing was built"
cntcheck patch_tol "angle tolerance 1.75e-06 rad" "CNT_patch_tol: AngleTol=0.0001 degrees is carried as 1.75e-06 rad"
cntcheck patch_hist "Patch: no history recorded - a G1 rebuild would need the adjacent surface edge as a recorded input" "CNT_patch_hist: History On + Continuity: recording refused, reason printed"
# --- NetworkSrf
cntcheck net_plain "exact Coons patch through 4 curves" "CNT_net_plain: no option -> the pinned exact Coons message"
cntnum net_plain "$REPM" "tangent angle " 0 1e-6 "CNT_net_plain: the exact Coons patch is ALREADY G1 here (0 rad): the option has no improvement to claim"
cntnum net_plain "$REPM" "cross-edge curvature difference " 0.011 0.013 "CNT_net_plain: its measured cross-edge curvature difference (0.012)"
cntcheck net_g1 "NetworkSrf: G1 continuity to object 1, V=max edge: input curve 1 lies on the edge" "CNT_net_g1: Continuity=Tangency picks the edge, finds the input curve on it"
cntnum net_g1 "$NETM" "tangent angle " 0 1e-5 "CNT_net_g1: the network's own MEASURED tangent angle (printed 5.94e-08 rad)"
cntnum net_g1 "$REPM" "tangent angle " 0 1e-5 "CNT_net_g1: MeasureEdgeContinuity run separately agrees (printed 6.15e-08 rad)"
cntnum net_g1 "$NETM" "position gap " 0 1e-3 "CNT_net_g1: measured position gap within the document tolerance (printed 4.02e-06)"
cntnum net_g1 "$NETM" "worst " 0 1e-3 "CNT_net_g1: every input curve is still within the document tolerance of the surface (worst printed 2.11e-05)"
cntcheck net_g1 "continuity achieved: G1" "CNT_net_g1: the report says G1 (G2 not met: cross-edge curvature difference 0.012 > 0.01)"
cntnot net_g1 "no history recorded" "CNT_net_g1: History Off -> no history message"
cntobjs net_g1 6 "CNT_net_g1: plane + 4 curves + 1 surface"
cntcheck net_g2_flat "curvature continuity requested but the adjacent surface is degree 1 (it has no curvature to continue); nothing was built" "CNT_net_g2_flat: G2 against a degree-1 plane refused WITH the kernel's reason"
cntcheck net_incompat "with the requested edge continuity the fit misses its data by 0.005773, more than the tolerance 0.001000; nothing was built" "CNT_net_incompat: curves that cannot leave the plane tangentially: refused, the fit would miss them by 0.00577"
cntobjs net_incompat 5 "CNT_net_incompat: nothing was built (plane + 4 curves)"
cntcheck net_three "needs 4 or more curves crossing in two directions; 3 curve(s) selected" "CNT_net_three: 3 curves have no continuity option, refused with that reason"
cntobjs net_three 4 "CNT_net_three: nothing was built"
# --- MeasureEdgeContinuity alone
cntnum rep_gap "$REPM" "position gap " 2.99 3.01 "CNT_rep_gap: a loft edge 3 above the plane: measured gap 3"
cntcheck rep_gap "G0 (gap <= 0.001) NOT met" "CNT_rep_gap: G0 NOT met"
cntcheck rep_gap "continuity achieved: none (the edges do not meet within the tolerance)" "CNT_rep_gap: continuity achieved: none"
cntcheck rep_same "AngleTol must be a positive number (degrees), not '-1'" "CNT_rep_same: a bad AngleTol is refused with its reason"
cntcheck rep_same "that is the first edge again; click a different edge" "CNT_rep_same: the same edge twice is refused and re-prompts"
cntnum rep_same "$REPM" "position gap " 2.99 3.01 "CNT_rep_same: ...and the next pick measures (gap 3)"
if grep -q "gl_error=0" <<<"$CNTO"; then echo "ok   CNT script ran without OpenGL errors"; else echo "FAIL CNT script ran without OpenGL errors"; fail=1; fi

# ---------------------------------------------------------------------------
# TS5_: ToSubD of a revolve of a CURVED profile (tosubd5_script.txt). A vase or a
# bottle (a spline profile revolved about an axis) used to get the straight-wall
# ladder of at most 12 evenly spaced rings (3840 and 2688 faces, measured 0.0108 and
# 0.0255 off the surface: unverified), and an egg (the profile meets the axis at both
# ends: one wall face, two poles) went through the dense grid tessellation (18240
# faces). Now the rings follow the profile (ring count from its NURBS control points:
# (control points - 1) x k, equally spaced in profile arc length and clustered toward
# the ends), the cage is interpolated onto the wall, and the Catmull-Clark limit
# surface is MEASURED against the exact wall (the reference's chord sag included); a
# cage is used only when verified within the document tolerance, else the reason is
# printed and the existing path runs (the 7-point zig-zag profile: 0.17 off at 37
# rings, so it still takes the old 3840-face cage, unverified, with the reason).
# Eight solids in script order: vase, bottle, egg, zig-zag (fallback), then the
# negative controls Cylinder, Cone, Torus and an extruded L, whose cages the TS2_ and
# TS4_ sections pin and which must be untouched. Ranges rather than exact numbers
# (deviations depend on the platform's float evaluation); the measured values on the
# reference run are in each description.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  TS5="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/tosubd5_script.txt" 2>&1)" || { echo "$TS5"; echo "FAIL: tosubd5 script exited non-zero"; exit 1; }
else
  TS5="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/tosubd5_script.txt" 2>&1)" || { echo "$TS5"; echo "FAIL: tosubd5 script exited non-zero"; exit 1; }
fi
ts5check() { if grep -q -- "$1" <<<"$TS5"; then echo "ok   $2"; else echo "FAIL $2"; near "$TS5" "$1"; fail=1; fi; }
# in range: ts5range VALUE LO HI DESC
ts5range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t TS5_TOSUBD < <(grep -F "history: ToSubD: created" <<<"$TS5" || true)
mapfile -t TS5_LIST < <(grep -E "^history:   [0-9]+ faces, [0-9]+ edges, [0-9]+ vertices, [0-9]+ creases" <<<"$TS5" || true)
mapfile -t TS5_VOL < <(grep -o "Volume = [0-9.e+-]*" <<<"$TS5" | awk '{print $3}' || true)
if [ "${#TS5_TOSUBD[@]}" -eq 8 ] && [ "${#TS5_LIST[@]}" -eq 8 ] && [ "${#TS5_VOL[@]}" -eq 4 ]; then
  echo "ok   tosubd5 script printed 8 ToSubD lines, 8 SubD List lines and 4 volumes"
  ts5dev() { sed -E 's/.*worst measured deviation ([0-9.]+)\).*/\1/' <<<"${TS5_TOSUBD[$1]}"; }
  ts5faces() { sed -E 's/^history: +([0-9]+) faces, .*/\1/' <<<"${TS5_LIST[$1]}"; }
  ts5vef() { sed -E 's/^history: +([0-9]+) faces, ([0-9]+) edges, ([0-9]+) vertices.*/\3 \2 \1/' <<<"${TS5_LIST[$1]}"; }
  ts5name=("vase" "bottle (pole + flat cap)" "egg (two poles)")
  # measured on the reference run: faces 768 / 1120 / 480 (before: 3840 unverified / 2688 unverified / 18240 dense); deviation 0.000496 / 0.000828 / 0.000841
  ts5flo=(600 900 350)
  ts5fhi=(950 1400 650)
  ts5dlo=(0.0002 0.0004 0.0004)
  ts5dhi=(0.0008 0.001 0.001)
  for i in 0 1 2; do
    if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.0[0-9]*)" <<<"${TS5_TOSUBD[$i]}" && grep -qF -- "curved-profile revolve cage (profile of " <<<"${TS5_TOSUBD[$i]}" && ! grep -qF -- "analytic revolved-solid cage" <<<"${TS5_TOSUBD[$i]}"; then
      echo "ok   ToSubD of the ${ts5name[$i]} is VERIFIED and reports the curved-profile revolve cage"
    else
      echo "FAIL ToSubD of the ${ts5name[$i]} is not verified or does not report the curved-profile revolve cage: ${TS5_TOSUBD[$i]}"; fail=1
    fi
    ts5range "$(ts5dev "$i")" "${ts5dlo[$i]}" "${ts5dhi[$i]}" "...measured limit-surface deviation of the ${ts5name[$i]} (tolerance 0.001, reference chord sag included)"
    ts5range "$(ts5faces "$i")" "${ts5flo[$i]}" "${ts5fhi[$i]}" "...cage face count of the ${ts5name[$i]} (before: 3840 / 2688 / 18240)"
    read -r ts5v ts5e ts5f <<<"$(ts5vef "$i")"
    if [ "$((ts5v - ts5e + ts5f))" -eq 2 ]; then echo "ok   ...Euler characteristic of the ${ts5name[$i]} SubD is 2 ($ts5v - $ts5e + $ts5f): one closed sphere-topology surface"; else echo "FAIL Euler characteristic of the ${ts5name[$i]} SubD is $((ts5v - ts5e + ts5f)), expected 2"; fail=1; fi
  done
  ts5range "$(grep -o 'x [0-9]* segments around' <<<"${TS5_TOSUBD[0]}" | awk '{print $2}' || true)" 32 128 "...vase segments around come from the 32/40/48/64/96/128 ladder"
  ts5range "$(grep -o '[0-9]* rings (control-point' <<<"${TS5_TOSUBD[0]}" | awk '{print $1}' || true)" 13 31 "...vase ring count is a multiple of its 3 control-point spans plus 1 (19 on the reference run)"
  # Volumes: Brep, then the control net after 0, 1, 2 SubDivide rounds. Reference run: 441.5 / 445.2 / 442.7 / 442.1.
  ts5range "${TS5_VOL[0]}" 440 443 "vase Brep Volume (display tessellation)"
  ts5range "${TS5_VOL[3]}" 440.5 443.5 "vase SubD control-net Volume after two SubDivide rounds matches the Brep Volume"
  if awk -v a="${TS5_VOL[0]}" -v b="${TS5_VOL[3]}" 'BEGIN { r = b / a; exit !(r > 0.995 && r < 1.005) }'; then echo "ok   vase SubD Volume is within 0.5% of the Brep Volume (${TS5_VOL[3]} vs ${TS5_VOL[0]})"; else echo "FAIL vase SubD Volume differs from the Brep Volume by more than 0.5% (${TS5_VOL[3]} vs ${TS5_VOL[0]})"; fail=1; fi
  # Fallback: the zig-zag profile is refused WITH the measured reason and keeps the existing path.
  if grep -qE "curved-profile revolve cage refused \(deviation [0-9.]+ at 37 rings x 128 segments exceeds the tolerance 0\.001000\), using the existing path" <<<"${TS5_TOSUBD[3]}" && grep -qF -- "analytic revolved-solid cage (128 segments around x 12 along the wall" <<<"${TS5_TOSUBD[3]}" && ! grep -qF -- "curved-profile revolve cage (profile of " <<<"${TS5_TOSUBD[3]}"; then
    echo "ok   fallback: the zig-zag profile is refused with the stated reason and takes the existing path"
    ts5range "$(sed -E 's/.*refused \(deviation ([0-9.]+) at .*/\1/' <<<"${TS5_TOSUBD[3]}")" 0.01 1 "...the refusing deviation (reference run 0.1729, far above the 0.001 tolerance)"
  else
    echo "FAIL fallback: the zig-zag profile line is not the refusal + existing path: ${TS5_TOSUBD[3]}"; fail=1
  fi
  ts5range "$(ts5faces 3)" 3000 4500 "...the fallback cage is the unchanged existing 3840-face one"
  # Negative controls: the existing cages are untouched (their windows are the TS2_ / TS4_ ones).
  ts5nc() { # index, description, marker, face lo, face hi
    if grep -qF -- "$3" <<<"${TS5_TOSUBD[$1]}" && ! grep -qF -- "curved-profile revolve cage" <<<"${TS5_TOSUBD[$1]}" && grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000" <<<"${TS5_TOSUBD[$1]}"; then
      echo "ok   negative control: $2 keeps its existing cage and never reports the curved-profile path"
    else
      echo "FAIL negative control: $2 changed: ${TS5_TOSUBD[$1]}"; fail=1
    fi
    ts5range "$(ts5faces "$1")" "$4" "$5" "...cage face count of $2 (reference run: unchanged)"
  }
  ts5nc 4 "the Cylinder" "analytic revolved-solid cage (32 segments around x 5 along the wall" 340 360
  ts5nc 5 "the Cone" "analytic revolved-solid cage (40 segments around x 6 along the wall" 370 390
  ts5nc 6 "the Torus" "analytic torus cage (48 x 16 quad grid" 760 776
  ts5nc 7 "the extruded L prism" "analytic right-prism cage (profile of 6 segment(s)" 24 28
else
  echo "FAIL tosubd5 script printed ${#TS5_TOSUBD[@]} ToSubD / ${#TS5_LIST[@]} List / ${#TS5_VOL[@]} Volume lines (expected 8 / 8 / 4)"; fail=1
fi
ts5check "gl_error=0" "tosubd5 script ran without OpenGL errors"

exit $fail
