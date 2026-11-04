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
HERE="/home/user/miniature-pancake/.claude/worktrees/agent-a102f7e751a3e860d/dino8-app/tests"
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
  HS="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/history_script.txt" 2>&1)" || { echo "$HS"; echo "FAIL: history script exited non-zero"; exit 1; }
else
  HS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/history_script.txt" 2>&1)" || { echo "$HS"; echo "FAIL: history script exited non-zero"; exit 1; }
fi
echo "$HS" | grep -E "^(ok|FAIL)"
if echo "$HS" | grep -q "^FAIL"; then fail=1; fi
echo "$HS" | grep -q "^smoke:" || { echo "$HS"; echo "FAIL: history script produced no smoke line"; fail=1; }
hcheck() { if echo "$HS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HS" "$1"; fail=1; fi; }
hcheck "History recording: off. 0 object(s) with live construction history" "History defaults Off and reports it"
hcheck "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry" "an Extrude made while History was Off recorded nothing for UpdateHistory to redo"
hcheck "History recording: on - new results of 39 construction commands (BlendSrf/Boolean2Objects/BooleanDifference/BooleanIntersection/BooleanUnion/Cap/ChamferEdge/ChamferSrf/Contour/Extrude/" "History On toggled recording on and now lists the registry-driven set of recordable constructions (was a hand-written 10-name sentence; the registry now has 39 names (the 38 listed plus FilletSurfaces, see FSR_) - 23 before the H2R_ additions BlendSrf, Cap, ChamferEdge, FilletEdge, Project and Pull, the H3R_ additions ChamferSrf and FilletSrf, and the H4R_ additions Contour, ExtrudeSrfAlongCrv, ExtrudeSrfTapered, ExtrudeSrfToPoint, OffsetCrvOnSrf, OffsetMultiple and Section - e.g. Shell, ExtrudeSrf, Offset, OffsetSrf, RailRevolve and the four booleans on top of the old Extrude/ExtrudeCrvToPoint/Revolve/Loft/SubDLoft/Pipe/Sweep1/Sweep2/Patch/NetworkSrf2)"
# ---------------------------------------------------------------------------
# FSR_: FilletSurfaces - the kernel's tolerance-bounded rolling-ball blend PATCH between two surfaces (fsr_script.txt; kernel:
# FilletSurfaces, pinned by surface_fillet_tests in dino8-kernel/tests/test_basic.cpp). The command is named FilletSurfaces
# because FilletSrf already exists (the older offset+SSX construction, still pinned by H3R_). The patch is a NEW surface object;
# the parents are not trimmed (no Trim option) and no solid is built. Each of the two picks chooses its ball side (the side
# facing the other pick); the command prints the kernel's sampled deviation, interval count, normal alignment and start/end
# trim, and the contact curves measured against the parents. Every value below was measured on this build; the windows say so:
#   plane floor z = 0 / plane wall x = 0, r = 1: blend bbox 0,0,0 .. 1,10,1 (analytic: x 0..r, z 0..r), deviation 7.1e-15, 16 intervals, trims 0
#   lofted floor / leaning wall, r = 0.8, tol 1e-4: deviation 7.5e-05 over 18 intervals, trims 0.128 / 0.060, contact gaps 4.7e-06 / 1.9e-05
#   tolerance sweep on that pair: tol 1e-3 -> 2.5e-04 (16 intervals), 1e-4 -> 7.5e-05 (18), 1e-6 -> 9.8e-07 (63)
# Not verified here: the deviation is the kernel's SAMPLED maximum (stations, quarter, half and three-quarter points), not a bound between
# samples; a rational parent; a polysurface face with a trimmed boundary (the untrimmed underlying surface is blended); Trim.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FSRO="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/fsr_script.txt" 2>&1)" || { echo "$FSRO"; echo "FAIL: fsr script exited non-zero"; exit 1; }
else
  FSRO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/fsr_script.txt" 2>&1)" || { echo "$FSRO"; echo "FAIL: fsr script exited non-zero"; exit 1; }
fi
fsrblock() { awk -v name="$1" '$0 ~ ("Unknown command: FSRBEGIN_" name "$") { on = 1; next } on && /Unknown command: FSRBEGIN_/ { exit } on { print }' <<<"$FSRO"; }
fsrcheck() { local blk; blk="$(fsrblock "$1")"; if grep -qF -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -F "FilletSurfaces" <<<"$blk" | head -6 | sed 's/^/     actual:   /' || true; fail=1; fi; }
fsrnot() { local blk; blk="$(fsrblock "$1")"; if grep -qF -- "$2" <<<"$blk"; then echo "FAIL $3"; echo "     unexpected: $2"; fail=1; else echo "ok   $3"; fi; }
fsrok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
# fsrobjs NAME N DESC: the case's last List shows exactly N surface objects (BoundingBox adds a box solid, which is not counted)
fsrobjs() { local n; n="$(fsrblock "$1" | awk '/^history: Command: List$/ { c = 0; next } /^history: Object [0-9]+ \(surface\)/ { c++ } END { print c + 0 }' || true)"; if [ "$n" = "$2" ]; then echo "ok   $3 ($n object(s))"; else echo "FAIL $3 ('$n' object(s), expected $2)"; fail=1; fi; }
# fsrbb NAME N: the case's N-th "Bounding box" as x0,y0,z0,x1,y1,z1
fsrbb() { fsrblock "$1" | grep -oE 'Bounding box min [^ ]+ max [^ ]+' | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/' || true; }
fsrclosebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
# fsrsb NAME N EXPECTED TOL DESC
fsrsb() { local got; got="$(fsrbb "$1" "$2")"; fsrok "$(fsrclosebb "$got" "$3" "$4")" "$5 (measured $got, expected $3 +/- $4)"; }
# fsrval NAME LINE_REGEX SED_EXPR: the last line of the case matching LINE_REGEX, through a sed -E substitution (empty if none)
fsrval() { fsrblock "$1" | grep -E "$2" | tail -1 | sed -nE "s/$3/\\1/p" || true; }
fsrrange() { fsrok "$(awk -v v="${1:-}" -v lo="$2" -v hi="$3" 'BEGIN{ print (v != "" && v + 0 >= lo && v + 0 <= hi) ? 1 : 0 }')" "$4 (measured ${1:-none}, window [$2, $3])"; }
# the printed MEASURED deviation, tolerance, interval count, alignment and trims of a case's last successful fillet
fsrdev() { fsrval "$1" "FilletSurfaces: MEASURED deviation" "^.*MEASURED deviation ([0-9.e+-]+) .*$"; }
fsrtol() { fsrval "$1" "FilletSurfaces: MEASURED deviation" "^.*, tolerance ([0-9.e+-]+)\\) over.*$"; }
fsrint() { fsrval "$1" "FilletSurfaces: MEASURED deviation" "^.* over ([0-9]+) intervals.*$"; }
fsralign() { fsrval "$1" "FilletSurfaces: normal alignment" "^.*normal alignment ([0-9.e+-]+) .*$"; }
fsrst() { fsrval "$1" "FilletSurfaces: start trim" "^.*start trim ([0-9.e+-]+), end trim.*$"; }
fsret() { fsrval "$1" "FilletSurfaces: start trim" "^.*end trim ([0-9.e+-]+) .*$"; }
fsrdevcheck() { # NAME DESC: 0 <= deviation <= the tolerance printed on the same line
  local d t; d="$(fsrdev "$1")"; t="$(fsrtol "$1")"
  fsrok "$(awk -v d="${d:-}" -v t="${t:-}" 'BEGIN{ print (d != "" && t != "" && d + 0 >= 0 && d + 0 <= t + 0) ? 1 : 0 }')" "$2: printed deviation <= printed tolerance (measured ${d:-none}, tolerance ${t:-none})"
}
FSR_MSG="FilletSurfaces: blend patch added as object"
FSR_NOTRIM="FilletSurfaces: the two parent surfaces are NOT trimmed back to the contact curves"

# --- analytic: plane floor + plane wall, r = 1
fsrcheck plane "FilletSurfaces: ball sides chosen from the picks - object 1 face 0: side" "FSR_plane: the chosen ball sides are printed"
fsrcheck plane "$FSR_MSG 3 between object 1 and object 2 (radius 1, tolerance 1.000e-03)" "FSR_plane: the blend is a NEW object 3 between the two parents"
fsrobjs plane 3 "FSR_plane: object count is the two parents + the patch"
fsrcheck plane "degree 3 x 2, CVs 17 x 3" "FSR_plane: the patch is a cubic x quadratic NURBS (17 x 3 control points)"
fsrsb plane 1 "0,0,0,1,10,1" 0.001 "FSR_plane: blend bounding box is x 0..r, y 0..10, z 0..r (analytic quarter cylinder, r = 1)"
fsrsb plane 2 "0,0,0,20,10,0" 0.001 "FSR_plane: the floor is not trimmed (bounding box unchanged)"
fsrsb plane 3 "0,0,0,0,10,10" 0.001 "FSR_plane: the wall is not trimmed (bounding box unchanged)"
fsrdevcheck plane "FSR_plane"
fsrrange "$(fsrint plane)" 8 512 "FSR_plane: interval count"
fsrrange "$(fsralign plane)" 0.999 1.000001 "FSR_plane: smallest |cos| of the blend normal against the ball direction"
fsrrange "$(fsrst plane)" 0 0.001 "FSR_plane: start trim (planes: the contact points never leave the surfaces)"
fsrrange "$(fsret plane)" 0 0.001 "FSR_plane: end trim"
fsrcheck plane "FilletSurfaces: contact A points 1.000000,0.000000,0.000000 1.000000,5.000000,0.000000 1.000000,10.000000,0.000000" "FSR_plane: contact A points are exactly (r, y, 0) on the floor"
fsrcheck plane "FilletSurfaces: contact B points 0.000000,0.000000,1.000000 0.000000,5.000000,1.000000 0.000000,10.000000,1.000000" "FSR_plane: contact B points are exactly (0, y, r) on the wall"
fsrcheck plane "$FSR_NOTRIM" "FSR_plane: the message says the parents are NOT trimmed"
fsrnot plane "Trim=" "FSR_plane: ...and no Trim option is offered"

# --- curved: lofted floor + leaning wavy wall, r = 0.8, tolerance 1e-4
fsrcheck curved "$FSR_MSG 11 between object 5 and object 10 (radius 0.8, tolerance 1.000e-04)" "FSR_curved: the blend is a new object 11 between the two lofted parents 5 and 10"
fsrobjs curved 3 "FSR_curved: objects after the fillet"
fsrcheck curved "object 5 face 0: side -1 (against the surface normal) (facing the second pick); object 10 face 0: side +1 (along the surface normal) (facing the first pick)" "FSR_curved: ball sides: floor -1, wall +1 (above the floor, on the floor side of the wall)"
fsrdevcheck curved "FSR_curved"
fsrrange "$(fsrdev curved)" 1e-7 1e-4 "FSR_curved: the printed deviation is positive (not a dummy zero) and within 1e-4 (measured 7.5e-05)"
fsrrange "$(fsrint curved)" 12 40 "FSR_curved: interval count (18 on the reference run)"
fsrrange "$(fsralign curved)" 0.999 1.000001 "FSR_curved: normal alignment"
fsrrange "$(fsrst curved)" 0.05 0.25 "FSR_curved: start trim (0.128 on the reference run: the contact points would leave the floor's domain)"
fsrrange "$(fsret curved)" 0.02 0.15 "FSR_curved: end trim (0.060 on the reference run)"
fsrsb curved 1 "3.678,0,-0.258,5.158,10,1.193" 0.01 "FSR_curved: blend bounding box (4 significant digits printed)"
fsrcheck curved "degree 3 x 3, CVs 5 x 4" "FSR_curved: the parents keep their lofted control nets (5 x 4)"
fsrcheck curved "$FSR_NOTRIM" "FSR_curved: the message says the parents are NOT trimmed"
# contact curves vs the parents: the command's own 33-sample measurement, then ClosestPt of the printed contact points (second run)
FSR_GA="$(fsrval curved "FilletSurfaces: contact curves measured" "^.*on object 5 ([0-9.e+-]+), on object 10.*$")"
FSR_GB="$(fsrval curved "FilletSurfaces: contact curves measured" "^.*on object 10 ([0-9.e+-]+)$")"
fsrrange "$FSR_GA" 0 0.0001 "FSR_curved: contact curve A lies on the floor (the command's 33-sample closest-point gap; tolerance 1e-4)"
fsrrange "$FSR_GB" 0 0.0001 "FSR_curved: contact curve B lies on the wall (33-sample gap; tolerance 1e-4)"
FSR_CPS="$TMPW/fsr_cp_script.txt"
FSR_PA="$(fsrblock curved | grep -F "FilletSurfaces: contact A points" | head -1 | sed -E 's/^.*contact A points //' || true)"
FSR_PB="$(fsrblock curved | grep -F "FilletSurfaces: contact B points" | head -1 | sed -E 's/^.*contact B points //' || true)"
{
  echo "SetActiveViewport Top"
  awk '/^FSRBEGIN_curved$/ { on = 1 } /^FSRBEGIN_curved_ref_big$/ { on = 0 } on' "$HERE/fsr_script.txt"
  for p in $FSR_PA; do printf 'SelNone\nSelID 5\nClosestPt\n%s\nEnter\n' "$p"; done
  for p in $FSR_PB; do printf 'SelNone\nSelID 10\nClosestPt\n%s\nEnter\n' "$p"; done
} > "$FSR_CPS"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FSRC="$(timeout 900 "$BIN" --smoke 60 --script "$FSR_CPS" 2>&1)" || { echo "$FSRC"; echo "FAIL: fsr closest-point script exited non-zero"; exit 1; }
else
  FSRC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$FSR_CPS" 2>&1)" || { echo "$FSRC"; echo "FAIL: fsr closest-point script exited non-zero"; exit 1; }
fi
mapfile -t FSR_CPD < <(grep -oE "^history: Closest point [^ ]+ distance [0-9.e+-]+" <<<"$FSRC" | sed -E 's/.* distance //' || true)
if [ "${#FSR_CPD[@]}" -eq 6 ]; then
  echo "ok   FSR_curved: ClosestPt ran for the 6 printed contact points (3 on the floor, 3 on the wall)"
  for i in 0 1 2; do fsrrange "${FSR_CPD[$i]}" 0 0.0001 "FSR_curved: ClosestPt of contact A point $i on the floor (object 5), distance"; done
  for i in 3 4 5; do fsrrange "${FSR_CPD[$i]}" 0 0.0001 "FSR_curved: ClosestPt of contact B point $((i - 3)) on the wall (object 10), distance"; done
else
  echo "FAIL FSR_curved: expected 6 ClosestPt distances, got ${#FSR_CPD[@]}"; fail=1
fi
if grep -q "FilletSurfaces: blend patch added as object 11" <<<"$FSRC"; then echo "ok   FSR_curved: the ClosestPt script rebuilt the same blend (object 11) the points were printed from"; else echo "FAIL FSR_curved: the ClosestPt script did not rebuild the blend"; fail=1; fi

# --- ball side flips with the pick: the wall picked BELOW the floor gives the underside fillet (floor side +1)
fsrcheck curved_under "object 5 face 0: side +1 (along the surface normal)" "FSR_under: a wall pick below the floor flips the floor's ball side to +1"
fsrdevcheck curved_under "FSR_under"
fsrrange "$(fsrdev curved_under)" 1e-7 1e-4 "FSR_under: deviation positive and within 1e-4 (measured 8.4e-05)"
fsrsb curved_under 1 "3.566,0,-0.5287,4.563,10,0.3237" 0.01 "FSR_under: the underside blend's bounding box lies below the top blend's (z max 0.324 vs 1.193)"

# --- the tolerance really controls the result: looser -> fewer intervals, tighter -> more, each printed deviation within its tolerance
fsrdevcheck curved_tol_loose "FSR_tol 1e-3"
fsrdevcheck curved_tol_tight "FSR_tol 1e-6"
fsrrange "$(fsrint curved_tol_loose)" 8 17 "FSR_tol 1e-3: interval count (16 on the reference run)"
fsrrange "$(fsrint curved_tol_tight)" 40 512 "FSR_tol 1e-6: interval count (63 on the reference run: more than the 1e-4 run's 18)"
fsrrange "$(fsrdev curved_tol_tight)" 1e-8 1e-6 "FSR_tol 1e-6: deviation within 1e-6 and not a dummy zero (measured 9.8e-07)"

# --- refusals: the kernel's reason, nothing built (object count unchanged)
fsrcheck ref_big "refused - dino8::kernel::FilletSurfaces: the offsets do not intersect: the centre equations (both surfaces offset by the radius) have no solution at any of" "FSR_ref_big: a radius 40 on 20 x 10 planes is refused with the kernel's reason (the ball does not fit)"
fsrcheck ref_big "nothing was built" "FSR_ref_big: ...and says nothing was built"
fsrnot ref_big "$FSR_MSG" "FSR_ref_big: ...no blend is claimed"
fsrobjs ref_big 2 "FSR_ref_big: only the two parents exist"
fsrcheck curved_ref_big "refused - dino8::kernel::FilletSurfaces: the offsets do not intersect" "FSR_curved_ref_big: radius 40 on the lofted pair is refused with the kernel's reason"
fsrnot curved_ref_big "$FSR_MSG" "FSR_curved_ref_big: ...no blend is claimed"
fsrobjs curved_ref_big 3 "FSR_curved_ref_big: the object count is unchanged (parents 5, 10 + the earlier blend 11)"
fsrcheck ref_parallel "refused - dino8::kernel::FilletSurfaces: the surfaces do not intersect (parallel, separated, or only touching): there is no edge to blend; nothing was built" "FSR_ref_parallel: parallel planes z = 0 and z = 5 are refused with the kernel's reason"
fsrobjs ref_parallel 2 "FSR_ref_parallel: only the two parents exist"
fsrcheck ref_same "refused - both picks are the same surface (object 1, face 0); a fillet needs two different surfaces; nothing was built" "FSR_ref_same: the same surface picked twice is refused with its reason"
fsrnot ref_same "ball sides chosen" "FSR_ref_same: ...refused before any side is chosen"
fsrobjs ref_same 2 "FSR_ref_same: only the two parents exist"
fsrcheck curved_ref_tol "refused - dino8::kernel::FilletSurfaces: tolerance " "FSR_curved_ref_tol: Tolerance=1e-14 is refused with the kernel's reason"
fsrcheck curved_ref_tol "not reached: the best sampled deviation is" "FSR_curved_ref_tol: ...naming the best deviation reached"
fsrobjs curved_ref_tol 3 "FSR_curved_ref_tol: the object count is unchanged"
fsrcheck opt_zero_tol "FilletSurfaces: Radius must be a positive number (kept 1)" "FSR_opt: Radius=0 is rejected at the option and the previous radius is kept"
fsrcheck opt_zero_tol "FilletSurfaces: Tolerance must be a positive number (kept 0.001)" "FSR_opt: Tolerance=0 is rejected at the option; the default is the document tolerance 0.001"
fsrcheck opt_zero_tol "(radius 1, tolerance 1.000e-03)" "FSR_opt: ...and the fillet builds with the kept radius and the document tolerance"

# --- History: recorded like BlendSrf / FilletSrf (Trim=No), follows an edit of either parent, EditHistory changes the radius
fsrcheck hist "object 3: FilletSurfaces <- 1,2  [radius=1, tolerance=0.001]" "FSR_hist: the patch records both parents, radius and tolerance"
fsrsb hist 1 "0,0,0,1,10,1" 0.001 "FSR_hist: r = 1 patch before any edit"
fsrcheck hist "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (3)" "FSR_hist: moving the wall rebuilds the patch automatically"
fsrsb hist 2 "3,0,0,4,10,1" 0.001 "FSR_hist: wall moved +3 X: the patch followed (x 3..4)"
fsrcheck hist "EditHistory: object 3 (FilletSurfaces): radius 1 -> 2." "FSR_hist: EditHistory changes the radius"
fsrsb hist 3 "3,0,0,5,10,2" 0.001 "FSR_hist: radius-2 rebuild spans x 3..5, z 0..2"
FSR_HB3="$(fsrbb hist 3)"; FSR_HB4="$(fsrbb hist 4)"
fsrok "$(fsrclosebb "$FSR_HB3" "$FSR_HB4" 0.001)" "FSR_hist: the rebuilt patch equals the same r = 2 fillet built fresh (History Off) between the moved parents (rebuilt $FSR_HB3, fresh $FSR_HB4)"
fsrcheck hist_refused "0 object(s) with live construction history" "FSR_hist_refused: a refused fillet records no history"
fsrcheck hist_keep "kept as they were: object 3 - source object 1 no longer exists" "FSR_hist_keep: a deleted parent makes the rebuild refuse with the reason"
fsrsb hist_keep 2 "0,0,0,1,10,1" 0.001 "FSR_hist_keep: ...and the old patch keeps its shape"
fsrcheck hist "39 construction commands" "FSR_hist: the History registry lists FilletSurfaces (39 recordable constructions)"

# --- negative controls: existing BlendSrf / FilletEdge / FilletSrf are unchanged and never reach FilletSurfaces
fsrcheck ctl_blend "BlendSrf: blend surface added between object 1 and 2 (Continuity=Tangency, exact kernel blend)" "FSR_ctl_blend: BlendSrf keeps its message and exact kernel path"
fsrsb ctl_blend 1 "10,0,0,20.31,10,0" 0.1 "FSR_ctl_blend: BlendSrf bounding box is the H2R_blend window (10,0,0 .. 20.31,10,0)"
fsrnot ctl_blend "FilletSurfaces:" "FSR_ctl_blend: ...FilletSurfaces is not involved"
fsrcheck ctl_filletedge "FilletEdge: edge 5 of object 1 replaced with an exact fillet (radius 1)" "FSR_ctl_filletedge: FilletEdge keeps its exact planar fillet message"
fsrcheck ctl_filletedge "7 faces, 15 edges, closed solid" "FSR_ctl_filletedge: 7 faces, 15 edges, closed solid (as PTF_ctl_box)"
fsrcheck ctl_filletedge "Object 1: valid" "FSR_ctl_filletedge: Check valid"
fsrrange "$(fsrblock ctl_filletedge | grep -oE 'Volume = [0-9.e+-]+' | tail -1 | sed 's/Volume = //' || true)" 142.5 142.9 "FSR_ctl_filletedge: Volume = 144 - (1 - pi/4) * 6 = 142.712 (PTF_ctl_box window)"
fsrnot ctl_filletedge "FilletSurfaces:" "FSR_ctl_filletedge: ...FilletSurfaces is not involved"
fsrcheck ctl_filletsrf "FilletSrf: built between object 1 and 2, radius 1" "FSR_ctl_filletsrf: the older FilletSrf keeps its own message (it is a different command)"
fsrsb ctl_filletsrf 1 "0,0,0,1,10,1" 0.05 "FSR_ctl_filletsrf: FilletSrf bounding box is the H3R_fillet window"
fsrrange "$(fsrblock ctl_filletsrf | grep -oE 'Area = [0-9.e+-]+' | tail -1 | sed 's/Area = //' || true)" 15.6 15.8 "FSR_ctl_filletsrf: area pi/2 x 10 = 15.71 (H3R_fillet window)"
fsrnot ctl_filletsrf "FilletSurfaces:" "FSR_ctl_filletsrf: ...FilletSurfaces is not involved"
if grep -q "gl_error=0" <<<"$FSRO"; then echo "ok   FSR script ran without OpenGL errors"; else echo "FAIL FSR script ran without OpenGL errors"; fail=1; fi

exit $fail
