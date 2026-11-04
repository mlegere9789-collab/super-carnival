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

exit $fail
