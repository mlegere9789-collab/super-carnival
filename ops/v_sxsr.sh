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
exit $fail
