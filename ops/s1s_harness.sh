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
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-a96d6a48886afe947/dino8-app/tests
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
if grep -q "Sweep1: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep1Sections: a closed rail is not supported" <<<"$S1S_E" && grep -q "Sweep1: 2 section(s) along " <<<"$S1S_E"; then s1s_ok "S1S_E_refusal: a closed rail is refused with that reason and the old sampled sweep builds"; else s1s_bad "S1S_E_refusal: refusal text or fallback line missing"; fi
S1S_N="$(grep -c "exact kernel multi-section sweep" <<<"$S1S" || true)"
if [ "$S1S_N" = "3" ]; then s1s_ok "S1S_count: exactly the three well-formed multi-section sweeps reached the kernel"; else s1s_bad "S1S_count: $S1S_N multi-section sweeps reached the kernel, expected 3"; fi

exit $fail
