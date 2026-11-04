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
b2s_check chain2 "exact B-rep boolean (no tessellation, general engine), 7 face(s), sealed: valid B-rep with real inner loops" "first hole is exact and closed"
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
b2s_check box_sphere "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 7 face(s), sealed: valid B-rep with real inner loops" "box + sphere is exact (before: declined, mesh)"
b2s_check box_sphere "7 faces, [0-9]* edges, closed solid" "...7 faces (5 box + box top with the circle removed + hemisphere), closed solid"
b2s_num box_sphere Volume 1130 1136 "box + upper hemisphere: 1000 + 2/3*pi*64 = 1134.04"
b2s_num box_sphere Area 646 655 "area = 600 - pi*16 + 2*pi*16 = 650.27"
b2s_check box_sphere_shell "Shell: thickness 0.5, closed, volume" "a Shell takes the box + sphere result as a closed solid (mesh construction: a curved face has no exact kernel shell)"
b2s_check box_sphere_sphere "re-evaluated from the recorded original operands" "box + sphere, then + a second sphere: exact"
b2s_check box_sphere_sphere "8 faces, [0-9]* edges, closed solid" "...8 faces, closed solid"
b2s_num box_sphere_sphere Volume 1264 1272 "1000 + 2*(2/3*pi*64) = 1268.08"
b2s_check box_two_spheres "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sealed: valid B-rep with real inner loops" "box + two spheres in one Boolean is exact (the left-to-right fold fails; the retry unites the spheres first)"
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
so2check H_shell "Shell: thickness 0.5, closed, exact B-rep, volume" "SO2_H_shell: a box with a Boolean through-hole (sampled keyhole cap loop) now shells exactly (prism-with-hole construction, HSO_; before: 'exact B-rep shell not used (the cap boundary is not one clean closed loop', mesh)"
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

# ---------------------------------------------------------------------------
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

# TS3: ToNURBS of the cone's SubD (tosubd3_script.txt). The radius-4 cone's
# SubD used to be the 64-segment cage (960 faces): ToNURBS reported "closed
# solid: yes, manifold" but Volume then said "Object N is not closed" and
# printed 0, because the mesher could not weld the 64-segment cage's tiny cap
# patches (the apex is NOT the cause: a radius-2 cone, same apex, 32 segments,
# measures fine). The segment ladder now also tries 40 and 48 before 64, and
# the radius-4 cone verifies at 40 (380 faces). The last two blocks show what
# the SubD's own Volume is: the volume of the current CONTROL NET (an
# interpolated cage lies outside its limit surface), which falls onto the
# exact figure as the net is refined with SubDivide. Ranges, not exact
# numbers (deviation and volumes depend on the platform's float evaluation).
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

exit $fail
