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
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PHL_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/patch_holes_script.txt" 2>&1)" || { echo "$PHL_OUT"; echo "FAIL: patch-holes script exited non-zero"; exit 1; }
else
  PHL_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/patch_holes_script.txt" 2>&1)" || { echo "$PHL_OUT"; echo "FAIL: patch-holes script exited non-zero"; exit 1; }
fi
phl_check() { if grep -q "$1" <<<"$PHL_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$PHL_OUT" "$1"; fail=1; fi; }
phl_count() { local n; n="$(grep -c "$1" <<<"$PHL_OUT" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$PHL_OUT" "$1"; fail=1; fi; }
# nth "Area = X" value (1-based) as a bare number
phl_area() { { grep -o 'Area = [0-9.]* square' <<<"$PHL_OUT" || true; } | sed -n "${1}p" | sed 's/Area = //; s/ square//'; }
# awk range test: phl_in_range VALUE LO HI
phl_in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }'; }
if grep -q "^FAIL" <<<"$PHL_OUT"; then echo "FAIL patch-holes script printed a FAIL line"; fail=1; fi
phl_count "^ok   expect_objects 0 (got 0)" 8 "patch-holes script: every case cleaned up after itself (8 sections, none left an object behind)"
phl_count "Patch: non-planar data - kernel least-squares NURBS" 5 "all five Patch cases reached the kernel's least-squares fit (no-hole reference, one hole, hole ring alone, two holes, overlapping negative control)"
phl_check "trimmed by the closed curve; the face's edge is within [0-9.e-]* of the curve" "a single closed non-planar curve keeps the original single-loop wording and trim (the no-hole reference, and the hole ring patched alone)"
phl_check "(9 x 9 net, worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1.5) trimmed by the closed curve with 1 hole(s) cut by the other closed curve(s); the worst of the 2 trimmed edges is within [0-9.e-]* of its curve" "outer ring + one inner ring: the larger curve is the boundary, the smaller one a hole, 2 trimmed edges, fit within the 0.001 tolerance"
phl_check "with 2 hole(s) cut by the other closed curve(s); the worst of the 3 trimmed edges is within [0-9.e-]* of its curve" "outer ring + two inner rings: 2 holes, 3 trimmed edges"
# Numeric: every kernel-measured figure is within the document tolerance 0.001 (measured 0.00016 and 0.00041 here)
PHL_DEV1="$({ grep -o 'the worst of the 2 trimmed edges is within [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* within //')"
PHL_DEV2="$({ grep -o 'the worst of the 3 trimmed edges is within [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* within //')"
if phl_in_range "$PHL_DEV1" 0 0.001; then echo "ok   one-hole face: worst trimmed-edge-to-curve deviation $PHL_DEV1 <= 0.001 (measured by the kernel, 0.00016 when written)"; else echo "FAIL one-hole face deviation '$PHL_DEV1' not in 0..0.001"; fail=1; fi
if phl_in_range "$PHL_DEV2" 0 0.001; then echo "ok   two-hole face: worst trimmed-edge-to-curve deviation $PHL_DEV2 <= 0.001 (0.00041 when written)"; else echo "FAIL two-hole face deviation '$PHL_DEV2' not in 0..0.001"; fail=1; fi
# Topology of the single resulting face (exact, not tessellation): List counts
phl_check "  1 faces, 2 edges, open" "one hole: ONE face with two edges (outer loop + hole loop), not a second face"
phl_check "  1 faces, 3 edges, open" "two holes: ONE face with three edges (outer loop + 2 hole loops)"
phl_count "Object [0-9]*: valid" 3 "Check reports the two hole faces and the five-curve NetworkSrf face valid"
# Areas (tessellation-derived: ranges). Closed form for the annulus on z = 0.06 (x^2 - y^2) between r = 4.97 and r = 1.98 is about 71.3;
# the unholed reference measured 84.93, the hole ring alone 12.55 (closed form for r = 1.98: 12.6).
PHL_A_REF="$(phl_area 1)"; PHL_A_HOLE="$(phl_area 2)"; PHL_A_RING="$(phl_area 3)"; PHL_A_TWO="$(phl_area 4)"
if phl_in_range "$PHL_A_REF" 83 87; then echo "ok   no-hole reference area $PHL_A_REF in 83..87 (84.93 when written)"; else echo "FAIL no-hole reference area '$PHL_A_REF'"; fail=1; fi
if phl_in_range "$PHL_A_HOLE" 70 73; then echo "ok   outer ring with the centre hole: area $PHL_A_HOLE in 70..73 (71.43 when written; closed form of the annulus 71.3)"; else echo "FAIL one-hole area '$PHL_A_HOLE' not in 70..73"; fail=1; fi
if phl_in_range "$PHL_A_RING" 12 13.1; then echo "ok   the hole ring patched alone: area $PHL_A_RING in 12..13.1 (12.55 when written; closed form 12.6)"; else echo "FAIL hole-ring-alone area '$PHL_A_RING'"; fail=1; fi
if awk -v a="$PHL_A_REF" -v h="$PHL_A_HOLE" -v r="$PHL_A_RING" 'BEGIN { d = a - h; exit !(a != "" && h != "" && r != "" && d > 0.9 * r && d < 1.2 * r) }'; then echo "ok   the hole really removes area: unholed minus holed ($PHL_A_REF - $PHL_A_HOLE) is within 0.9..1.2 x the hole ring's own patch area $PHL_A_RING"; else echo "FAIL hole area removed is not about the hole ring's own area (ref $PHL_A_REF, holed $PHL_A_HOLE, ring $PHL_A_RING)"; fail=1; fi
if phl_in_range "$PHL_A_TWO" 73 78; then echo "ok   outer ring with two holes (r = 1.2 at y = +-2.5): area $PHL_A_TWO in 73..78 (75.72 when written; about 74.3 closed form for the ideal saddle minus two discs)"; else echo "FAIL two-hole area '$PHL_A_TWO' not in 73..78"; fail=1; fi
# Negative control: a second ring that crosses the outer one is reported and the surface stays untrimmed
phl_check "Patch: closed curve 2 is not wholly inside the outer boundary; keeping the untrimmed fitted surface" "a second closed curve crossing the outer one is refused as a hole with the reason printed"
phl_check "untrimmed, spanning the data's extent" "...and the fitted surface is returned untrimmed (the old behavior for that input)"

# NetworkSrf through FIVE curves (same script, case 3): the command used to keep only the
# first 4 curves. Now the curves are chained into a closed loop (any order or direction;
# here scrambled, two drawn backwards), joined, fitted by the kernel's least-squares
# NurbsSurface::FitPatch and trimmed by the joined loop: ONE face. It is approximate (not an
# interpolating Coons patch) and says so, printing the measured deviations.
phl_check "NetworkSrf: 5 curves chained into a closed loop; kernel least-squares NURBS patch ([0-9]* x [0-9]* net, worst deviation from the curves [0-9.e-]* vs tolerance 0.001: met) trimmed by the joined loop, trimmed edge within [0-9.e-]* of the loop (approximate: fitted through the boundary samples, not an interpolating Coons patch)" "NetworkSrf of five scrambled/reversed pieces of the saddle ring chains, joins, fits within the 0.001 tolerance and trims, and labels itself approximate"
PHL_NW_FIT="$({ grep -o 'worst deviation from the curves [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* curves //')"
PHL_NW_EDGE="$({ grep -o 'trimmed edge within [0-9.e-]* of the loop' <<<"$PHL_OUT" || true; } | sed 's/trimmed edge within //; s/ of the loop//')"
if phl_in_range "$PHL_NW_FIT" 0 0.001; then echo "ok   five-curve NetworkSrf: fit deviation from the curves $PHL_NW_FIT <= 0.001 (0.00018 when written)"; else echo "FAIL five-curve NetworkSrf fit deviation '$PHL_NW_FIT'"; fail=1; fi
if phl_in_range "$PHL_NW_EDGE" 0 0.001; then echo "ok   five-curve NetworkSrf: trimmed edge within $PHL_NW_EDGE of the loop <= 0.001 (0.00017 when written)"; else echo "FAIL five-curve NetworkSrf edge deviation '$PHL_NW_EDGE'"; fail=1; fi
phl_check "  1 faces, 1 edges, open" "the five-curve NetworkSrf is ONE face bounded by ONE joined edge (not 5 edges, not the first 4 curves only)"
PHL_A_NW="$(phl_area 5)"
if phl_in_range "$PHL_A_NW" 83 89; then echo "ok   five-curve NetworkSrf area $PHL_A_NW in 83..89 (86.01 when written; the single-closed-curve Patch of the same saddle ring measures 84.93)"; else echo "FAIL five-curve NetworkSrf area '$PHL_A_NW'"; fail=1; fi
phl_check "NetworkSrf: 5 curves could not be fitted (the 5 curves do not close into a loop within the document tolerance 0.001 (largest corner gap 0.5)); using the first 4 curves only" "five curves open by 0.5 (> tolerance) are NOT silently fitted: the measured gap is the printed reason and the old first-4 behavior runs"


exit $fail
