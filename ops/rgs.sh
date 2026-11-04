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

exit $fail
