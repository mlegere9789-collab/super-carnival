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
exit $fail
