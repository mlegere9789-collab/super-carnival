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
# (E) was "a closed rail is not supported": closed rails are now a cyclic kernel sweep, so this case (two circles lying IN the rail's own plane, on a circle rail) is refused for the reason that applies - the section plane contains the rail tangent - and the old sampled sweep still builds
if grep -q "Sweep1: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep1Sections: the plane of section 1 contains (or is within 3 degrees of) the rail tangent where it crosses - the sweep is flat there); using the sampled approximation" <<<"$S1S_E" && grep -q "Sweep1: 2 section(s) along [0-9]* rail stations, closed" <<<"$S1S_E"; then s1s_ok "S1S_E_refusal: sections lying in the closed rail's own plane (their plane contains the rail tangent) are refused with that reason and the old sampled sweep builds"; else s1s_bad "S1S_E_refusal: refusal text or fallback line missing"; fi
S1S_N="$(grep -c "exact kernel multi-section sweep" <<<"$S1S" || true)"
if [ "$S1S_N" = "3" ]; then s1s_ok "S1S_count: exactly the three well-formed multi-section sweeps reached the kernel"; else s1s_bad "S1S_count: $S1S_N multi-section sweeps reached the kernel, expected 3"; fi

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
# was "(G) rails with a tangent jump: reported miss at 512 stations": the kernel now puts a station pair exactly at each paired corner, so this case is an EXACT sweep at the first rung of the ladder, wall edges within 1e-12 of the rails
if grep -q "Sweep2: exact kernel multi-section sweep (2 sections, [0-9]* rail stations)" <<<"$S2C_G"; then s2c_ok "S2C_G_kernel: rails with a tangent jump (polyline corner) reach the kernel and are an exact sweep"; else s2c_bad "S2C_G_kernel: expected the exact sweep for polyline rails"; fi
s2c_acc "$S2C_G" 1e-9 "S2C_G_accuracy: sections reproduced and the wall edges within 1e-9 of the polyline rails (corner stations placed exactly at the rails' corners; before: 0.0108 off at 512 stations)"
S2C_N="$(grep -c "exact kernel multi-section sweep" <<<"$S2C" || true)"
if [ "$S2C_N" = "6" ]; then s2c_ok "S2C_count: exactly the six well-formed sweeps reached the kernel"; else s2c_bad "S2C_count: $S2C_N multi-section sweeps reached the kernel, expected 6"; fi

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

exit $fail
