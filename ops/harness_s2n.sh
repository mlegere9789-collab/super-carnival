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
HERE="/home/user/miniature-pancake/.claude/worktrees/agent-a34f41bb080e3eecc/dino8-app/tests"
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
# --- NetworkSrf through a CURVE NETWORK (s2n_network_script.txt, prefix S2N_ / s2n_).
# Curves crossing in their interiors (3 one way x 3 the other, drawn scrambled and half of them
# backwards) are sorted into the two directions by their meetings, a bicubic NURBS surface is
# fitted through them and EVERY input curve's distance to it is measured and printed; a network
# whose curves do not meet within the document tolerance is refused with the reason and the old
# behaviour runs; a boundary loop of 4 curves still takes the exact Coons path. Areas are
# tessellation-derived, so they are range-checked (the Windows CI tessellates slightly differently).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  S2N_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/s2n_network_script.txt" 2>&1)" || { echo "$S2N_OUT"; echo "FAIL: s2n network script exited non-zero"; exit 1; }
else
  S2N_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/s2n_network_script.txt" 2>&1)" || { echo "$S2N_OUT"; echo "FAIL: s2n network script exited non-zero"; exit 1; }
fi
s2n_check() { if grep -q "$1" <<<"$S2N_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$S2N_OUT" "$1"; fail=1; fi; }
s2n_count() { local n; n="$(grep -c "$1" <<<"$S2N_OUT" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$S2N_OUT" "$1"; fail=1; fi; }
s2n_area() { { grep -o 'Area = [0-9.]* square' <<<"$S2N_OUT" || true; } | sed -n "${1}p" | sed 's/Area = //; s/ square//'; }
s2n_in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }'; }
grep -q "^smoke:" <<<"$S2N_OUT" || { echo "$S2N_OUT"; echo "FAIL: s2n network script produced no smoke line"; fail=1; }
if grep -q "^FAIL" <<<"$S2N_OUT"; then echo "FAIL s2n network script printed a FAIL line"; fail=1; fi
s2n_count "^ok   expect_objects 0 (got 0)" 5 "S2N_: every case cleaned up after itself (5 sections, none left an object behind)"
s2n_check "NetworkSrf: curve network of 3 x 3 curves (9 meetings, 5 crossing in their interiors, worst meeting gap [0-9.e-]*)" "S2N_3x3: six scrambled/reversed curves are sorted into 3 + 3, 9 meetings of which 5 cross in interiors"
s2n_check "measured distance of each input curve from the surface: \([0-9.e-]*, \)\{5\}[0-9.e-]* (worst [0-9.e-]*, document tolerance 0.001: met)" "S2N_3x3: the distance of ALL SIX input curves from the surface is measured and printed, and met the tolerance"
s2n_check "Approximate least-squares fit over the curves' bounding rectangle, not an interpolating or trimmed surface" "S2N_3x3: the result labels itself approximate and untrimmed"
S2N_WORST="$({ grep -o 'worst [0-9.e-]*, document tolerance 0.001: met' <<<"$S2N_OUT" || true; } | head -1 | sed 's/worst //; s/, document.*//')"
S2N_GAP="$({ grep -o 'worst meeting gap [0-9.e-]*' <<<"$S2N_OUT" || true; } | head -1 | sed 's/worst meeting gap //')"
if s2n_in_range "$S2N_WORST" 0 0.001; then echo "ok   S2N_3x3: worst curve-to-surface deviation $S2N_WORST <= 0.001"; else echo "FAIL S2N_3x3 worst deviation '$S2N_WORST' not in 0..0.001"; fail=1; fi
if s2n_in_range "$S2N_GAP" 0 0.001; then echo "ok   S2N_3x3: worst meeting gap $S2N_GAP <= 0.001"; else echo "FAIL S2N_3x3 worst meeting gap '$S2N_GAP' not in 0..0.001"; fail=1; fi
# The area of the 6 x 4 rectangle plus the 0.72 high bump is a little over 24 (measured 25.52 here); the bounding box reaches the bump top z = 0.72.
s2n_check "NURBS surface (cubic where the net allows) fitted through the curves and the meetings ([0-9]* x [0-9]* net)" "S2N_3x3: the control net of the fitted surface is reported"
S2N_A1="$(s2n_area 1)"
if s2n_in_range "$S2N_A1" 25 26.2; then echo "ok   S2N_3x3: area $S2N_A1 in 25..26.2 (25.52 when written: the 6 x 4 rectangle plus the 0.72 high bump)"; else echo "FAIL S2N_3x3 area '$S2N_A1' not in 25..26.2"; fail=1; fi
S2N_TOP="$({ grep -o 'Bounding box min 0,0,-\?[0-9.e-]* max 6,4,[0-9.e-]*' <<<"$S2N_OUT" || true; } | head -1 | sed 's/.* max 6,4,//')"
if s2n_in_range "$S2N_TOP" 0.69 0.75; then echo "ok   S2N_3x3: the surface spans x 0..6, y 0..4 and its top is z = $S2N_TOP (the bump height 0.72 is reproduced through the interior curves)"; else echo "FAIL S2N_3x3 bounding box top '$S2N_TOP' not in 0.69..0.75 (or the box is not 6 x 4)"; fail=1; fi
s2n_count "Object [0-9]*: valid" 1 "S2N_3x3: Check reports the fitted surface valid"
s2n_check "NetworkSrf: these curves cross in their interiors but cannot be fitted as a curve network (curve [0-9]* does not meet the rest of the network within the tolerance (nearest is curve [0-9]*, 0\.[45][0-9]* apart)); using the older loop behaviour" "S2N_miss: a curve lifted 0.5 off the network is refused with the measured miss and the old behaviour runs"
s2n_check "NetworkSrf: curve network of 2 x 2 curves (4 meetings, 4 crossing in their interiors" "S2N_hash: 4 curves forming a # (2 x 2, all crossings interior) take the network path"
S2N_A2="$(s2n_area 2)"
if s2n_in_range "$S2N_A2" 23.5 24.5; then echo "ok   S2N_hash: flat # area $S2N_A2 in 23.5..24.5 (the 6 x 4 bounding rectangle of the curves)"; else echo "FAIL S2N_hash area '$S2N_A2' not in 23.5..24.5"; fail=1; fi
s2n_check "NetworkSrf: exact Coons patch through 4 curves" "S2N_loop control: a closed 4-curve boundary loop still takes the exact Coons path"
s2n_count "NetworkSrf: curve network of" 2 "S2N_: only the two crossing networks used the network routine (the miss and the loop did not)"


exit $fail
