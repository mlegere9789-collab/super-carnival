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
HERE="/home/user/miniature-pancake/.claude/worktrees/agent-aaf1200e7640df7a2/dino8-app/tests"
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
# TS2: ToSubD of a revolved solid (tosubd2_script.txt). The app's Cylinder,
# Cone and TCone (a surface-of-revolution wall plus trimmed planar caps) used
# to fall back to the chord-tolerance mesher: an ~11900-face triangle cage,
# 0 of 1 limit-surface-fidelity verified, worst deviation 0.02-0.05. The cage
# is now built from the Brep's own wall parametrisation and shared rim ring
# (all-quad O-grid caps), the rims are creased, and the Catmull-Clark limit
# surface is measured against the exact surface (the same analytic wall
# sampled far finer than the tolerance, exactly planar caps). Ranges rather
# than exact numbers for everything that depends on the platform's float
# evaluation (deviation, volumes).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  TS2="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/tosubd2_script.txt" 2>&1)" || { echo "$TS2"; echo "FAIL: tosubd2 script exited non-zero"; exit 1; }
else
  TS2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/tosubd2_script.txt" 2>&1)" || { echo "$TS2"; echo "FAIL: tosubd2 script exited non-zero"; exit 1; }
fi
ts2check() { if grep -q -- "$1" <<<"$TS2"; then echo "ok   $2"; else echo "FAIL $2"; near "$TS2" "$1"; fail=1; fi; }
# in range: ts2range VALUE LO HI DESC
ts2range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t TS2_TOSUBD < <(grep -F "history: ToSubD: created" <<<"$TS2" || true)
mapfile -t TS2_LIST < <(grep -E "^history:   [0-9]+ faces, [0-9]+ edges, [0-9]+ vertices, [0-9]+ creases" <<<"$TS2" || true)
mapfile -t TS2_VOL < <(grep -o "Volume = [0-9.e+-]*" <<<"$TS2" | awk '{print $3}' || true)
if [ "${#TS2_TOSUBD[@]}" -eq 6 ] && [ "${#TS2_LIST[@]}" -eq 5 ] && [ "${#TS2_VOL[@]}" -eq 4 ]; then
  echo "ok   tosubd2 script printed 6 ToSubD lines, 5 SubD List lines and 4 volumes"
  # worst measured deviation per ToSubD line, in script order: cylinder, cone, TCone, big cylinder, torus, extruded circle
  ts2dev() { sed -E 's/.*worst measured deviation ([0-9.]+)\).*/\1/' <<<"${TS2_TOSUBD[$1]}"; }
  ts2name=(cylinder cone TCone "big cylinder (radius 40)" torus "extruded circle solid")
  for i in 0 1 2 3 4 5; do
    if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.0[0-9]*)" <<<"${TS2_TOSUBD[$i]}"; then
      ts2range "$(ts2dev $i)" 0 0.001 "ToSubD of the ${ts2name[$i]} is VERIFIED: measured limit-surface deviation within the 0.001 document tolerance (before: 0 of 1 verified, 0.02-0.05, for cylinder/cone/TCone)"
    else
      echo "FAIL ToSubD of the ${ts2name[$i]} is not verified: ${TS2_TOSUBD[$i]}"; fail=1
    fi
  done
  # The three wall solids and the big cylinder go through the analytic revolved-solid cage; the torus does not.
  for i in 0 1 2 3 5; do
    if grep -q "analytic revolved-solid cage (.* segments around x .* along the wall, all-quad O-grid caps welded to the wall's rim ring), cage interpolated onto the Brep surface" <<<"${TS2_TOSUBD[$i]}" && grep -q "against the exact surface sampled [0-9]* x 64 (planar caps exact), reference chord sag 0\.000[0-9]* included in the deviation" <<<"${TS2_TOSUBD[$i]}"; then
      echo "ok   ToSubD of the ${ts2name[$i]} reports the analytic cage and what the deviation was measured against"
    else
      echo "FAIL ToSubD of the ${ts2name[$i]} does not report the analytic revolved-solid cage: ${TS2_TOSUBD[$i]}"; fail=1
    fi
  done
  if grep -q "analytic revolved-solid cage" <<<"${TS2_TOSUBD[4]}"; then echo "FAIL the torus unexpectedly used the revolved-solid cage"; fail=1; else echo "ok   the torus keeps its grid cage (not a wall + cap solid)"; fi
  # Cage sizes: a few hundred faces (before: 11894 / 11660 / 11894), closed manifold (Euler), rims creased.
  # F E V C per List line: cylinder, cone, TCone, big cylinder
  ts2lname=(cylinder cone TCone "big cylinder (radius 40)" "extruded circle solid")
  ts2fe() { sed -E 's/^history: +([0-9]+) faces, ([0-9]+) edges, ([0-9]+) vertices, ([0-9]+) creases.*/\1 \2 \3 \4/' <<<"${TS2_LIST[$1]}"; }
  for i in 0 1 2 3 4; do
    read -r F E V C <<<"$(ts2fe $i)"
    if [ "$((V - E + F))" -eq 2 ]; then echo "ok   the ${ts2lname[$i]} cage is a closed manifold: Euler $V - $E + $F = 2"; else echo "FAIL the ${ts2lname[$i]} cage Euler $V - $E + $F != 2"; fail=1; fi
    ts2range "$F" 300 1600 "the ${ts2lname[$i]} cage has a few hundred to ~1500 faces (before: ~11900)"
    ts2range "$C" 64 160 "the ${ts2lname[$i]} cage creases its rims (and the cone's apex spokes)"
  done
  ts2check "352 faces, 704 edges, 354 vertices, 64 creases" "the cylinder cage: 32 x 5 wall + two 64-face O-grid caps = 352 faces, 64 rim creases (before: 11894 faces, 512 creases)"
  ts2check "32 segments around x 5 along the wall, all-quad O-grid caps" "the cylinder uses the 32-segment cage (verified at the first round)"
  # Volumes in script order: cylinder SubD, cylinder ToNURBS, cone SubD, TCone SubD
  ts2range "${TS2_VOL[1]}" 501.0 504.4 "ToNURBS of the cylinder SubD: closed polysurface, Volume vs pi r^2 h = 502.65"
  ts2range "${TS2_VOL[0]}" 497.0 511.0 "cylinder SubD display Volume vs pi r^2 h = 502.65 (display tessellation of the SubD, looser)"
  ts2range "${TS2_VOL[2]}" 163.5 171.5 "cone SubD Volume vs pi r^2 h / 3 = 167.55"
  ts2range "${TS2_VOL[3]}" 288.0 300.0 "TCone SubD Volume vs pi h (R^2 + R r + r^2) / 3 = 293.2"
else
  echo "FAIL tosubd2 script printed ${#TS2_TOSUBD[@]} ToSubD / ${#TS2_LIST[@]} List / ${#TS2_VOL[@]} Volume lines (expected 6 / 5 / 4)"; fail=1
fi
ts2check "ToNURBS: watertight conversion of a 352-face SubD (2 Catmull-Clark refinement round(s) first): 5632 bicubic patches" "ToNURBS of the cylinder SubD converts the 352-face cage"
ts2check "0 naked edge(s) left, closed solid: yes, manifold" "...to a closed manifold polysurface"
ts2check "5632 faces, 22528 edges, closed solid" "...which lists as a closed solid"
ts2check "gl_error=0" "tosubd2 script ran without OpenGL errors"

exit $fail
