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
HERE="/home/user/miniature-pancake/.claude/worktrees/agent-a9cb50949c933224e/dino8-app/tests"
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
exit $fail
