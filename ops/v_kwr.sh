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
kwrcheck O_cyl "OffsetSrf: object 2 not offset - recognised plane/sphere/cylinder/cone/torus: the exact offset is refused (" "KWR_O_cyl: -3 (radius 0) is refused WITH the kernel's reason (before: the first-order fallback built a degraded surface)"
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
