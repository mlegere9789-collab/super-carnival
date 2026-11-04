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
# SBL_: sealed exact Booleans (sbl_script.txt, sbl_script_fb.txt). The exact general-Boolean path now tries
# kernel::SealGeneralBooleanResult (BooleanCombineGeneralSealed's sewing half) FIRST: a result that seals is
# ON_Brep::IsValid + IsSolid with REAL inner loops (no keyhole slits) and carries an exact divergence-theorem
# volume checked against the operands' bounds; Check is asserted valid on these results for the first time. A
# refusal falls back to the previous sewing path unchanged (the far-from-origin case below, and the sealed-off
# control run). Every volume/area is read against a closed form; display Volume comes from the closed display mesh.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SBL_OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/sbl_script.txt" 2>&1)" || { echo "$SBL_OUT"; echo "FAIL: SBL_ script exited non-zero"; exit 1; }
  SBL_FB="$(DINO8_NO_SEALED_BOOLEAN=1 timeout 900 "$BIN" --smoke 60 --script "$HERE/sbl_script_fb.txt" 2>&1)" || { echo "$SBL_FB"; echo "FAIL: SBL_ fallback script exited non-zero"; exit 1; }
else
  SBL_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/sbl_script.txt" 2>&1)" || { echo "$SBL_OUT"; echo "FAIL: SBL_ script exited non-zero"; exit 1; }
  SBL_FB="$(DINO8_NO_SEALED_BOOLEAN=1 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/sbl_script_fb.txt" 2>&1)" || { echo "$SBL_FB"; echo "FAIL: SBL_ fallback script exited non-zero"; exit 1; }
fi
sblblock() { awk -v name="$1" '$0 ~ ("Unknown command: SBLBEGIN_" name "$") { on = 1; next } on && /Unknown command: SBLBEGIN_|Unknown command: SBLEND/ { exit } on { print }' <<<"${2:-$SBL_OUT}"; }
# sblcheck NAME PATTERN DESC [OUTPUT]: the case's block must contain PATTERN (a grep regex)
sblcheck() { local blk; blk="$(sblblock "$1" "${4:-$SBL_OUT}")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   SBL_$1: $3"; else echo "FAIL SBL_$1: $3"; echo "     expected: $2"; { grep -E "^history: (Boolean|Shell|Object|  [0-9]|Volume|Area|!)" <<<"$blk" || true; } | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
# sblnot NAME PATTERN DESC: the case's block must NOT contain PATTERN
sblnot() { local blk; blk="$(sblblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "FAIL SBL_$1: $3"; fail=1; else echo "ok   SBL_$1: $3"; fi; }
# sblnum NAME REGEX MIN MAX DESC: the first number following REGEX (a grep -oE regex ending right before the number) in the block lies in [MIN, MAX]
sblnum() {
  local blk v; blk="$(sblblock "$1")"
  v="$({ grep -oE -- "$2[-0-9.eE+]+" <<<"$blk" || true; } | head -1 | sed -E "s/^$2//")"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$3" -v hi="$4" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   SBL_$1: $5 (measured $v in [$3, $4])"; else echo "FAIL SBL_$1: $5 (measured '${v:-none}' not in [$3, $4])"; fail=1; fi
}
SBL_SEAL="sealed: valid B-rep with real inner loops, exact volume"
# --- box 10^3 minus a through-hole cylinder r2: V = 874.34, A = 700.53; two keyholes (one per end face) opened into real inner loops
sblcheck cut_through "7 face(s), $SBL_SEAL" "box minus a through-hole cylinder takes the SEALED path (7 faces)"
sblcheck cut_through "2 keyhole(s) opened" "...both end faces' keyhole slits were opened into real inner loops"
sblcheck cut_through "^history: Object 3: valid$" "...Check reports the Boolean result a VALID B-rep (before: ON_Brep.m_T[..].m_type = seam but m_iso is not N/E/W/S_iso)"
sblcheck cut_through "7 faces, [0-9]* edges, closed solid" "...List reports a closed solid"
sblnum cut_through "exact volume " 873.7 875.0 "exact kernel volume = 1000 - pi*2^2*10 = 874.34"
sblnum cut_through "^history: Volume = " 872.5 876.5 "display Volume (closed display mesh) = 874.34"
sblnum cut_through "^history: Area = " 698 703 "Area = 600 - 2*pi*4 + 2*pi*2*10 = 700.53"
sblcheck cut_through "mesh cross-check" "...the independent mesh-boolean cross-check still ran"
# --- union with a piercing cylinder: 10 faces, 1000 + pi*4*10 = 1125.66
sblcheck union_pierce "10 face(s), $SBL_SEAL" "box + piercing cylinder: sealed, 10 faces"
sblcheck union_pierce "2 keyhole(s) opened" "...2 keyholes opened"
sblcheck union_pierce "^history: Object 3: valid$" "...Check valid"
sblnum union_pierce "exact volume " 1123.5 1127.5 "exact volume = 1000 + pi*4*10 = 1125.66"
sblnum union_pierce "^history: Volume = " 1122 1128 "display Volume = 1125.66"
# --- intersection with the piercing cylinder: 3 faces, no keyhole, pi*4*10 = 125.66
sblcheck intersect_pierce "3 face(s), $SBL_SEAL" "box ^ piercing cylinder: sealed, 3 faces"
sblcheck intersect_pierce "0 keyhole(s) opened" "...no keyhole to open"
sblcheck intersect_pierce "^history: Object 3: valid$" "...Check valid"
sblnum intersect_pierce "exact volume " 124.6 126.6 "exact volume = pi*4*10 = 125.66"
# --- blind hole (1 keyhole, the open end) and boss
sblcheck blind "8 face(s), $SBL_SEAL" "blind hole: sealed, 8 faces"
sblcheck blind "1 keyhole(s) opened" "...1 keyhole opened (the open end only)"
sblcheck blind "^history: Object 3: valid$" "...Check valid"
sblnum blind "exact volume " 936.2 938.2 "exact volume = 1000 - pi*4*5 = 937.17"
sblcheck boss "8 face(s), $SBL_SEAL" "boss: sealed, 8 faces"
sblcheck boss "^history: Object 3: valid$" "...Check valid"
sblnum boss "exact volume " 1139.8 1142.9 "exact volume = 1000 + pi*9*5 = 1141.37"
sblnum boss "^history: Volume = " 1139 1144 "display Volume = 1141.37"
# --- cylinder-only solids: the cylinder wall is ONE untrimmed analytic face (integrated on its whole domain)
sblcheck tube "4 face(s), $SBL_SEAL" "tube (cylinder minus coaxial cylinder): sealed, 4 faces"
sblcheck tube "^history: Object 3: valid$" "...Check valid"
sblnum tube "exact volume " 653 666 "exact volume = pi*(25-4)*10 = 659.73 (polyline edges: <1% quadrature error)"
sblnum tube "^history: Volume = " 655 664 "display Volume = 659.73"
sblcheck stack "5 face(s), $SBL_SEAL" "stacked cylinders: sealed, 5 faces"
sblcheck stack "^history: Object 3: valid$" "...Check valid"
sblnum stack "exact volume " 323.5 329.5 "exact volume = pi*9*8 + pi*4*8 = 326.73"
# --- two holes in one Boolean, and a second hole cut in the result of the first
sblcheck two_holes "8 face(s), $SBL_SEAL" "two holes in ONE Boolean: sealed, 8 faces"
sblcheck two_holes "4 keyhole(s) opened" "...4 keyholes opened (2 per end face)"
sblcheck two_holes "^history: Object 4: valid$" "...Check valid"
sblnum two_holes "exact volume " 857 860.5 "exact volume = 1000 - 2*pi*2.25*10 = 858.62"
sblnum two_holes "^history: Volume = " 856.5 861 "display Volume = 858.62"
sblcheck sequential "7 face(s), $SBL_SEAL" "sequential Booleans: the first hole is sealed"
sblcheck sequential "re-evaluated from the recorded original operands.*$SBL_SEAL" "...the second hole is re-evaluated from the recorded operands (GeneralRecipe) and sealed"
sblcheck sequential "^history: Object 5: valid$" "...Check valid on the second result"
sblnum sequential "^history: Volume = " 856.5 861 "display Volume = 858.62"
# --- the exact Shell reads the sealed result's end faces (real inner loops) as a plate with a through-hole
sblcheck shell "$SBL_SEAL" "shell case: the base Boolean is sealed"
sblcheck shell "Shell: thickness 0.5, closed, exact B-rep, volume" "Shell of the sealed result is still the EXACT prism-with-hole path"
sblnum shell "Shell: thickness 0.5, closed, exact B-rep, volume " 320 324 "shell volume = 874.34 - (729 - pi*2.5^2*9) = 322.0"
# --- declined case: unchanged previous behaviour (mesh boolean, with the reason)
sblcheck far_decline "exact B-rep boolean declined (the engine's result has gaps between faces" "a hole 100000 units from the origin still declines with the engine's reason"
sblnot far_decline "$SBL_SEAL" "...and nothing claims a sealed result"
sblnum far_decline "^history: Volume = " 873 877 "...and the mesh result has Volume 874.9"
# --- control: sealed path switched off -> the previous sewn keyhole-slit result, bit for bit the old message
sblcheck fb_cut_through "7 face(s), sewn into a closed solid (tolerance 0.01855), volume 874.8" "DINO8_NO_SEALED_BOOLEAN=1 gives the previous sewn result" "$SBL_FB"
sblcheck fb_cut_through "INVALID - ON_Brep.m_T" "...which is the keyhole-slit structure Check rejects (why the sealed path exists)" "$SBL_FB"
sblcheck fb_cut_through "closed solid" "...yet a closed solid" "$SBL_FB"

exit $fail

exit $fail
