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
# B2S_: sequential exact Booleans (b2s_script.txt). A second hole cut in the result of a first exact
# Boolean, and box + sphere (also with a second sphere), stay exact B-rep: every accepted exact result
# is a closed solid (IsSolid, Check() clean at the sewing step) whose display-mesh volume is within the
# stated range of the analytic value, and a case the engine cannot do is declined WITH a reason (never an
# open or wrong solid). Volumes are read from the display mesh (chord 0.05% of the diagonal), so the
# ranges carry that tessellation error (measured ~0.1% here; the Windows CI tessellates slightly
# differently, hence the +-0.5% windows).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  B2SOUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/b2s_script.txt" 2>&1)" || { echo "$B2SOUT"; echo "FAIL b2s_script exited non-zero"; exit 1; }
else
  B2SOUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/b2s_script.txt" 2>&1)" || { echo "$B2SOUT"; echo "FAIL b2s_script exited non-zero"; exit 1; }
fi
b2s_block() { awk -v name="$1" '$0 ~ ("Unknown command: B2SBEGIN_" name "$") { on = 1; next } on && /Unknown command: B2SBEGIN_|Unknown command: B2SEND/ { exit } on { print }' <<<"$B2SOUT"; }
b2s_check() {
  local blk; blk="$(b2s_block "$1")"
  if grep -q -- "$2" <<<"$blk"; then echo "ok   b2s_$1: $3"; else
    echo "FAIL b2s_$1: $3"; echo "     expected: $2"
    { grep -E "^history: (Boolean|Shell|Object|  [0-9]|Volume|Area|!)" <<<"$blk" || true; } | head -8 | sed 's/^/     actual:   /'
    fail=1
  fi
}
# b2s_num NAME KEY MIN MAX DESC: the case's last "KEY = V" (Volume / Area) must lie in [MIN, MAX]
b2s_num() {
  local blk v; blk="$(b2s_block "$1")"
  v="$({ grep -E "^history: $2 = " <<<"$blk" || true; } | tail -1 | sed -E "s/^history: $2 = ([0-9.eE+-]+).*/\\1/")"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   b2s_$1: $5 ($2 $v in [$3, $4])"; else echo "FAIL b2s_$1: $5 ($2 '${v:-none}' not in [$3, $4])"; fail=1; fi
}
# --- second sequential hole: exact, re-evaluated from the recorded operands
b2s_check chain2 "exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "first hole is exact and closed"
b2s_check chain2 "exact B-rep boolean (no tessellation, general engine), 8 face(s), re-evaluated from the recorded original operands (the base and 2 tool(s) in one pass" "second sequential hole is exact (before: declined, mesh)"
b2s_check chain2 "(polysurface)" "...result is a polysurface, not a mesh"
b2s_check chain2 "8 faces, [0-9]* edges, closed solid" "...8 faces (6 box + 2 hole walls), closed solid"
b2s_check chain2 "mesh cross-check" "...with its independent mesh-boolean cross-check volume printed"
b2s_num chain2 Volume 855.5 861.7 "two holes r1.5 in a 10-cube: 1000 - 2*pi*1.5^2*10 = 858.62"
b2s_num chain2 Area 755 765 "area = 400 + 2*(100-2*pi*1.5^2) + 2*(2*pi*1.5*10) = 760.2"
b2s_check chain3 "(the base and 3 tool(s) in one pass" "third sequential hole is exact too"
b2s_check chain3 "9 faces, [0-9]* edges, closed solid" "...9 faces, closed solid"
b2s_num chain3 Volume 861 868 "three holes r1.2: 1000 - 3*pi*1.44*10 = 864.28"
# --- a moved intermediate result must NOT use the recorded operands: declined with the engine's reason, mesh volume right
b2s_check moved "exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a MOVED first result is not re-evaluated from its recorded operands: declined WITH the reason"
b2s_check moved "(mesh)" "...and the fallback is a mesh"
b2s_num moved Volume 855.5 861.7 "...whose volume is still 1000 - 2*pi*1.5^2*10 = 858.62"
# --- box + sphere
b2s_check box_sphere "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "box + sphere is exact (before: declined, mesh)"
b2s_check box_sphere "7 faces, [0-9]* edges, closed solid" "...7 faces (5 box + box top with the circle removed + hemisphere), closed solid"
b2s_num box_sphere Volume 1130 1136 "box + upper hemisphere: 1000 + 2/3*pi*64 = 1134.04"
b2s_num box_sphere Area 646 655 "area = 600 - pi*16 + 2*pi*16 = 650.27"
b2s_check box_sphere_shell "Shell: thickness 0.5, closed, volume" "a Shell takes the box + sphere result as a closed solid (mesh construction: a curved face has no exact kernel shell)"
b2s_check box_sphere_sphere "re-evaluated from the recorded original operands" "box + sphere, then + a second sphere: exact"
b2s_check box_sphere_sphere "8 faces, [0-9]* edges, closed solid" "...8 faces, closed solid"
b2s_num box_sphere_sphere Volume 1264 1272 "1000 + 2*(2/3*pi*64) = 1268.08"
b2s_check box_two_spheres "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sewn into a closed solid" "box + two spheres in one Boolean is exact (the left-to-right fold fails; the retry unites the spheres first)"
b2s_num box_two_spheres Volume 1264 1272 "1000 + 2*(2/3*pi*64) = 1268.08"
# --- still declined, honestly: a different operation on the box + sphere result
b2s_check sphere_then_hole "BooleanDifference: exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a hole drilled in the box + sphere result (Difference after a Union) is declined WITH the reason"
b2s_check sphere_then_hole "(mesh)" "...mesh fallback"
b2s_num sphere_then_hole Volume 1098 1106 "...with the right volume 1134.04 - pi*10 = 1102.6"
# --- other sphere placements: declined honestly, with the reason; the mesh fallback has the right volume
b2s_check sph_cap "BooleanUnion: exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a sphere poking out of the top as a cap is declined WITH the reason"
b2s_check sph_cap "(mesh)" "...mesh fallback"
b2s_num sph_cap Volume 1038 1046 "...with the right volume 1000 + pi*4*(12-2)/3 = 1041.89"
b2s_check sph_side "BooleanUnion: exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a sphere centred on a side face is declined WITH the reason"
b2s_num sph_side Volume 1052 1060 "...with the right volume 1000 + 2/3*pi*27 = 1056.55"


exit $fail
