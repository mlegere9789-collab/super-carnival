#!/usr/bin/env bash
trap '' PIPE
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
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-a85dac6234d906358/dino8-app/tests
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
sxcheck B_then_shell "Shell: thickness 0.5, closed, volume" "Shell of the sewn Boolean result now works (before: 'Object 3 is not a closed solid; skipped')"
sxcheck B_then_shell "exact B-rep shell not used (" "...and says why that shell is a mesh (a curved face has no exact kernel shell)"
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
exit $fail
