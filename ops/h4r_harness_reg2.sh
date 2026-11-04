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
# History / associative re-execution, round 2 (H2R_): FilletEdge, ChamferEdge, Cap,
# BlendSrf and Project/Pull record construction history (tests/h2r_edge_script.txt,
# h2r_cap_script.txt, h2r_blend_script.txt, h2r_proj_script.txt).
# FilletEdge/ChamferEdge on a solid: with History On the solid is hidden (kept as the
# recorded source) and the exact result is a new object that records the radius or
# distances and, per edge, a geometric signature (direction, both face normals, position
# relative to the solid's bounding box); editing the source re-finds each edge by that
# signature on the edited solid and re-runs the exact kernel fillet/chamfer. Every
# number below is a measured Volume or Bounding box, compared with the SAME operation
# performed fresh (History Off) on the moved/scaled source; negative controls: History
# Off records nothing, a rotated source is still followed (edge re-found by its position
# in the edge list, dihedral angle and relative length), a source chamfered on the very
# edge that was filleted makes the rebuild refuse with the reason and keep the old result,
# Rho fillet / angle chamfer / a Project that splits into pieces / a Cap of a closed solid
# record nothing.
# Tolerances: tessellation-derived values (volume, blend bounding boxes) are compared
# with ranges, as the Windows CI tessellates slightly differently.
# ---------------------------------------------------------------------------
H2R_DIR="$TMPW/h2r"
mkdir -p "$H2R_DIR"
h2r_run() {  # h2r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H2R_DIR|g" "$HERE/h2r_$1_script.txt" > "$H2R_DIR/h2r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H2R_DIR/h2r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H2R_DIR/h2r_$1_script.txt" 2>&1
  fi
}
h2r_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
h2r_vol() { { grep -oE 'Volume = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Volume = //'; }
h2r_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
h2r_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
h2r_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
h2r_sh() { h2r_ok "$(h2r_closev "$(h2r_vol "$1" "$2")" "$3" "$4")" "$5 (measured $(h2r_vol "$1" "$2"), expected $3 +/- $4)"; }
h2r_sb() { h2r_ok "$(h2r_closebb "$(h2r_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(h2r_bb "$1" "$2"), expected $3)"; }
h2r_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
h2r_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }
h2r_countre() { local n; n="$(grep -cE -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- FilletEdge / ChamferEdge (h2r_edge_script.txt)
H2R_E="$(h2r_run edge)" || { echo "$H2R_E"; echo "FAIL: h2r edge script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_E" || { echo "$H2R_E"; echo "FAIL: h2r edge script produced no smoke line"; fail=1; }
# Volumes: 1 fillet r2 (991.4) 2 source moved +5 X 3 source scaled 2x (7983) 4 after Undo 5 EditHistory radius=3 (980.6) 6 reopened source moved +5 Y
#   7 two chamfers of 3 (910) 8 source moved 9 source scaled 2x (7820) 10 EditHistory distance=2 (7920) 11 asymmetric chamfer 2/4 (960) 12 source moved +3 Z
#   13 EditHistory distance2=1 (990) 14 History Off fillet 15 ...after Move 16 source rotated 30 degrees: followed 17 source chamfered on the recorded edge: old result kept
#   18-21 fresh controls (7983, 7820, 980.6, rotated 991.4)
# Bounding boxes: 1 fillet 2 moved +5 X 3 reopened source moved +5 X then +5 Y 4 chamfered box moved +7 X 5 rotated source 6 fresh rotated control
h2r_has "$H2R_E" "FilletEdge: edge 10 of object 1 replaced with an exact fillet (radius 2); History is On: the original solid 1 is kept hidden as the source and the result is object 2" "H2R_fillet: with History On the exact fillet hides its source (kept, not edited in place) and the result is a new object"
h2r_has "$H2R_E" "object 2: FilletEdge <- 1  [radius=2]" "H2R_fillet: the record names the source solid and the radius"
h2r_sh "$H2R_E" 1 991.4 0.3 "H2R_fillet: box 10^3, fillet radius 2 (1000 - (1-pi/4)*2^2*10)"
h2r_sb "$H2R_E" 1 "0,0,0,10,10,10" 0.05 "H2R_fillet: result bounding box"
h2r_sh "$H2R_E" 2 991.4 0.3 "H2R_fillet: source moved +5 in X, no UpdateHistory: the fillet followed (same volume)"
h2r_sb "$H2R_E" 2 "5,0,0,15,10,10" 0.05 "H2R_fillet: ...and its bounding box moved with the source"
h2r_has "$H2R_E" "FilletEdge: edge 1 re-found as edge 10 of the source (direction and both face normals match)" "H2R_fillet: the recorded edge was re-found on the edited source and the rebuild says so"
h2r_has "$H2R_E" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (2)" "H2R_fillet: automatic propagation line names the dependent"
h2r_sh "$H2R_E" 3 7983 3 "H2R_fillet: source scaled 2x about (5,0,0): the same edge re-found, radius kept (8000 - (1-pi/4)*2^2*20)"
h2r_sh "$H2R_E" 18 "$(h2r_vol "$H2R_E" 3)" 3 "H2R_fillet control: the same fillet performed fresh (History Off) on a 20^3 box at x 5..25 has the same volume as the rebuilt one"
h2r_sh "$H2R_E" 18 7983 3 "H2R_fillet control: fresh volume itself, measured"
h2r_sh "$H2R_E" 4 991.4 0.3 "H2R_fillet: Undo restores the previous result (the rebuild is inside the edit's undo step)"
h2r_has "$H2R_E" "EditHistory: object 2 (FilletEdge): radius 2 -> 3." "H2R_fillet: EditHistory exposes and changes the recorded radius"
h2r_sh "$H2R_E" 5 980.6 0.3 "H2R_fillet: after EditHistory radius=3 (1000 - (1-pi/4)*3^2*10)"
h2r_has "$H2R_E" "object 2: FilletEdge <- 1  [radius=3]" "H2R_fillet: after Save/New/Open the record (with its edge signature) is read back from the .3dm"
h2r_sh "$H2R_E" 6 980.6 0.3 "H2R_fillet: reopened, source moved +5 in Y: the fillet followed with its radius"
h2r_sb "$H2R_E" 3 "5,5,0,15,15,10" 0.05 "H2R_fillet: reopened source moved: bounding box followed"
h2r_sh "$H2R_E" 20 "$(h2r_vol "$H2R_E" 6)" 0.3 "H2R_fillet control: the same radius-3 fillet performed fresh on the moved box has the same volume"
h2r_has "$H2R_E" "ChamferEdge: edge 6 of object 2 replaced with an exact chamfer (radius 3); recorded in the history of object 2 (now 2 step(s))" "H2R_chamfer: a second pick in the same run extends the record of the first result instead of chaining"
h2r_has "$H2R_E" "object 2: ChamferEdge <- 1  [distance=3, distance2=3]" "H2R_chamfer: one record, source 1, both distances"
h2r_sh "$H2R_E" 7 910 0.5 "H2R_chamfer: two chamfers of 3 on a 10^3 box (1000 - 2*3*3/2*10)"
h2r_sh "$H2R_E" 8 910 0.5 "H2R_chamfer: source moved +7 in X: both chamfers followed"
h2r_sb "$H2R_E" 4 "7,0,0,17,10,10" 0.05 "H2R_chamfer: ...bounding box moved with the source"
h2r_has "$H2R_E" "ChamferEdge: edge 2 re-found as edge 6 of the source (direction and both face normals match)" "H2R_chamfer: the second step's edge is re-found as well"
h2r_sh "$H2R_E" 9 7820 3 "H2R_chamfer: source scaled 2x about (7,0,0): 20^3 box with two chamfers of 3 (8000 - 2*4.5*20)"
h2r_sh "$H2R_E" 19 7820 3 "H2R_chamfer control: the same two chamfers performed fresh on a 20^3 box at x 7..27"
h2r_has "$H2R_E" "EditHistory: object 2 (ChamferEdge): distance 3 -> 2." "H2R_chamfer: EditHistory changes the distance"
h2r_sh "$H2R_E" 10 7920 3 "H2R_chamfer: after EditHistory distance=2 both chamfers are rebuilt (8000 - 2*2*20)"
h2r_has "$H2R_E" "ChamferEdge: edge 10 of object 1 replaced with an exact chamfer (distance1 2, distance2 4); History is On" "H2R_chamfer: an asymmetric chamfer records too"
h2r_has "$H2R_E" "object 2: ChamferEdge <- 1  [distance=2, distance2=4]" "H2R_chamfer: both distances are in the record"
h2r_sh "$H2R_E" 11 960 0.5 "H2R_chamfer: distances 2 and 4 on a 10^3 box (1000 - 2*4/2*10)"
h2r_sh "$H2R_E" 12 960 0.5 "H2R_chamfer: source moved +3 in Z: unchanged volume"
h2r_has "$H2R_E" "EditHistory: object 2 (ChamferEdge): distance2 4 -> 1." "H2R_chamfer: EditHistory changes distance2"
h2r_sh "$H2R_E" 13 990 0.5 "H2R_chamfer: after distance2=1 (1000 - 2*1/2*10)"
# negative controls
h2r_countre "$H2R_E" 'exact fillet \(radius 2\)$' 3 "H2R_off control: with History Off (the N1 box and the fresh X1 and X4 controls) the fillet message carries no history note (edited in place, nothing hidden)"
h2r_has "$H2R_E" "History recording: off. 0 object(s) with live construction history" "H2R_off control: History Off records nothing"
h2r_sh "$H2R_E" 14 991.4 0.3 "H2R_off control: the in-place fillet of the original box has the same volume"
h2r_sh "$H2R_E" 15 991.4 0.3 "H2R_off control: moving the filleted box changes nothing else"
h2r_has "$H2R_E" "FilletEdge: edge 1 re-found as edge 10 of the source (the solid was re-oriented: same position in its edge list, same dihedral angle and relative length)" "H2R_rotate: a source rotated 30 degrees about Z has no edge with the recorded direction/normals; the solid kept its topology, so the edge is re-found by its position in the edge list, dihedral angle and relative length, and the rebuild says so"
h2r_sh "$H2R_E" 16 991.4 0.3 "H2R_rotate: the rebuilt fillet on the rotated source has the same volume"
h2r_sb "$H2R_E" 5 "-1.83,-1.83,0,11.83,11.1,10" 0.05 "H2R_rotate: ...and the bounding box of a rotated, filleted box"
h2r_sb "$H2R_E" 6 "-1.83,-1.83,0,11.83,11.1,10" 0.05 "H2R_rotate control: the same fillet performed fresh on the rotated box has the same bounding box"
h2r_sh "$H2R_E" 21 991.4 0.3 "H2R_rotate control: ...and the same volume"
h2r_has "$H2R_E" "no longer exists on the edited source: no edge has that direction between faces with those normals, and the solid's own edge 10 no longer has the recorded dihedral angle and length" "H2R_refuse: the source was chamfered in place on the very edge the fillet was recorded on; the edge vanished and the reason is printed"
h2r_has "$H2R_E" "UpdateHistory: object 2 (FilletEdge) kept as it was: edge 1 of 1:" "H2R_refuse: UpdateHistory keeps the old result and names the edge"
h2r_sh "$H2R_E" 17 991.4 0.3 "H2R_refuse: the old result keeps its volume (not the chamfered source's 955)"
h2r_has "$H2R_E" "staged for an exact conic fillet (rho 0.6" "H2R_rho control: a Rho fillet takes its own exact conic path"
h2r_has "$H2R_E" "not recorded in history (this chamfer mode (distance and angle) is not one the rebuild reproduces)" "H2R_angle control: a distance/angle chamfer says it is not recorded"
h2r_count "$H2R_E" "History recording: on. 0 object(s) with live construction history" 2 "H2R_rho/angle control: after the Rho fillet and after the angle chamfer nothing is recorded"

# --- Cap (h2r_cap_script.txt)
# Bounding boxes: 1 capped box 2 source scaled 2x 3 source rotated 90 deg, saved, reopened, moved +4 Z 4 fresh control 5 History Off moved
H2R_C="$(h2r_run cap)" || { echo "$H2R_C"; echo "FAIL: h2r cap script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_C" || { echo "$H2R_C"; echo "FAIL: h2r cap script produced no smoke line"; fail=1; }
h2r_has "$H2R_C" "Capped 1 object(s), 2 opening(s); History is On: the open polysurface(s) are kept hidden as the source of 1 recorded result(s)" "H2R_cap: with History On Cap hides the open polysurface (kept as the recorded source) and adds the capped copy"
h2r_has "$H2R_C" "object 2: Cap <- 1" "H2R_cap: the record names the open polysurface"
h2r_sb "$H2R_C" 1 "0,0,0,10,10,10" 0.05 "H2R_cap: capped box bounding box"
h2r_sb "$H2R_C" 2 "0,0,0,20,20,20" 0.05 "H2R_cap: source scaled 2x: the capped copy was re-capped on the new size"
h2r_sb "$H2R_C" 4 "0,0,0,20,20,20" 0.05 "H2R_cap control: the same Cap performed fresh (History Off) on a 20^3 open box has the same bounding box"
h2r_count "$H2R_C" "6 faces, 76 edges, open" 4 "H2R_cap: the re-capped copies have the same topology as a fresh Cap (6 faces, 76 edges; both rebuilds and the control)"
h2r_sb "$H2R_C" 3 "-10,0,4,10,20,24" 0.05 "H2R_cap: source rotated 90 degrees about Z, saved, reopened in a new document, moved +4 in Z: the record survived and the caps followed"
h2r_count "$H2R_C" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (2)" 3 "H2R_cap: three automatic updates (scale, rotate, and the Move after Open)"
h2r_sb "$H2R_C" 5 "5,0,0,15,10,10" 0.05 "H2R_cap History Off control: Cap edits in place (the moved result's bounding box)"
h2r_count "$H2R_C" "History recording: off. 0 object(s) with live construction history" 2 "H2R_cap History Off control: nothing recorded (the fresh control box and the in-place Cap both report 0 records)"
h2r_has "$H2R_C" "Capped 0 object(s), 0 opening(s)" "H2R_cap control: Cap of a closed solid does nothing"
h2r_has "$H2R_C" "History recording: on. 0 object(s) with live construction history" "H2R_cap control: ...and records nothing"

# --- Project / Pull (h2r_proj_script.txt)
# Bounding boxes: 1 projected line 2 line moved +1,+1 3 plane moved +4 Z 4 line moved +3 X: refused, kept 5 reopened, line moved -3 X
#                 6 pulled point 7 plane moved +4 Z 8 point moved +2 X 9 fresh control
H2R_P="$(h2r_run proj)" || { echo "$H2R_P"; echo "FAIL: h2r proj script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_P" || { echo "$H2R_P"; echo "FAIL: h2r proj script produced no smoke line"; fail=1; }
h2r_has "$H2R_P" "Project: 1 curve(s), 0 point(s); 1 result(s) recorded in history" "H2R_project: a curve that maps to one piece is recorded"
h2r_has "$H2R_P" "object 3: Project <- 2,1" "H2R_project: the record names the curve and the target"
h2r_sb "$H2R_P" 1 "2,2,0,18,18,0" 0.05 "H2R_project: line (2,2)-(18,18) projected along +Z onto the plane"
h2r_sb "$H2R_P" 2 "3,3,0,19,19,0" 0.05 "H2R_project: source line moved +1,+1: the projection followed"
h2r_sb "$H2R_P" 3 "3,3,4,19,19,4" 0.05 "H2R_project: target plane moved +4 in Z: the projection lifted onto it"
h2r_sb "$H2R_P" 9 "3,3,4,19,19,4" 0.05 "H2R_project control: the same projection performed fresh (History Off) has the same bounding box"
h2r_has "$H2R_P" "has no editable options - its inputs are its source objects" "H2R_project: EditHistory says a projection has no options of its own"
h2r_has "$H2R_P" "the curve now projected to 0 piece(s) instead of the one that was recorded" "H2R_project refuse: a line moved partly off the plane maps to no piece: the reason is printed"
h2r_sb "$H2R_P" 4 "3,3,4,19,19,4" 0.05 "H2R_project refuse: the previous projection is kept"
h2r_has "$H2R_P" "UpdateHistory: object 3 (Project) kept as it was:" "H2R_project refuse: UpdateHistory refuses the same way"
h2r_sb "$H2R_P" 5 "3,3,4,19,19,4" 0.05 "H2R_project: after Save/New/Open the record is back and moving the line back rebuilds it"
h2r_has "$H2R_P" "Pull: 0 curve(s), 1 point(s); 1 result(s) recorded in history" "H2R_pull: a pulled point is recorded"
h2r_has "$H2R_P" "object 3: Pull <- 2,1" "H2R_pull: the record names the point and the target"
h2r_sb "$H2R_P" 6 "5,5,0,5,5,0" 0.05 "H2R_pull: point (5,5,-3) pulled to the plane"
h2r_sb "$H2R_P" 7 "5,5,4,5,5,4" 0.05 "H2R_pull: target plane moved +4 in Z: the pulled point followed"
h2r_sb "$H2R_P" 8 "7,5,4,7,5,4" 0.05 "H2R_pull: source point moved +2 in X: the pulled point followed"
h2r_has "$H2R_P" "Project: 2 curve(s), 0 point(s); 0 result(s) recorded in history, 1 source(s) split into several pieces and not recorded" "H2R_project control: a curve that maps to two pieces is not recorded"
h2r_countre "$H2R_P" '^history: Project: 1 curve\(s\), 0 point\(s\)$' 1 "H2R_project History Off control: the fresh projection prints no history note"

# --- BlendSrf (h2r_blend_script.txt)
# Bounding boxes: 1 blend between two squares 2 second square moved +10 X 3 first square moved +4 Y 4 EditHistory continuity=curvature
#                 5 reopened, second square moved +5 X 6 fresh tangency control 7 fresh curvature control 8,9 refused: source deleted
H2R_B="$(h2r_run blend)" || { echo "$H2R_B"; echo "FAIL: h2r blend script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H2R_B" || { echo "$H2R_B"; echo "FAIL: h2r blend script produced no smoke line"; fail=1; }
h2r_has "$H2R_B" "object 3: BlendSrf <- 1,2  [continuity=tangency]" "H2R_blend: the blend records both surfaces and its continuity (neither is consumed)"
h2r_sb "$H2R_B" 1 "10,0,0,20.31,10,0" 0.1 "H2R_blend: tangent blend between two 10x10 squares 10 apart"
h2r_sb "$H2R_B" 2 "10,0,0,30,10,0" 0.1 "H2R_blend: second square moved +10 in X: the blend lengthened (no UpdateHistory)"
h2r_sb "$H2R_B" 3 "10,0,0,30.37,14,0" 0.1 "H2R_blend: first square moved +4 in Y: the blend followed it"
h2r_sb "$H2R_B" 6 "10,0,0,30.37,14,0" 0.1 "H2R_blend control: the same blend built fresh (History Off) between the surfaces in their moved positions has the same bounding box"
h2r_has "$H2R_B" "EditHistory: object 3 (BlendSrf): continuity tangency -> curvature." "H2R_blend: EditHistory changes the continuity"
h2r_sb "$H2R_B" 4 "10,0,0,30.91,14,0" 0.1 "H2R_blend: curvature-continuous rebuild"
h2r_sb "$H2R_B" 7 "10,0,0,30.91,14,0" 0.1 "H2R_blend control: the same Continuity=Curvature blend built fresh has the same bounding box"
h2r_has "$H2R_B" "object 3: BlendSrf <- 1,2  [continuity=curvature]" "H2R_blend: record (with its edge description) read back from the .3dm after New + Open"
h2r_sb "$H2R_B" 5 "10,0,0,35.81,14,0" 0.1 "H2R_blend: reopened, second square moved +5 in X: the blend followed"
h2r_has "$H2R_B" "kept as they were: object 3 - source object 2 no longer exists" "H2R_blend refuse: a deleted source is reported and the blend is kept"
h2r_sb "$H2R_B" 9 "10,0,0,20.31,10,0" 0.1 "H2R_blend refuse: the old blend keeps its shape"
h2r_has "$H2R_B" "UpdateHistory: object 3 (BlendSrf) kept as it was: source object 2 no longer exists" "H2R_blend refuse: UpdateHistory refuses the same way"

# ---------------------------------------------------------------------------
# SO2: exact Shell / OffsetSrf of RIGHT PRISMS (so2_script.txt; prism_solid.h) - the
# non-convex and filleted-box half of "Solid editing with B-rep results (booleans,
# fillet, shell, offset)". An extruded L and a box whose parallel edges were rounded
# with FilletEdge (planar faces + cylindrical strips) used to decline with 'exact
# B-rep shell not used' / 'exact B-rep offset not used' and become a mesh. The profile
# (lines + arcs) is offset analytically (plane -> parallel plane, cylinder ->
# concentric cylinder, new corners = exact line/line intersections, tangent joints stay
# tangent), the caps move along the axis and the result is extruded back into a closed
# B-rep. Expected volumes are closed forms (Steiner/miter offset of the profile area):
#   area(d) = A + d*P + d^2*(sum of tan(turn/2) at the mitred corners + half the arcs' turning)
# and are read from the display mesh (chord 0.005), so the ranges carry tessellation error.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SO2OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/so2_script.txt" 2>&1)" || { echo "$SO2OUT"; echo "FAIL: so2 script exited non-zero"; exit 1; }
else
  SO2OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/so2_script.txt" 2>&1)" || { echo "$SO2OUT"; echo "FAIL: so2 script exited non-zero"; exit 1; }
fi
so2block() { awk -v name="$1" '$0 ~ ("Unknown command: SO2BEGIN_" name "$") { on = 1; next } on && /Unknown command: SO2BEGIN_|Unknown command: SO2END/ { exit } on { print }' <<<"$SO2OUT"; }
so2check() { local blk; blk="$(so2block "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; { grep -E "^history: (Shell|Offset|Object|  [0-9]|Volume|!)" <<<"$blk" || true; } | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
# so2vol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
so2vol() {
  local blk v; blk="$(so2block "$1")"
  v="$({ grep -E "^history: Volume = " <<<"$blk" || true; } | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/')"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- extruded L (profile area 300, perimeter 80, five convex corners and one reflex corner: area(d) = 300 + 80 d + 4 d^2)
so2check L_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_L_shell: the L-shaped extrusion shell is an exact B-rep (before: 'exact B-rep shell not used', mesh)"
so2check L_shell "11 faces, 21 edges, closed solid" "SO2_L_shell: ...a closed solid, outer extrusion (3 faces) + inner extrusion (8 faces)"
so2vol L_shell 1050 1062 "SO2_L_shell: Volume = 8*300 - 6*224 = 1056 (inner profile area 300 - 80 + 4 = 224, inner height 6)"
so2check L_shell "Object [0-9]*: valid" "SO2_L_shell: ...and Check reports it valid"
so2check L_offset_out "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "SO2_L_offset: OffsetSrf +1 of the L is exact (before: 'exact B-rep offset not used', mesh)"
so2vol L_offset_out 3830 3850 "SO2_L_offset: Volume = (300 + 80 + 4)*(8 + 2) = 3840"
so2check L_offset_out "Object [0-9]*: valid" "SO2_L_offset: ...Check valid"
so2check L_offset_in "OffsetSrf: distance -1, 1 object(s), 1 exact B-rep" "SO2_L_offset_in: OffsetSrf -1 of the L is exact"
so2vol L_offset_in 1338 1350 "SO2_L_offset_in: Volume = (300 - 80 + 4)*(8 - 2) = 1344"
so2check L_offset_in "Object [0-9]*: valid" "SO2_L_offset_in: ...Check valid"
so2check L_offset_solid "solid, 1 exact B-rep" "SO2_L_offset_solid: Solid=Yes (hollow wall between the L and its offset) is exact"
so2vol L_offset_solid 1435 1445 "SO2_L_offset_solid: Volume = 3840 - 2400 = 1440"
so2check L_offset_solid "Object [0-9]*: valid" "SO2_L_offset_solid: ...Check valid"
so2check L_shell_toothick "exact B-rep shell not used (the prism would collapse between its caps at that offset)" "SO2_L_declined: a wall of 5 on an 8-high L (2*5 > 8) is refused WITH the reason"
so2check L_arm_toothin "exact B-rep shell not used (a flat edge of the profile would collapse or reverse at that distance)" "SO2_L_declined: a wall of 5 on a 30-high L with 10-wide arms (the inner offset of an arm reverses) is refused WITH the reason"
# --- box with ONE rounded vertical edge (radius 2): area 100 - (1 - pi/4)*4 = 99.1416, perimeter 39.1416, 3 mitred corners + one quarter arc
so2check F1_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_F1_shell: Shell of a box with a FilletEdge-rounded edge is an exact B-rep (before: 'exact B-rep shell not used', mesh)"
so2vol F1_shell 478 484 "SO2_F1_shell: Volume = 10*99.1416 - 8*(64 - (1 - pi/4)) = 481.13"
so2check F1_shell "Object [0-9]*: valid" "SO2_F1_shell: ...Check valid"
so2check F1_offset "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "SO2_F1_offset: OffsetSrf +1 of the rounded box is exact (cylinder r2 -> concentric r3)"
so2vol F1_offset 1700 1710 "SO2_F1_offset: Volume = 12*(144 - (1 - pi/4)*9) = 1704.82"
so2check F1_offset "7 faces, 15 edges, closed solid" "SO2_F1_offset: ...7 faces (5 walls including the rounded strip, 2 caps), closed solid"
so2check F1_offset "Object [0-9]*: valid" "SO2_F1_offset: ...Check valid"
so2check F1_offset_in "OffsetSrf: distance -0.5, 1 object(s), 1 exact B-rep" "SO2_F1_offset_in: OffsetSrf -0.5 (cylinder r2 -> r1.5) is exact"
so2vol F1_offset_in 722 727 "SO2_F1_offset_in: Volume = 9*(99.1416 - 0.5*39.1416 + 0.25*(3 + pi/4)) = 724.65"
so2check F1_offset_in "Object [0-9]*: valid" "SO2_F1_offset_in: ...Check valid"
# --- box with FOUR rounded vertical edges (radius 2): area 100 - 4*(1 - pi/4)*4 = 96.566
so2check F4_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_F4_shell: Shell of a box with 4 rounded edges is an exact B-rep"
so2vol F4_shell 457 463 "SO2_F4_shell: Volume = 10*96.566 - 8*(64 - 4*(1 - pi/4)) = 460.53"
so2check F4_shell "Object [0-9]*: valid" "SO2_F4_shell: ...Check valid"
so2check F4_offset_solid "solid, 1 exact B-rep" "SO2_F4_offset_solid: Solid=Yes offset of the 4-edge rounded box is exact"
so2vol F4_offset_solid 667 672 "SO2_F4_offset_solid: Volume = 12*(144 - 4*(1 - pi/4)*9) - 965.66 = 669.63"
so2check F4_offset_solid "Object [0-9]*: valid" "SO2_F4_offset_solid: ...Check valid"
# --- tilted prisms (axis not a coordinate axis): the construction is frame-independent
so2check R_F1_shell "Shell: thickness 1, closed, exact B-rep, volume" "SO2_R_F1: the rounded box rotated 37 degrees about (1,2,3) shells exactly"
so2vol R_F1_shell 478 484 "SO2_R_F1: Volume is unchanged by the rotation (481.13)"
so2check R_F1_shell "Object [0-9]*: valid" "SO2_R_F1: ...Check valid"
so2check R_L_offset "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "SO2_R_L: the L rotated 61 degrees about (3,-1,2) offsets exactly"
so2vol R_L_offset 3830 3850 "SO2_R_L: Volume is unchanged by the rotation (3840)"
so2check R_L_offset "Object [0-9]*: valid" "SO2_R_L: ...Check valid"
# --- not a right prism: still declined with its reason
so2check H_shell "exact B-rep shell not used (the cap boundary is not one clean closed loop" "SO2_declined: a box with a Boolean through-hole (sampled keyhole cap loop) is not recognised: refused with the reason, mesh shell kept"
so2check X_notprism "exact B-rep shell not used (" "SO2_declined: a box with a sphere fused on top is not a right prism: the exact shell is refused with a reason"
if grep -q "^FAIL" <<<"$SO2OUT"; then echo "FAIL so2 script reported an in-script FAIL"; fail=1; fi


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
s2n_check "NetworkSrf: these curves cross in their interiors but cannot be fitted as a curve network (curve 1 does not meet the rest of the network within the tolerance (nearest is curve [0-9]*, 0\.[45][0-9]* apart)); using the older loop behaviour" "S2N_miss: a curve lifted 0.5 off the network is refused with the measured miss and the old behaviour runs"
s2n_check "NetworkSrf: curve network of 2 x 2 curves (4 meetings, 4 crossing in their interiors" "S2N_hash: 4 curves forming a # (2 x 2, all crossings interior) take the network path"
S2N_A2="$(s2n_area 2)"
if s2n_in_range "$S2N_A2" 23.5 24.5; then echo "ok   S2N_hash: flat # area $S2N_A2 in 23.5..24.5 (the 6 x 4 bounding rectangle of the curves)"; else echo "FAIL S2N_hash area '$S2N_A2' not in 23.5..24.5"; fail=1; fi
s2n_check "NetworkSrf: exact Coons patch through 4 curves" "S2N_loop control: a closed 4-curve boundary loop still takes the exact Coons path"
s2n_count "NetworkSrf: curve network of" 2 "S2N_: only the two crossing networks used the network routine (the miss and the loop did not)"


# H3R_: construction history, part 3 - Sweep1/Sweep2 with SEVERAL cross-sections, the non-planar fitted Patch and
# FilletSrf/ChamferSrf (Trim=No) now record {sources, options} and rebuild when a source is edited (automatic
# propagation, no UpdateHistory), including a source edited through its CONTROL POINTS (HBar + HBarDragSelfTest: the
# TransformSubObjects call sequence a gizmo/control-point drag makes). Every rebuild is compared with the SAME
# construction built fresh (History Off) from the same, already moved, sources; every refusal keeps the old result.
# Scripts: h3r_{sweep1,sweep2,patch,fillet}_script.txt (their headers list the numbered measurements).
# ---------------------------------------------------------------------------
H3R_DIR="$TMPW/h3r"
mkdir -p "$H3R_DIR"
h3r_run() {  # h3r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H3R_DIR|g" "$HERE/h3r_$1_script.txt" > "$H3R_DIR/h3r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H3R_DIR/h3r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H3R_DIR/h3r_$1_script.txt" 2>&1
  fi
}
h3r_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
h3r_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
h3r_ar() { { grep -oE 'Area = [0-9.e+-]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Area = //'; }
h3r_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
h3r_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
# bounding box n of output $1 equals the expected "x0,y0,z0,x1,y1,z1" within $4 (a tolerance range: the Windows CI tessellates slightly differently)
h3r_sb() { h3r_ok "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(h3r_bb "$1" "$2"), expected $3 +/- $4)"; }
# bounding box n equals bounding box m of the same output (a rebuilt result against the same construction built fresh)
h3r_eq() { h3r_ok "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$(h3r_bb "$1" "$3")" "$4")" "$5 (#$2 $(h3r_bb "$1" "$2") vs #$3 $(h3r_bb "$1" "$3"))"; }
# bounding box n differs from bounding box m by more than $4 in at least one coordinate (the edit really changed the result)
h3r_ne() { h3r_ok "$([ "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$(h3r_bb "$1" "$3")" "$4")" = 1 ] && echo 0 || echo 1)" "$5 (#$2 $(h3r_bb "$1" "$2") vs #$3 $(h3r_bb "$1" "$3"))"; }
h3r_sa() { h3r_ok "$(h3r_closev "$(h3r_ar "$1" "$2")" "$3" "$4")" "$5 (measured $(h3r_ar "$1" "$2"), expected $3 +/- $4)"; }
h3r_eqa() { h3r_ok "$(h3r_closev "$(h3r_ar "$1" "$2")" "$(h3r_ar "$1" "$3")" "$4")" "$5 (area #$2 $(h3r_ar "$1" "$2") vs #$3 $(h3r_ar "$1" "$3"))"; }
h3r_nea() { h3r_ok "$([ "$(h3r_closev "$(h3r_ar "$1" "$2")" "$(h3r_ar "$1" "$3")" "$4")" = 1 ] && echo 0 || echo 1)" "$5 (area #$2 $(h3r_ar "$1" "$2") vs #$3 $(h3r_ar "$1" "$3"))"; }
h3r_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
h3r_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- Sweep1 with two cross-sections (h3r_sweep1_script.txt)
# Bounding boxes: 1 fresh wall 2 section 2 moved +1 Y 3 section 1 moved -1 Y 4 moved again then Undo (= 3) 5 moved again 6 rail control points moved
#   7 fresh sweep from the same moved sources (= 6) 8 reopened, section 1 moved +1 X 9 fresh (= 8) 10 refused (= 8) 11 History Off control (= 1)
# Areas: 1 fresh 2 section 2 moved 3 section 1 moved twice 4 control points moved 5 fresh (= 4) 6 reopened 7 fresh (= 6) 8 refused (= 6) 9 History Off control (= 1)
H3R_S1="$(h3r_run sweep1)" || { echo "$H3R_S1"; echo "FAIL: h3r sweep1 script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_S1" || { echo "$H3R_S1"; echo "FAIL: h3r sweep1 script produced no smoke line"; fail=1; }
h3r_has "$H3R_S1" "Sweep1: exact kernel multi-section sweep (2 sections, 32 rail stations)" "H3R_sweep1: the two-section sweep is the exact kernel one"
h3r_count "$H3R_S1" "object 4: Sweep1 <- 1,2,3" 3 "H3R_sweep1: the record lists the rail and BOTH sections (live, and read back from the .3dm after New + Open)"
h3r_sb "$H3R_S1" 1 "-1.75,-1.48,0,1.5,1.48,10" 0.15 "H3R_sweep1: curved rail, circles r=1 (z=0) and r=1.5 (z=10)"
h3r_has "$H3R_S1" "History: source object(s) 3 changed - 1 dependent(s) re-evaluated (4)" "H3R_sweep1: moving section 2 rebuilds the wall automatically (no UpdateHistory)"
h3r_sb "$H3R_S1" 2 "-1.75,-0.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 2 moved +1 Y: the wall's Y range grew to follow it"
h3r_ne "$H3R_S1" 2 1 0.3 "H3R_sweep1 control: the wall really changed (not the old bounding box)"
h3r_sb "$H3R_S1" 3 "-1.75,-1.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 1 moved -1 Y: the wall followed"
h3r_eq "$H3R_S1" 4 3 0.02 "H3R_sweep1: Undo takes the section move and the rebuilt wall back together (same undo step)"
h3r_sb "$H3R_S1" 5 "-1.75,-2.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 1 moved -1 Y again: the wall followed"
h3r_has "$H3R_S1" "HBarDragSelfTest: moved anchor control point 1 by 1.5,0,0" "H3R_sweep1: the rail's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_S1" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (4)" "H3R_sweep1: editing the rail's CONTROL POINTS rebuilt the wall with no UpdateHistory"
h3r_ne "$H3R_S1" 6 5 0.3 "H3R_sweep1 control: the control-point edit really changed the wall"
h3r_eq "$H3R_S1" 7 6 0.02 "H3R_sweep1: the wall rebuilt after the control-point edit equals the same sweep built fresh from the edited rail and sections"
h3r_eqa "$H3R_S1" 5 4 0.8 "H3R_sweep1: ...and has the same area"
h3r_sa "$H3R_S1" 1 75.1 1.5 "H3R_sweep1: wall area"
h3r_nea "$H3R_S1" 4 3 0.3 "H3R_sweep1 control: the control-point edit changed the area"
h3r_eq "$H3R_S1" 9 8 0.02 "H3R_sweep1: after Save/New/Open the record is back and moving a section rebuilds the wall (equals a fresh sweep)"
h3r_eqa "$H3R_S1" 7 6 0.8 "H3R_sweep1: ...with the same area"
h3r_ne "$H3R_S1" 8 7 0.1 "H3R_sweep1 control: the reopened wall changed when its section moved"
h3r_has "$H3R_S1" "kept as they were: object 4 - dino8::kernel::Brep::Sweep1Sections: the rail never crosses the plane of section 2" "H3R_sweep1 refuse: a section the rail no longer crosses is reported with the kernel's reason and the wall kept"
h3r_eq "$H3R_S1" 10 8 0.02 "H3R_sweep1 refuse: the old wall keeps its shape"
h3r_eq "$H3R_S1" 11 1 0.02 "H3R_sweep1 History Off control: moving a section leaves a wall built with History Off alone"
h3r_has "$H3R_S1" "History recording: off. 0 object(s) with live construction history" "H3R_sweep1 History Off control: nothing was recorded"

# --- Sweep2 with two cross-sections (h3r_sweep2_script.txt)
# Bounding boxes: 1 fresh wall 2 section 2 moved +1 Y 3 section 1 moved -1 Y 4 moved again then Undo (= 3) 5 rail 2 control points moved 6 fresh (= 5)
#   7 reopened, section 2 moved +1 Y 8 fresh (= 7) 9 refused: two sections at one station (= 7) 10 History Off control (= 1)
# Areas: 1 fresh 2 section 2 moved 3 control points moved 4 fresh (= 3) 5 reopened 6 fresh (= 5) 7 refused (= 5) 8 History Off control (= 1)
H3R_S2="$(h3r_run sweep2)" || { echo "$H3R_S2"; echo "FAIL: h3r sweep2 script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_S2" || { echo "$H3R_S2"; echo "FAIL: h3r sweep2 script produced no smoke line"; fail=1; }
h3r_has "$H3R_S2" "Sweep2: exact kernel multi-section sweep (2 sections, 32 rail stations)" "H3R_sweep2: the two-section sweep is the exact kernel one"
h3r_count "$H3R_S2" "object 5: Sweep2 <- 1,2,3,4" 3 "H3R_sweep2: the record lists both rails and BOTH sections (live, and read back from the .3dm after New + Open)"
h3r_sb "$H3R_S2" 1 "0,0,0,5.53,2,10" 0.15 "H3R_sweep2: straight rail and curved rail, arcs at z=0 and z=10"
h3r_has "$H3R_S2" "History: source object(s) 4 changed - 1 dependent(s) re-evaluated (5)" "H3R_sweep2: moving section 2 rebuilds the wall automatically (no UpdateHistory)"
h3r_sb "$H3R_S2" 2 "0,0,0,5.53,3,10" 0.15 "H3R_sweep2: section 2 moved +1 Y: the wall's Y range grew"
h3r_sb "$H3R_S2" 3 "0,-1,0,5.53,3,10" 0.15 "H3R_sweep2: section 1 moved -1 Y: the wall followed"
h3r_eq "$H3R_S2" 4 3 0.02 "H3R_sweep2: Undo takes the section move and the rebuilt wall back together (same undo step)"
h3r_has "$H3R_S2" "HBarDragSelfTest: moved anchor control point 1 by 1,0,0" "H3R_sweep2: rail 2's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_S2" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (5)" "H3R_sweep2: editing rail 2's CONTROL POINTS rebuilt the wall with no UpdateHistory"
h3r_ne "$H3R_S2" 5 4 0.3 "H3R_sweep2 control: the control-point edit really changed the wall"
h3r_eq "$H3R_S2" 6 5 0.02 "H3R_sweep2: the wall rebuilt after the control-point edit equals the same sweep built fresh from the edited rails and sections"
h3r_eqa "$H3R_S2" 4 3 0.8 "H3R_sweep2: ...and has the same area"
h3r_sa "$H3R_S2" 1 60.7 1.5 "H3R_sweep2: wall area"
h3r_eq "$H3R_S2" 8 7 0.02 "H3R_sweep2: after Save/New/Open the record is back and moving a section rebuilds the wall (equals a fresh sweep)"
h3r_eqa "$H3R_S2" 6 5 0.8 "H3R_sweep2: ...with the same area"
h3r_has "$H3R_S2" "kept as they were: object 5 - dino8::kernel::Brep::Sweep2Sections: two sections sit at the same station of the rails" "H3R_sweep2 refuse: two sections at one station are reported with the kernel's reason and the wall kept"
h3r_eq "$H3R_S2" 9 7 0.02 "H3R_sweep2 refuse: the old wall keeps its shape"
h3r_eq "$H3R_S2" 10 1 0.02 "H3R_sweep2 History Off control: moving a section leaves a wall built with History Off alone"
h3r_has "$H3R_S2" "History recording: off. 0 object(s) with live construction history" "H3R_sweep2 History Off control: nothing was recorded"

# --- Non-planar Patch (h3r_patch_script.txt)
# Bounding boxes: 1 patch through 9 points 2 centre point moved +2 Z 3 fresh (= 2) 4 all points flattened: refused (= 2) 5 a point deleted: refused (= 2)
#   6 saddle curve, trimmed face 7 two control points of the curve moved 8 fresh patch from the moved curve (= 7)
# Areas: 1 patch 2 moved (= 3 fresh) 4 saddle 5 moved (= 6 fresh)
H3R_P="$(h3r_run patch)" || { echo "$H3R_P"; echo "FAIL: h3r patch script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_P" || { echo "$H3R_P"; echo "FAIL: h3r patch script produced no smoke line"; fail=1; }
h3r_has "$H3R_P" "object 10: Patch <- 1,2,3,4,5,6,7,8,9" "H3R_patch: the fitted patch records all nine points it was fitted to"
h3r_has "$H3R_P" "object 2: Patch <- 1" "H3R_patch: the trimmed saddle patch records its curve"
h3r_sb "$H3R_P" 1 "-2,-2,-1,2,2,1" 0.1 "H3R_patch: patch through nine points"
h3r_sa "$H3R_P" 1 17.27 0.3 "H3R_patch: its area (closed form 17.27)"
h3r_has "$H3R_P" "History: source object(s) 5 changed - 1 dependent(s) re-evaluated (10)" "H3R_patch: moving a point re-runs the fit automatically (no UpdateHistory)"
h3r_sb "$H3R_P" 2 "-2,-2,-1,2,2,1.94" 0.15 "H3R_patch: centre point moved +2 Z: the patch followed (3x3 net now)"
h3r_ne "$H3R_P" 2 1 0.3 "H3R_patch control: the patch really changed"
h3r_eq "$H3R_P" 3 2 0.02 "H3R_patch: equals the patch fitted fresh through the moved points"
h3r_eqa "$H3R_P" 2 3 0.3 "H3R_patch: ...with the same area"
h3r_has "$H3R_P" "the sources are now flat (within 0.001 of their best-fit plane), so the fitted patch no longer applies" "H3R_patch refuse: flattened data are reported and the patch kept"
h3r_eq "$H3R_P" 4 2 0.02 "H3R_patch refuse: the patch keeps its shape"
h3r_has "$H3R_P" "object 10 - source object 9 no longer exists" "H3R_patch refuse: a deleted point is reported and the patch kept"
h3r_eq "$H3R_P" 5 2 0.02 "H3R_patch refuse: the patch keeps its shape"
h3r_sa "$H3R_P" 4 84.9 1.5 "H3R_patch: saddle trimmed face area (the flat disc is 78.5)"
h3r_has "$H3R_P" "HBarDragSelfTest: moved anchor control point 3 by 0,0,0.4" "H3R_patch: the saddle curve's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_P" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (2)" "H3R_patch: editing the curve's CONTROL POINTS re-fitted and re-trimmed the face with no UpdateHistory"
h3r_ne "$H3R_P" 7 6 0.3 "H3R_patch control: the control-point edit really changed the face"
h3r_eq "$H3R_P" 8 7 0.02 "H3R_patch: the rebuilt face equals the patch fitted fresh through the edited curve"
h3r_eqa "$H3R_P" 5 6 0.5 "H3R_patch: ...with the same area"

# --- FilletSrf / ChamferSrf, Trim=No (h3r_fillet_script.txt)
# Bounding boxes: 1 fillet r1 2 wall moved +3 X 3 fresh (= 2) 4 EditHistory radius=2 5 fresh r2 (= 4) 6 reopened, wall +2 X 7 fresh (= 6) 8 refused (= 6)
#   9 ChamferSrf 10 wall moved +2 X 11 fresh chamfer (= 10)
# Areas: 1 fillet 2 moved 3 fresh 4 r2 5 fresh r2 6 reopened 7 fresh 8 chamfer 9 moved 10 fresh chamfer  (quarter circle r: pi/2 r x 10; chamfer: sqrt(2) r x 10)
H3R_F="$(h3r_run fillet)" || { echo "$H3R_F"; echo "FAIL: h3r fillet script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_F" || { echo "$H3R_F"; echo "FAIL: h3r fillet script produced no smoke line"; fail=1; }
h3r_has "$H3R_F" "object 3: FilletSrf <- 1,2  [radius=1, endradius=1]" "H3R_fillet: the fillet records both surfaces and its radii (neither is consumed)"
h3r_sb "$H3R_F" 1 "0,0,0,1,10,1" 0.05 "H3R_fillet: radius-1 fillet between a floor and a wall"
h3r_sa "$H3R_F" 1 15.71 0.1 "H3R_fillet: its area (quarter circle pi/2 x 10 = 15.71)"
h3r_has "$H3R_F" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (3)" "H3R_fillet: moving the wall rebuilds the fillet automatically (no UpdateHistory)"
h3r_sb "$H3R_F" 2 "3,0,0,4,10,1" 0.05 "H3R_fillet: wall moved +3 X: the fillet followed"
h3r_eq "$H3R_F" 3 2 0.02 "H3R_fillet: equals the fillet built fresh between the moved surfaces"
h3r_has "$H3R_F" "EditHistory: object 3 (FilletSrf): radius 1 -> 2." "H3R_fillet: EditHistory changes the radius"
h3r_sb "$H3R_F" 4 "3,0,0,5,10,2" 0.05 "H3R_fillet: radius-2 rebuild"
h3r_sa "$H3R_F" 4 31.42 0.2 "H3R_fillet: its area (pi x 10 = 31.42)"
h3r_eq "$H3R_F" 5 4 0.02 "H3R_fillet: equals the radius-2 fillet built fresh"
h3r_has "$H3R_F" "object 3: FilletSrf <- 1,2  [radius=2, endradius=2]" "H3R_fillet: record (with the edited radius) read back from the .3dm after New + Open"
h3r_sb "$H3R_F" 6 "5,0,0,7,10,2" 0.05 "H3R_fillet: reopened, wall moved +2 X more: the fillet followed"
h3r_eq "$H3R_F" 7 6 0.02 "H3R_fillet: equals the fillet built fresh"
h3r_has "$H3R_F" "kept as they were: object 3 - source object 1 no longer exists" "H3R_fillet refuse: a deleted source is reported and the fillet kept"
h3r_eq "$H3R_F" 8 6 0.02 "H3R_fillet refuse: the old fillet keeps its shape"
h3r_has "$H3R_F" "ChamferSrf: built between object 1 and 2, radius 1" "H3R_chamfer: ChamferSrf Trim=No builds the ruled chamfer"
h3r_sa "$H3R_F" 8 14.14 0.1 "H3R_chamfer: its area (sqrt(2) x 10 = 14.14)"
h3r_sb "$H3R_F" 10 "2,0,0,3,10,1" 0.05 "H3R_chamfer: wall moved +2 X: the chamfer followed"
h3r_eq "$H3R_F" 11 10 0.02 "H3R_chamfer: equals the chamfer built fresh between the moved surfaces"
h3r_has "$H3R_F" "FilletSrf: no history recorded - Trim=Yes cuts the two source surfaces" "H3R_fillet negative control: Trim=Yes is not recorded, and says why"
h3r_has "$H3R_F" "History recording: on. 0 object(s) with live construction history" "H3R_fillet negative control: Trim=Yes added no record (the History after it lists none)"


H4R_DIR="$TMPW/h4r"
mkdir -p "$H4R_DIR"
h4r_run() {  # h4r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H4R_DIR|g" "$HERE/h4r_$1_script.txt" > "$H4R_DIR/h4r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H4R_DIR/h4r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H4R_DIR/h4r_$1_script.txt" 2>&1
  fi
}
h4r_len() { { grep -oE 'Total length = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Total length = //'; }
h4r_sl() { h2r_ok "$(h2r_closev "$(h4r_len "$1" "$2")" "$3" "$4")" "$5 (measured $(h4r_len "$1" "$2"), expected $3 +/- $4)"; }
# two measurements of the same kind agree: h4r_eqbb OUT i j tol label / h4r_eqlen OUT i j tol label / h4r_eqvol OUT i j tol label
h4r_eqbb() { h2r_ok "$(h2r_closebb "$(h2r_bb "$1" "$2")" "$(h2r_bb "$1" "$3")" "$4")" "$5 (rebuilt $(h2r_bb "$1" "$2") vs fresh $(h2r_bb "$1" "$3"))"; }
h4r_eqlen() { h2r_ok "$(h2r_closev "$(h4r_len "$1" "$2")" "$(h4r_len "$1" "$3")" "$4")" "$5 (rebuilt $(h4r_len "$1" "$2") vs fresh $(h4r_len "$1" "$3"))"; }
h4r_eqvol() { h2r_ok "$(h2r_closev "$(h2r_vol "$1" "$2")" "$(h2r_vol "$1" "$3")" "$4")" "$5 (rebuilt $(h2r_vol "$1" "$2") vs fresh $(h2r_vol "$1" "$3"))"; }
# bounding box i equals bounding box j shifted by (0,2,0)
h4r_shift2() {
  local a b; a="$(h2r_bb "$1" "$2")"; b="$(h2r_bb "$1" "$3")"
  h2r_ok "$(awk -v a="$a" -v b="$b" -v t="$4" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){ e=x[i]+((i==2||i==5)?2:0)-y[i]; if(e<0)e=-e; if(e>t){print 0; exit} } print 1 }')" "$5 (saved $a, after the sources moved +2 Y $b)"
}

# --- part 1: ExtrudeSrf* family, Contour, Section, OffsetMultiple
H4R_E="$(h4r_run ext)" || { echo "$H4R_E"; echo "FAIL: h4r ext script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_E" || { echo "$H4R_E"; echo "FAIL: h4r ext script produced no smoke line"; fail=1; }
h2r_has "$H4R_E" "object 9: ExtrudeSrfAlongCrv <- 1,2" "H4R_ext: ExtrudeSrfAlongCrv records the surface and the path curve"
h2r_has "$H4R_E" "object 10: ExtrudeSrfTapered <- 3  [distance=5, draft=5]" "H4R_ext: ExtrudeSrfTapered records the surface, the distance and the draft"
h2r_has "$H4R_E" "object 11: ExtrudeSrfToPoint <- 4  [apexx=45, apexy=5, apexz=10]" "H4R_ext: ExtrudeSrfToPoint records the surface and the apex"
h2r_has "$H4R_E" "object 12: Contour <- 5" "H4R_ext: every Contour piece records the contoured object"
h2r_has "$H4R_E" "object 15: Contour <- 5" "H4R_ext: ...all four pieces"
h2r_has "$H4R_E" "object 16: Section <- 6" "H4R_ext: Section records the sectioned object"
h2r_has "$H4R_E" "object 17: OffsetMultiple <- 7  [distance=2]" "H4R_ext: OffsetMultiple records the curve and the distance (one record per offset)"
h2r_count "$H4R_E" "14 object(s) with live construction history" 2 "H4R_ext: 14 recorded results before the edits and again after Open; the History Off controls added none"
# initial results
h2r_sb "$H4R_E" 1 "0,0,0,10,10,5" 0.05 "H4R_ext: ExtrudeSrfAlongCrv of a 10x10 plane along a 5 line (before)"
h2r_sh "$H4R_E" 1 500 1 "H4R_ext: ...volume 10*10*5 (before)"
h2r_sb "$H4R_E" 2 "20,0,0,30,10,5" 0.05 "H4R_ext: ExtrudeSrfTapered distance 5 draft 5 (before)"
h2r_sh "$H4R_E" 2 469.7 1.5 "H4R_ext: ...volume of the 5 degree taper (before)"
h2r_sb "$H4R_E" 3 "40,0,0,50,10,10" 0.05 "H4R_ext: ExtrudeSrfToPoint apex 10 above (before)"
h2r_sh "$H4R_E" 3 333.3 1 "H4R_ext: ...pyramid volume 100*10/3 (before)"
h4r_sl "$H4R_E" 1 159.9 1 "H4R_ext: Contour of a 10^3 box, 4 planes: total loop length 4*40 (before)"
h2r_sb "$H4R_E" 4 "60,0,1.25,70,10,8.75" 0.05 "H4R_ext: ...planes at z 1.25 .. 8.75 (before)"
h4r_sl "$H4R_E" 2 40 0.3 "H4R_ext: Section through the box at y=5: one 10x10 loop (before)"
h2r_sb "$H4R_E" 5 "80,5,0,90,5,10" 0.05 "H4R_ext: ...section bounding box (before)"
h4r_sl "$H4R_E" 3 20.88 0.6 "H4R_ext: OffsetMultiple 2 offsets x 2 of a curve (before)"
h2r_sb "$H4R_E" 6 "97.78,1.664,0,108.8,6.2,0" 0.15 "H4R_ext: ...offsets bounding box (before)"
# after the edits
h2r_sb "$H4R_E" 8 "3,0,0,13,10,10" 0.05 "H4R_ext: plane moved +3 X and path scaled 2x: the extrusion followed (x 3..13, height 10)"
h2r_sh "$H4R_E" 4 1000 2 "H4R_ext: ...volume 10*10*10"
h2r_has "$H4R_E" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (9)" "H4R_ext: moving the surface re-evaluates the extrusion automatically"
h2r_has "$H4R_E" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (9)" "H4R_ext: scaling the path re-evaluates it too"
h2r_has "$H4R_E" "EditHistory: object 10 (ExtrudeSrfTapered): distance 5 -> 8." "H4R_ext: EditHistory changes the taper distance"
h2r_has "$H4R_E" "EditHistory: object 10 (ExtrudeSrfTapered): draft 5 -> 10." "H4R_ext: ...and the draft"
h2r_sb "$H4R_E" 9 "20,4,0,30,14,8" 0.05 "H4R_ext: taper after plane moved +4 Y, distance 8, draft 10"
h2r_sh "$H4R_E" 5 651 3 "H4R_ext: ...volume"
h2r_has "$H4R_E" "EditHistory: object 11 (ExtrudeSrfToPoint): apexz 10 -> 20." "H4R_ext: EditHistory moves the apex"
h2r_sb "$H4R_E" 10 "40,2,0,50,12,20" 0.05 "H4R_ext: cone after plane moved +2 Y and apex raised to z 20"
h2r_sh "$H4R_E" 6 666.7 2 "H4R_ext: ...volume 100*20/3"
h2r_has "$H4R_E" "History: source object(s) 5 changed - 4 dependent(s) re-evaluated (12,13,14,15)" "H4R_ext: moving the contoured box re-evaluates all four contour curves"
h2r_sb "$H4R_E" 11 "65,3,1.25,75,13,8.75" 0.05 "H4R_ext: contours followed the box moved (+5,+3,+1) and stayed on their fixed planes"
h4r_sl "$H4R_E" 5 159.9 1 "H4R_ext: ...total length"
h2r_has "$H4R_E" "History: source object(s) 6 changed - 1 dependent(s) re-evaluated (16)" "H4R_ext: scaling the sectioned box re-evaluates the section"
h4r_sl "$H4R_E" 6 79.94 0.6 "H4R_ext: section of the box scaled 2x: one 20x20 loop"
h2r_sb "$H4R_E" 12 "80,5,0,100,5,20" 0.05 "H4R_ext: ...section bounding box"
h2r_has "$H4R_E" "History: source object(s) 7 changed - 2 dependent(s) re-evaluated (17,18)" "H4R_ext: scaling the curve re-evaluates both offsets"
h4r_sl "$H4R_E" 7 42.09 0.7 "H4R_ext: offsets of the curve scaled 2x"
h2r_sb "$H4R_E" 13 "97.78,1.664,0,118.8,9.2,0" 0.2 "H4R_ext: ...offsets bounding box"
h2r_has "$H4R_E" "History: source object(s) 8 changed" "H4R_ext: moving the contoured sphere is noticed"
h4r_sl "$H4R_E" 8 101.9 6 "H4R_ext: the sphere's four contour curves are all still there (pieces whose count changed kept as they were)"
# controls: the same operations fresh on the edited sources
h4r_eqbb "$H4R_E" 8 15 0.05 "H4R_ext control: fresh ExtrudeSrfAlongCrv bounding box"
h4r_eqvol "$H4R_E" 4 7 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 9 16 0.05 "H4R_ext control: fresh ExtrudeSrfTapered (distance 8, draft 10) bounding box"
h4r_eqvol "$H4R_E" 5 8 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 10 17 0.05 "H4R_ext control: fresh ExtrudeSrfToPoint (apex z 20) bounding box"
h4r_eqvol "$H4R_E" 6 9 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 11 18 0.05 "H4R_ext control: fresh Contour of the moved box bounding box"
h4r_eqlen "$H4R_E" 5 9 0.3 "H4R_ext control: ...total length"
h4r_eqbb "$H4R_E" 12 19 0.05 "H4R_ext control: fresh Section of the scaled box bounding box"
h4r_eqlen "$H4R_E" 6 10 0.3 "H4R_ext control: ...length"
h4r_eqbb "$H4R_E" 13 20 0.1 "H4R_ext control: fresh OffsetMultiple of the scaled curve bounding box"
h4r_eqlen "$H4R_E" 7 11 0.3 "H4R_ext control: ...total length"
# negative control: the contour planes no longer meet the box
h2r_has "$H4R_E" "History: source object(s) 5 changed - 0 dependent(s) re-evaluated, 4 kept as they were" "H4R_ext: the box moved +20 Z leaves every contour plane: no rebuild, all four kept"
h2r_has "$H4R_E" "the edited source now meets the plane in 0 piece(s), it gave 1 when this result was made; kept as it was" "H4R_ext: ...with the reason"
h4r_eqbb "$H4R_E" 21 11 0.05 "H4R_ext: the kept contours did not move"
h4r_eqlen "$H4R_E" 12 5 0.01 "H4R_ext: ...nor change length"
h4r_eqbb "$H4R_E" 22 11 0.05 "H4R_ext: the box moved back: the contours are rebuilt again, equal to before"
# Save, New, Open
h2r_has "$H4R_E" "object 10: ExtrudeSrfTapered <- 3  [distance=8, draft=10]" "H4R_ext: after Save/New/Open the taper record (with the EditHistory'd numbers) is read back from the .3dm"
h2r_has "$H4R_E" "object 11: ExtrudeSrfToPoint <- 4  [apexx=45, apexy=5, apexz=20]" "H4R_ext: ...the apex record"
h2r_sb "$H4R_E" 23 "3,5,0,13,15,10" 0.05 "H4R_ext: reopened, plane moved +5 Y: the extrusion followed"
h2r_sh "$H4R_E" 10 1000 2 "H4R_ext: ...volume"
h2r_sb "$H4R_E" 24 "65,4,1.25,75,14,8.75" 0.05 "H4R_ext: reopened, box moved +1 Y: the contours followed"
h4r_sl "$H4R_E" 14 159.9 1 "H4R_ext: ...total length"
h4r_eqbb "$H4R_E" 25 6 0.1 "H4R_ext: reopened, curve scaled back to its first size: the offsets are the first ones again"
h4r_eqlen "$H4R_E" 15 3 0.1 "H4R_ext: ...length"
h4r_eqbb "$H4R_E" 26 5 0.05 "H4R_ext: reopened, box scaled back: the section is the first one again"
h4r_eqlen "$H4R_E" 16 2 0.1 "H4R_ext: ...length"
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_E" && echo 1 || echo 0)" "H4R_ext: ran without OpenGL errors"

# --- part 2: history survives Save / New / Open for 14 construction kinds
H4R_P="$(h4r_run persist)" || { echo "$H4R_P"; echo "FAIL: h4r persist script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_P" || { echo "$H4R_P"; echo "FAIL: h4r persist script produced no smoke line"; fail=1; }
h2r_count "$H4R_P" "17 object(s) with live construction history" 2 "H4R_persist: 17 recorded results before Save and again after New + Open"
for rec in "object 4: Sweep1 <- 1,2,3" "object 14: Patch <- 5,6,7,8,9,10,11,12,13" "object 17: FilletSrf <- 15,16" "object 20: ExtrudeSrf <- 19" "object 22: Pipe <- 21" "object 26: Loft <- 23,24,25" "object 28: Revolve <- 27" "object 35: BooleanUnion <- 33,34" "object 37: Offset <- 36" "object 39: ExtrudeCrvTapered <- 38" "object 42: NetworkSrf2 <- 40,41" "object 44: OffsetSrf <- 43" "object 46: ExtrudeCrvToPoint <- 45"; do
  h2r_count "$H4R_P" "$rec" 2 "H4R_persist: record '$rec' listed before Save and again after Open"
done
h2r_count "$H4R_P" "dependent(s) re-evaluated" 14 "H4R_persist: after Open each of the 14 chains' source edits re-evaluated its dependents"
h2r_countre "$H4R_P" "kept as they were:" 0 "H4R_persist: no rebuild was refused"
H4R_NAMES=(Sweep1 Patch FilletSrf "PlanarSrf+ExtrudeSrf" Pipe Loft Revolve Extrude BooleanUnion Offset ExtrudeCrvTapered NetworkSrf OffsetSrf ExtrudeCrvToPoint)
for k in $(seq 1 14); do
  nm="${H4R_NAMES[$((k - 1))]}"
  if [ "$k" = "7" ]; then
    h4r_eqbb "$H4R_P" 21 29 0.05 "H4R_persist: $nm: after Open the profile moved +2 Y: the revolve about the fixed axis equals a fresh revolve of the moved profile"
    h2r_ok "$(awk -v a="$(h2r_bb "$H4R_P" 7)" -v b="$(h2r_bb "$H4R_P" 21)" 'BEGIN{ n=split(a,x,","); split(b,y,","); for(i=1;i<=n;i++){ d=x[i]-y[i]; if(d<0)d=-d; if(d>0.1){print 1; exit} } print 0 }')" "H4R_persist: $nm: ...and it did change from the saved result (the rebuild ran)"
  else
    h4r_shift2 "$H4R_P" "$k" "$((14 + k))" 0.05 "H4R_persist: $nm: after Open the sources moved +2 Y: the rebuilt result is the saved one shifted (0,2,0)"
  fi
done
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_P" && echo 1 || echo 0)" "H4R_persist: ran without OpenGL errors"

# --- part 3: OffsetCrvOnSrf (h4r_offsrf_script.txt)
H4R_O="$(h4r_run offsrf)" || { echo "$H4R_O"; echo "FAIL: h4r offsrf script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_O" || { echo "$H4R_O"; echo "FAIL: h4r offsrf script produced no smoke line"; fail=1; }
h2r_has "$H4R_O" "object 3: OffsetCrvOnSrf <- 2,1  [distance=3]" "H4R_offsrf: OffsetCrvOnSrf records the curve, the surface and the distance"
h2r_sb "$H4R_O" 1 "2,8,0,18,8,0" 0.05 "H4R_offsrf: the 16-long line at y=5 offset by 3 along the surface (before)"
h4r_sl "$H4R_O" 1 16 0.1 "H4R_offsrf: ...length (before)"
h2r_has "$H4R_O" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (3)" "H4R_offsrf: moving the curve re-evaluates the offset automatically"
h2r_sb "$H4R_O" 2 "2,12,0,18,12,0" 0.05 "H4R_offsrf: curve moved +4 Y: the offset followed (y=9+3)"
h2r_has "$H4R_O" "EditHistory: object 3 (OffsetCrvOnSrf): distance 3 -> -2." "H4R_offsrf: EditHistory changes the distance"
h2r_sb "$H4R_O" 3 "2,7,0,18,7,0" 0.05 "H4R_offsrf: ...the offset is now on the other side (y=9-2)"
h4r_eqbb "$H4R_O" 3 4 0.05 "H4R_offsrf control: the same offset performed fresh (History Off) on the moved curve has the same bounding box"
h4r_eqlen "$H4R_O" 3 4 0.05 "H4R_offsrf control: ...and the same length"
h2r_has "$H4R_O" "object 3: OffsetCrvOnSrf <- 2,1  [distance=-2]" "H4R_offsrf: after Save/New/Open the record (with the EditHistory'd distance) is read back from the .3dm"
h2r_sb "$H4R_O" 5 "2,9,0,18,9,0" 0.05 "H4R_offsrf: reopened, curve moved +2 Y more: the offset followed (y=11-2)"
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_O" && echo 1 || echo 0)" "H4R_offsrf: ran without OpenGL errors"

exit $fail
