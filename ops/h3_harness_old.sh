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
HERE="/home/user/miniature-pancake/.claude/worktrees/agent-a6793fdf3e148e078/dino8-app/tests"
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
# History / RecordHistory / UpdateHistory: a real, intentionally-scoped
# constructional-history mechanism (Extrude/ExtrudeCrv, ExtrudeCrvToPoint,
# Revolve, Loft, SubDLoft - see cmd_history.cpp's own header comment and
# tests/history_script.txt's for exactly what this checks). The key
# assertion is a real bounding-box move, not just an object count: after
# History On, Extrude, moving the source curve and running UpdateHistory,
# the extruded surface's bounding box must have actually shifted to match
# the curve's new position - the exact check a fake/no-op implementation
# would fail.
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
hcheck "History recording: on - new results of 31 construction commands (BlendSrf/Boolean2Objects/BooleanDifference/BooleanIntersection/BooleanUnion/Cap/ChamferEdge/ChamferSrf/Extrude/" "History On toggled recording on and now lists the registry-driven set of recordable constructions (was a hand-written 10-name sentence; the registry now has 31 names - 23 before the H2R_ additions BlendSrf, Cap, ChamferEdge, FilletEdge, Project and Pull, and the H3R_ additions ChamferSrf and FilletSrf - e.g. Shell, ExtrudeSrf, Offset, OffsetSrf, RailRevolve and the four booleans on top of the old Extrude/ExtrudeCrvToPoint/Revolve/Loft/SubDLoft/Pipe/Sweep1/Sweep2/Patch/NetworkSrf2)"
hcheck "Bounding box min 20,0,0 max 30,0,5" "the freshly-extruded surface's bounding box, before the source curve moves"
hcheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one object History was tracking"
hcheck "Bounding box min 20,0,20 max 30,0,25" "UpdateHistory genuinely re-derived the extruded surface's geometry from the source curve's new z=20 position - not the z=0..5 box baked at creation time"
hcheck "History recording: on. 1 object(s) with live construction history:" "the live report lists exactly one tracked object"
hcheck "object 4: Extrude <- 3" "the report names the real dependent/source pair (surface 4 built from curve 3)"

# ExtrudeCrvToPoint Solid=Yes: RebuildExtrudeToPoint (cmd_solids.cpp) now
# wires a closed, planar, non-self-intersecting profile into
# kernel::Brep::ExtrudeToPoint for a genuine capped B-rep cone instead of
# the old centroid-collapsed ruled surface - see
# extrude_to_point_solid_script.txt's own header comment for exactly what
# this checks, including the pre-existing (not newly broken) app-level
# Volume gap on this topology.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  E2P="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/extrude_to_point_solid_script.txt" 2>&1)" || { echo "$E2P"; echo "FAIL: extrude-to-point-solid script exited non-zero"; exit 1; }
else
  E2P="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/extrude_to_point_solid_script.txt" 2>&1)" || { echo "$E2P"; echo "FAIL: extrude-to-point-solid script exited non-zero"; exit 1; }
fi
echo "$E2P" | grep -E "^(ok|FAIL)"
if echo "$E2P" | grep -q "^FAIL"; then fail=1; fi
echo "$E2P" | grep -q "^smoke:" || { echo "$E2P"; echo "FAIL: extrude-to-point-solid script produced no smoke line"; fail=1; }
e2pcheck() { if echo "$E2P" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$E2P" "$1"; fail=1; fi; }
e2pcheck "Object 2 (polysurface) layer Default" "Solid=Yes on a closed planar rectangle builds a real polysurface, not a degenerate surface"
e2pcheck "2 faces, 3 edges, closed solid" "the built cone is a genuine closed solid (IsSolid), not just visually cone-shaped"
e2pcheck "Object 2: valid" "Check reports the new solid cone as valid"
e2pcheck "Object 4 (surface) layer Default" "Solid=No on the identical curve/apex still falls back to the pre-existing ruled surface, unchanged"
e2pcheck "Object 6 (surface) layer Default" "a non-star-shaped (C-shaped) profile falls back to the ruled surface instead of throwing or crashing when ExtrudeToPoint refuses its flat cap"
e2pcheck "Object 8 (surface) layer Default" "an open curve is unaffected - still the pre-existing ruled surface, since this pass only wires the closed-profile capped-cone case"

# RailRevolve: RailRevolveCommand (cmd_srfedit.cpp) now wires a profile
# planar through the picked axis into kernel::Brep::RailRevolve for a
# genuine B-rep instead of the old approximate curve-through-points fit -
# see railrevolve_solid_script.txt's own header comment for exactly what
# this checks.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RRV="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/railrevolve_solid_script.txt" 2>&1)" || { echo "$RRV"; echo "FAIL: railrevolve-solid script exited non-zero"; exit 1; }
else
  RRV="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/railrevolve_solid_script.txt" 2>&1)" || { echo "$RRV"; echo "FAIL: railrevolve-solid script exited non-zero"; exit 1; }
fi
echo "$RRV" | grep -E "^(ok|FAIL)"
if echo "$RRV" | grep -q "^FAIL"; then fail=1; fi
echo "$RRV" | grep -q "^smoke:" || { echo "$RRV"; echo "FAIL: railrevolve-solid script produced no smoke line"; fail=1; }
rrvcheck() { if echo "$RRV" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RRV" "$1"; fail=1; fi; }
rrvcheck_re() { if echo "$RRV" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RRV" "$1"; fail=1; fi; }
rrvcheck "RailRevolve: genuine B-rep solid/shell built (profile planar through the picked axis)" "a profile planar through the picked axis hits the new kernel::Brep::RailRevolve path"
rrvcheck "Object 3 (polysurface) layer Default" "the result is a real polysurface, not a degenerate approximate surface"
rrvcheck "1 faces, 2 edges, closed solid" "a closed off-axis profile with a constant-radius rail builds a genuine closed solid (doubly-periodic single face, torus topology)"
rrvcheck "Object 3: valid" "Check reports the new solid as valid"
rrvcheck_re "Volume = 224\.[67] cubic Millimeters" "Volume measures the new solid directly - no apex/seam mesh-closure gap on this topology, unlike ExtrudeCrvToPoint's own cone"
rrvcheck "RailRevolve: surface created (profile scaled radially to follow the rail)" "an axis outside the profile's own plane falls back to the pre-existing approximate surface, unchanged"
rrvcheck "Object 6 (surface) layer Default" "the fallback result is still the pre-existing approximate surface kind, not a Brep"

# Revolve Angle/StartAngle: RevolveCommand (cmd_solids.cpp) now exposes
# both options (previously unavailable anywhere in the app) and routes a
# genuinely non-default combination through kernel::Brep::Revolve - see
# revolve_angle_script.txt's own header comment for exactly what this
# checks, including the pre-existing partial-angle-cap Volume gap it
# shares with ExtrudeCrvToPoint's own cone.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RAS="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/revolve_angle_script.txt" 2>&1)" || { echo "$RAS"; echo "FAIL: revolve-angle script exited non-zero"; exit 1; }
else
  RAS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/revolve_angle_script.txt" 2>&1)" || { echo "$RAS"; echo "FAIL: revolve-angle script exited non-zero"; exit 1; }
fi
echo "$RAS" | grep -E "^(ok|FAIL)"
if echo "$RAS" | grep -q "^FAIL"; then fail=1; fi
echo "$RAS" | grep -q "^smoke:" || { echo "$RAS"; echo "FAIL: revolve-angle script produced no smoke line"; fail=1; }
rascheck() { if echo "$RAS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RAS" "$1"; fail=1; fi; }
rascheck_re() { if echo "$RAS" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RAS" "$1"; fail=1; fi; }
rascheck "3 faces, 5 edges, closed solid" "Angle=90 on a closed off-axis profile builds a real capped solid via kernel::Brep::Revolve (wall + 2 pie-slice caps)"
rascheck "Object 4: valid" "Check reports the partial-angle solid as valid"
rascheck_re "Volume = 149\.[12] cubic Millimeters" "StartAngle=45 at full angle (torus topology, no cap-adjacent mesh gap) measures correctly"

# History extended to a sixth command, Pipe (PipeCommand, cmd_surface.cpp;
# RebuildPipe, history_rebuild.h) - see history_pipe_script.txt's own
# header comment for exactly what this checks. Same real-bounding-box-move
# money check as the Extrude case above, not just an object count.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HSP="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_pipe_script.txt" 2>&1)" || { echo "$HSP"; echo "FAIL: history-pipe script exited non-zero"; exit 1; }
else
  HSP="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_pipe_script.txt" 2>&1)" || { echo "$HSP"; echo "FAIL: history-pipe script exited non-zero"; exit 1; }
fi
echo "$HSP" | grep -E "^(ok|FAIL)"
if echo "$HSP" | grep -q "^FAIL"; then fail=1; fi
echo "$HSP" | grep -q "^smoke:" || { echo "$HSP"; echo "FAIL: history-pipe script produced no smoke line"; fail=1; }
hspcheck() { if echo "$HSP" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HSP" "$1"; fail=1; fi; }
hspcheck "object 2: Pipe <- 1" "History tracks a Pipe result (object 2) built from its rail curve (object 1)"
hspcheck "Bounding box min 0,-1,-1 max 10,1,1" "the freshly-built pipe's bounding box, before the rail curve moves"
hspcheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Pipe History was tracking"
hspcheck "Bounding box min 0,-1,4 max 10,1,6" "UpdateHistory genuinely re-derived the pipe's geometry from the rail curve's new z=5 position - not the z=-1..1 mesh baked at creation time"

# History extended to a seventh command, Sweep1's single-cross-section case
# (Sweep1Command, cmd_surface.cpp; RebuildSweep1, history_rebuild.h) - see
# history_sweep1_script.txt's own header comment for exactly what this
# checks. Same real-bounding-box-move money check as Extrude/Pipe above.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HSS="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_sweep1_script.txt" 2>&1)" || { echo "$HSS"; echo "FAIL: history-sweep1 script exited non-zero"; exit 1; }
else
  HSS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_sweep1_script.txt" 2>&1)" || { echo "$HSS"; echo "FAIL: history-sweep1 script exited non-zero"; exit 1; }
fi
echo "$HSS" | grep -E "^(ok|FAIL)"
if echo "$HSS" | grep -q "^FAIL"; then fail=1; fi
echo "$HSS" | grep -q "^smoke:" || { echo "$HSS"; echo "FAIL: history-sweep1 script produced no smoke line"; fail=1; }
hsscheck() { if echo "$HSS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HSS" "$1"; fail=1; fi; }
hsscheck "object 3: Sweep1 <- 1,2" "History tracks a Sweep1 result (object 3) built from its rail (object 1) and section (object 2)"
hsscheck "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" "the freshly-built sweep's bounding box, before the section curve moves"
hsscheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Sweep1 History was tracking"
hsscount() { local n; n="$(echo "$HSS" | grep -cF "$1" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HSS" "$1"; fail=1; fi; }
hsscount "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" 2 "after the section slid +5 in Z (to half way along the rail) UpdateHistory's rebuilt sweep still covers the rail's own z=0..10 extent - the old rigid-from-rail-start result was z=5..15, overshooting the rail's end by 5 (this line and the freshly-built one above)"
hsscheck "Sweep1: the section sits 50.0% along the rail; the rail was split there and both sides swept from the section and joined; the result reproduces the section to " "the rebuild reports where it found the section (50.0% along the rail) and that the joined two-sided sweep reproduces it"
hsscheck "Bounding box min 2.093,-0.978,0 max 4,0.978,10" "UpdateHistory genuinely re-derived the swept surface's geometry from the section curve's new +3 x offset (x: -0.9073..1 became 2.093..4, z still the rail's 0..10) - not the surface baked at creation time"

# History extended to an eighth command, Sweep2's single-cross-section case
# (Sweep2Command, cmd_surface.cpp; RebuildSweep2, history_rebuild.h) - see
# history_sweep2_script.txt's own header comment for exactly what this
# checks. Same real-bounding-box-move money check as Sweep1 above.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HS2="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_sweep2_script.txt" 2>&1)" || { echo "$HS2"; echo "FAIL: history-sweep2 script exited non-zero"; exit 1; }
else
  HS2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_sweep2_script.txt" 2>&1)" || { echo "$HS2"; echo "FAIL: history-sweep2 script exited non-zero"; exit 1; }
fi
echo "$HS2" | grep -E "^(ok|FAIL)"
if echo "$HS2" | grep -q "^FAIL"; then fail=1; fi
echo "$HS2" | grep -q "^smoke:" || { echo "$HS2"; echo "FAIL: history-sweep2 script produced no smoke line"; fail=1; }
hs2check() { if echo "$HS2" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HS2" "$1"; fail=1; fi; }
hs2check "object 4: Sweep2 <- 1,2,3" "History tracks a Sweep2 result (object 4) built from its two rails (objects 1,2) and section (object 3)"
hs2check "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" "the freshly-built sweep's bounding box, before the section curve moves"
hs2check "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Sweep2 History was tracking"
hs2count() { local n; n="$(echo "$HS2" | grep -cF "$1" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HS2" "$1"; fail=1; fi; }
hs2count "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" 2 "after the section slid +5 in Z (to half way along both rails) UpdateHistory's rebuilt sweep still covers the rails' own z=0..10 extent - the old rigid-from-rail-start result was z=5..15 (this line and the freshly-built one above)"
hs2check "Sweep2: the section sits 50.0% along rail 1 and 50.0% along rail 2; both rails were split there and both sides swept from the section and joined; the result reproduces the section to " "the rebuild reports where it found the section (50.0% along both rails) and that the joined two-sided sweep reproduces it"
hs2check "Bounding box min 2.093,-0.978,0 max 4,0.978,10" "UpdateHistory genuinely re-derived the swept surface's geometry from the section curve's new +3 x offset (x: -0.9073..1 became 2.093..4, z still the rails' 0..10) - not the surface baked at creation time"

# History extended to a ninth command, Patch's single-closed-planar-curve
# case (the free Patch function, cmd_surface.cpp; RebuildPatch,
# history_rebuild.h) - see history_patch_script.txt's own header comment
# for exactly what this checks. Same real-bounding-box-move money check as
# Pipe/Sweep1/Sweep2 above; the result is a flat Brep, so (like
# history_script.txt's own flat Extrude case) BoundingBox never adds an
# extra box object for it.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HPA="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_patch_script.txt" 2>&1)" || { echo "$HPA"; echo "FAIL: history-patch script exited non-zero"; exit 1; }
else
  HPA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_patch_script.txt" 2>&1)" || { echo "$HPA"; echo "FAIL: history-patch script exited non-zero"; exit 1; }
fi
echo "$HPA" | grep -E "^(ok|FAIL)"
if echo "$HPA" | grep -q "^FAIL"; then fail=1; fi
echo "$HPA" | grep -q "^smoke:" || { echo "$HPA"; echo "FAIL: history-patch script produced no smoke line"; fail=1; }
hpacheck() { if echo "$HPA" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HPA" "$1"; fail=1; fi; }
hpacheck "object 2: Patch <- 1" "History tracks a Patch result (object 2) built from its closed curve (object 1)"
hpacheck "Bounding box min -5,-5,0 max 5,5,0" "the freshly-patched circle's exact bounding box, before the source curve moves"
hpacheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Patch History was tracking"
hpacheck "Bounding box min -5,-5,5 max 5,5,5" "UpdateHistory genuinely re-derived the patched face's geometry from the source circle's new z=5 position - not the z=0 flat face baked at creation time"

# History extended to a tenth command, NetworkSrf's 2-curve ruled-surface
# case (the free NetworkSrf function, cmd_surface.cpp; RebuildNetworkSrf2,
# history_rebuild.h) - see history_networksrf_script.txt's own header
# comment for exactly what this checks. Same real-bounding-box-move money
# check as Pipe/Sweep1/Sweep2/Patch above (a flat ruled surface between
# two ground-plane lines, max z 0 -> 5 once the first line moves).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HNS="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_networksrf_script.txt" 2>&1)" || { echo "$HNS"; echo "FAIL: history-networksrf script exited non-zero"; exit 1; }
else
  HNS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_networksrf_script.txt" 2>&1)" || { echo "$HNS"; echo "FAIL: history-networksrf script exited non-zero"; exit 1; }
fi
echo "$HNS" | grep -E "^(ok|FAIL)"
if echo "$HNS" | grep -q "^FAIL"; then fail=1; fi
echo "$HNS" | grep -q "^smoke:" || { echo "$HNS"; echo "FAIL: history-networksrf script produced no smoke line"; fail=1; }
hnscheck() { if echo "$HNS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HNS" "$1"; fail=1; fi; }
hnscheck "object 3: NetworkSrf2 <- 1,2" "History tracks a NetworkSrf2 result (object 3) built from its two source lines (objects 1,2)"
hnscheck "Bounding box min 0,0,0 max 10,10,0" "the freshly-ruled surface's exact bounding box, before either source line moves"
hnscheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one NetworkSrf2 History was tracking"

# Registry-based construction history (cmd_history.cpp / history_rebuild.h):
# one dispatch table re-executes every recorded construction through
# UpdateHistory in dependency order - Extrude/ExtrudeSrf/ExtrudeCrvTapered/
# ExtrudeCrvAlongCrv/PlanarSrf/NetworkSrf (3-4 curves)/EdgeSrf/Offset/OffsetSrf/
# RailRevolve and the four booleans, on top of the older ones. See
# tests/history_registry_script.txt: every UpdateHistory is followed by a
# MEASURED Volume/Area/Length, never just an object count.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HRG="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_registry_script.txt" 2>&1)" || { echo "$HRG"; echo "FAIL: history-registry script exited non-zero"; exit 1; }
else
  HRG="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_registry_script.txt" 2>&1)" || { echo "$HRG"; echo "FAIL: history-registry script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HRG"
if grep -q "^FAIL" <<<"$HRG"; then fail=1; fi
grep -q "^smoke:" <<<"$HRG" || { echo "$HRG"; echo "FAIL: history-registry script produced no smoke line"; fail=1; }
hrgcheck() { if grep -qF -- "$1" <<<"$HRG"; then echo "ok   $2"; else echo "FAIL $2"; near "$HRG" "$1"; fail=1; fi; }
HRGSEQ="$(grep -oE '^history: (Volume = [0-9.]+|Area = [0-9.]+|Curve [0-9]+ length = [0-9.]+|UpdateHistory: [0-9]+ object\(s\) re-evaluated|BooleanUnion: exact)' <<<"$HRG" | sed 's/^history: //' | tr '\n' '|' | sed -E 's/Volume = 224\.[56]\|/Volume = 224.6|/g; s/Volume = 180[12]\|/Volume = 1802|/g')"
HRGWANT="Volume = 250|Volume = 500|UpdateHistory: 2 object(s) re-evaluated|Volume = 500|Volume = 500|Volume = 500|BooleanUnion: exact|Volume = 1500|UpdateHistory: 3 object(s) re-evaluated|Volume = 1700|Volume = 500|UpdateHistory: 3 object(s) re-evaluated|Volume = 700|Volume = 1500|UpdateHistory: 3 object(s) re-evaluated|Volume = 1700|Volume = 250|UpdateHistory: 0 object(s) re-evaluated|Volume = 250|BooleanUnion: exact|Volume = 1500|UpdateHistory: 1 object(s) re-evaluated|Volume = 4000|Volume = 1000|Volume = 500|UpdateHistory: 2 object(s) re-evaluated|Volume = 2000|Area = 400|Volume = 1436|UpdateHistory: 1 object(s) re-evaluated|Volume = 6009|Area = 50|UpdateHistory: 1 object(s) re-evaluated|Area = 100|Area = 100|UpdateHistory: 1 object(s) re-evaluated|Area = 400|Area = 50|UpdateHistory: 1 object(s) re-evaluated|Area = 200|Curve 50 length = 18.85|Volume = 112.9|UpdateHistory: 2 object(s) re-evaluated|Curve 50 length = 50.27|Volume = 803.8|Volume = 1728|UpdateHistory: 2 object(s) re-evaluated|Volume = 5808|Volume = 224.6|UpdateHistory: 1 object(s) re-evaluated|Volume = 1802|Volume = 1802|BooleanUnion: exact|Volume = 2368|UpdateHistory: 2 object(s) re-evaluated|Volume = 2128|"
if [ "$HRGSEQ" = "$HRGWANT" ]; then echo "ok   history-registry: every measured value before/after each UpdateHistory is the analytic one (curve->Extrude->BooleanIntersection 250->500 after moving the curve; ->BooleanUnion 1500->1700; BooleanDifference 500->700; Boolean2Objects 1500->1700; root deleted keeps 250; PlanarSrf->ExtrudeSrf 500->2000 and area 100->400; ExtrudeCrvTapered 1436->6009; ExtrudeCrvAlongCrv 50->100; NetworkSrf 4 curves 100->400; EdgeSrf 3 curves 50->200; Offset length 18.85->50.27 and its extrusion 112.9->803.8; Extrude->OffsetSrf 1728->5808; RailRevolve 224.6->1802 = the fresh construction; exact Box->OffsetSrf->BooleanUnion 2368->2128)"; else echo "FAIL history-registry measured sequence differs"; echo "got:  $HRGSEQ"; echo "want: $HRGWANT"; fail=1; fi
hrgcheck "object 4: BooleanIntersection <- 2,3" "the History report lists the boolean with its two recorded operand ids (the operands are hidden sources, not deleted)"
hrgcheck "object 10: BooleanUnion <- 8,9" "...and a 3-deep curve -> Extrude -> BooleanUnion chain is listed with each link's sources"
hrgcheck "object 63: OffsetSrf <- 61" "...and OffsetSrf records its source solid"
hrgcheck "object 64: BooleanUnion <- 62,63" "...and the exact-B-rep boolean records both operands"
hrgcheck "! UpdateHistory: object 22 (Extrude) kept as it was: source object 21 no longer exists" "deleting the root curve: the extrusion is not rebuilt and the printed reason names the missing source"
hrgcheck "! UpdateHistory: object 24 (BooleanIntersection) kept as it was: it depends on object 22, which was not rebuilt (source object 21 no longer exists)" "...and the boolean built from it is skipped with the upstream reason instead of being rebuilt from a half-updated chain"
hrgcheck "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry, 2 skipped" "...and the summary counts both as skipped"
hrgcheck "History recording: off. 0 object(s) with live construction history" "History Off: a boolean made while Off recorded nothing"
hrgcheck "BooleanUnion: exact B-rep boolean (no tessellation), 14 face(s)" "...and (History Off) it still deletes its operands: 24 objects, the expect_objects in the script"
hrgcheck "Object 64 (polysurface) layer Default" "the exact-boolean result is still a polysurface after UpdateHistory (it did not degrade to a mesh)"
hrgcheck "  36 faces, 72 edges, closed solid" "...with the new shape's own topology (42 faces before the box moved, 36 after) and still a closed solid"

# Automatic history propagation + EditHistory (cmd_history.cpp, Document::
# JoinPendingChange, tests/history_auto_script.txt): with History On, editing a
# SOURCE object (Move/Scale/Delete/Undo/Redo here, no UpdateHistory call in the
# A sections) rebuilds every recorded dependent in dependency order inside the
# same undo step; EditHistory re-runs a recorded construction with new options.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HAU="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_auto_script.txt" 2>&1)" || { echo "$HAU"; echo "FAIL: history-auto script exited non-zero"; exit 1; }
else
  HAU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_auto_script.txt" 2>&1)" || { echo "$HAU"; echo "FAIL: history-auto script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HAU" || true
if grep -q "^FAIL" <<<"$HAU"; then fail=1; fi
grep -q "^smoke:" <<<"$HAU" || { echo "$HAU"; echo "FAIL: history-auto script produced no smoke line"; fail=1; }
haucheck() { if grep -qF -- "$1" <<<"$HAU"; then echo "ok   $2"; else echo "FAIL $2"; near "$HAU" "$1"; fail=1; fi; }
haucheckre() { if grep -qE -- "$1" <<<"$HAU"; then echo "ok   $2"; else echo "FAIL $2"; near "$HAU" "$1"; fail=1; fi; }
haucount() { local n; n="$(grep -cF -- "$1" <<<"$HAU" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HAU" "$1"; fail=1; fi; }
HAUSEQ="$(grep -oE '^history: (! )?(Volume = [0-9.]+|Bounding box min [^ ]+ max [^ ]+|History: source object\(s\) [0-9,]+ changed - [0-9]+ dependent\(s\) re-evaluated( \([0-9,]+\))?|UpdateHistory: [0-9]+ object\(s\) re-evaluated)' <<<"$HAU" | sed 's/^history: //' | tr '\n' '|')"
HAUWANT="Volume = 1728|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)|Bounding box min 4,-1,-1 max 16,11,11|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)|Volume = 5808|Volume = 1728|Volume = 5808|Volume = 250|History: source object(s) 6 changed - 2 dependent(s) re-evaluated (7,9)|Volume = 500|Volume = 250|Volume = 500|! History: source object(s) 6 changed - 0 dependent(s) re-evaluated|Volume = 500|History: source object(s) 6 changed - 2 dependent(s) re-evaluated (7,9)|Volume = 250|Volume = 1000|Volume = 1000|UpdateHistory: 1 object(s) re-evaluated|Volume = 4000|Volume = 3168|Volume = 6048|Volume = 3168|Volume = 1728|Volume = 3168|"
if [ "$HAUSEQ" = "$HAUWANT" ]; then echo "ok   history-auto: with NO UpdateHistory call, Moving/Scaling a curve rebuilds its extrusion and the offset solid built from it (2-deep chain: offset solid box -1..11 -> 4..16 after Move, volume 1728 -> 5808 after Scale 2x, back to 1728 on Undo and 5808 on Redo - one undo step covers the curve AND both dependents); the same for curve -> Extrude -> BooleanIntersection (250 -> 500, Undo 250, Redo 500); Delete of the root curve keeps the old geometry and prints the reason; Undo of the Delete + Move rebuilds again (250); History Off propagates nothing (1000) until UpdateHistory (4000)"; else echo "FAIL history-auto measured sequence differs"; echo "got:  $HAUSEQ"; echo "want: $HAUWANT"; fail=1; fi
haucheck "! History: source object(s) 6 changed - 0 dependent(s) re-evaluated, 2 kept as they were: object 7 - source object 6 no longer exists; object 9 - it depends on object 7, which was not rebuilt (source object 6 no longer exists)" "failure case: deleting the root curve prints ONE summary line naming each kept object and its reason (the dependent of the failed extrusion is skipped with the upstream reason)"
haucheck "Automatic updates this session: 4 dependent rebuild(s), 0 kept as they were" "an unrelated edit (Move of a box nothing depends on) rebuilt nothing: still the 4 rebuilds from the two curve edits"
haucheck "Automatic updates this session: 8 dependent rebuild(s), 2 kept as they were" "...and the session totals at the end: 4 + 2 + 2 rebuilt, the 2 kept from the Delete"
haucount "History: source object(s)" 5 "exactly five automatic-update lines in the whole run (2 + 1 + the failed Delete + 1): no other edit, including the unrelated Move, the Hide/Show, selection and EditHistory, triggered one"
haucheck "EditHistory: object 13 (Extrude) <- 12 - editable parameters (EditHistory 13 name=value ...):" "EditHistory with no key=value lists the object's editable parameters"
haucheck "  distance = 10   - extrusion distance along the recorded direction (non-zero; negative flips the direction)" "...with the current value and the valid range"
haucheck "  bothsides = no   - extrude symmetrically to both sides of the curve [yes|no]" "...and choice options with their choices"
haucheck "EditHistory: object 13 (Extrude): distance 10 -> 20." "EditHistory distance=20 reports the change"
haucheck "  before: bbox 0,50,0 to 10,60,10, volume 1000" "...with the measured geometry before (10x10x10 prism, volume 1000)"
haucheck "  after:  bbox 0,50,0 to 10,60,20, volume 2000" "...and after (z 0..20, volume 2000)"
haucheck "  dependents re-evaluated: 14" "...and the offset solid built from the extrusion is re-evaluated in the same step"
haucheck "  after:  bbox 0,50,-20 to 10,60,20, volume 4000" "bothsides=yes: the extrusion becomes symmetric about the curve (z -20..20, volume 4000; the offset solid follows to 6048, see the sequence)"
haucheck "EditHistory: object 13 unchanged - distance: distance must be non-zero" "a zero distance is refused and changes nothing"
haucheck "EditHistory: object 13 unchanged - 'bogus' is not an editable parameter of Extrude (valid: distance, bothsides, solid)" "an unknown parameter is refused, listing the valid names"
haucheck "EditHistory: object 13 unchanged - bothsides: 'maybe' is not one of: yes, no" "a bad choice value is refused, listing the choices"
haucheck "EditHistory: object 12 has no recorded construction history" "EditHistory on an object with no history says so"
haucheck "EditHistory: object 99 does not exist" "EditHistory on a missing id says so"
haucount "  distance = 10   - extrusion distance along the recorded direction" 2 "after Undo the RECORD is restored with the geometry: the parameter listing reads distance=10 originally, and again after the second Undo (the listing of 20 sits between them)"
haucount "  distance = 20   - extrusion distance along the recorded direction" 1 "...and reads distance=20 after the first Undo (undoing only the bothsides edit)"
haucheck "ListHistory: 1 object(s) with construction history:" "ListHistory names the recorded objects"
haucheck "  object 14 (mesh): OffsetSrf <- 13  [distance=1, solid=no]" "...with each record's sources and parameters"
haucheck "      input 13 (polysurface)" "ShowHistory also names each input object"
haucheck "  after:  bbox -10,-10,0 to 10,10,5, volume 1302" "tapered extrusion: draft 10 -> 20 degrees measurably narrows the solid (1436 -> 1302)"
haucheck "  after:  bbox -10,-10,0 to 10,10,10, volume 3140" "...distance 10 draft 0 is the straight cylinder pi*100*10 = 3141.6"
haucheck "EditHistory: object 16 unchanged - draft: draft must be between -90 and 90 degrees (exclusive)" "an out-of-range draft is refused"
haucheck "EditHistory: object 18 (Revolve): angle 360 -> 180." "revolve angle 360 -> 180"
haucheck "volume 224.6" "...from the full-revolve volume 224.6"
haucheckre "volume 112\.[1-4]" "...to half of it (112.1 on Linux, 112.3 on the Windows tessellation)"
haucheck "EditHistory: object 18 unchanged - angle: angle must be greater than 0 and at most 360 degrees" "an angle over 360 is refused"
haucheck "EditHistory: object 20 (Pipe): radius 1 -> 2." "pipe radius 1 -> 2"
haucheckre "volume 31\.2[89]" "...volume pi*1*10 = 31.4 (tessellated 31.29 on Linux, 31.28 on Windows)"
haucheck "volume 125.4" "...to pi*4*10 = 125.7 (tessellated 125.4)"
haucheck "EditHistory: object 20 unchanged - radius: radius must be positive" "a negative radius is refused"
haucheck "EditHistory: object 24 (Loft): style normal -> straight." "loft style Normal -> Straight"
haucheck "  before: bbox 0,0,300 to 10,10,302.9, area 120.4" "...Normal interpolates smoothly through the middle line (area 120.4, z peak 302.9)"
haucheck "  after:  bbox 0,0,300 to 10,10,303, area 116.6" "...Straight is the ruled loft 2 * 10 * sqrt(5^2+3^2) = 116.6"
haucheck "EditHistory: object 26 (Offset): distance -2 -> -1." "curve offset distance -2 -> -1"
haucheck "length 18.85" "...inward offset circle r=3 has length 18.85"
haucheck "length 25.13" "...r=4 has length 25.13"
haucheck "length 37.7" "...and distance +1 flips to the outside, r=6: length 37.7"
haucount "operand groups swapped" 2 "boolean swap=yes twice"
haucheck "  after:  bbox 10,150,0 to 12,160,10, volume 200" "BooleanDifference swap=yes: A-B (800) becomes B-A (200)"
haucheck "  after:  bbox 0,150,0 to 12,160,10, volume 1200" "operation=union: 800 + 400 - 200 = 1200"
haucheck "  after:  bbox 8,150,0 to 10,160,10, volume 200" "operation=intersection: the 2 x 10 x 10 overlap, volume 200"
haucheck "  object 30: BooleanDifference <- 28,29  [operation=intersection]" "the History report names each record's parameters: the edited boolean now reads operation=intersection"
haucheck "  object 24: Loft <- 21,22,23  [style=normal, cap=yes]" "...and the loft's style/cap"


# Automatic history propagation, part 2 (tests/history_auto2_script.txt): the
# other ways a source is edited (Rotate, Mirror Copy=No, ScaleNU, a boolean
# OPERAND moved directly) rebuild the dependents with no UpdateHistory, inside
# the same undo step; every claim is a measured Volume.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HA2="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_auto2_script.txt" 2>&1)" || { echo "$HA2"; echo "FAIL: history-auto2 script exited non-zero"; exit 1; }
else
  HA2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_auto2_script.txt" 2>&1)" || { echo "$HA2"; echo "FAIL: history-auto2 script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HA2" || true
if grep -q "^FAIL" <<<"$HA2"; then fail=1; fi
grep -q "^smoke:" <<<"$HA2" || { echo "$HA2"; echo "FAIL: history-auto2 script produced no smoke line"; fail=1; }
ha2check() { if grep -qF -- "$1" <<<"$HA2"; then echo "ok   $2"; else echo "FAIL $2"; near "$HA2" "$1"; fail=1; fi; }
ha2count() { local n; n="$(grep -cF -- "$1" <<<"$HA2" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HA2" "$1"; fail=1; fi; }
HA2SEQ="$(grep -oE '^history: (Volume = [0-9.]+|History: source object\(s\) [0-9,]+ changed - [0-9]+ dependent\(s\) re-evaluated( \([0-9,]+\))?)' <<<"$HA2" | sed 's/^history: //' | tr '\n' '|')"
HA2WANT="Volume = 500|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,4)|Volume = 457.1|Volume = 500|Volume = 457.1|Volume = 600|History: source object(s) 5 changed - 2 dependent(s) re-evaluated (6,8)|Volume = 400|Volume = 1000|History: source object(s) 9 changed - 1 dependent(s) re-evaluated (10)|Volume = 3000|Volume = 500|History: source object(s) 13 changed - 1 dependent(s) re-evaluated (14)|Volume = 200|Volume = 500|"
if [ "$HA2SEQ" = "$HA2WANT" ]; then echo "ok   history-auto2: with NO UpdateHistory call a Rotate of the source square rebuilds the extrusion AND the boolean built from it (overlap with a fixed box 500 -> 457.1 = 10*(50-4.289), the diamond clipped to the box), Undo restores 500 and Redo 457.1 in single steps; Mirror Copy=No across x=10 moves it 600 -> 400; ScaleNU 3,1,1 takes an extrusion 1000 -> 3000; moving a boolean's OPERAND (the box, not its curve) rebuilds the boolean 500 -> 200 and Undo gives 500"; else echo "FAIL history-auto2 measured sequence differs"; echo "got:  $HA2SEQ"; echo "want: $HA2WANT"; fail=1; fi
ha2count "History: source object(s)" 4 "exactly four automatic-update lines (Rotate, Mirror, ScaleNU, operand Move): Undo/Redo, Show, selection and Volume triggered none"
ha2check "Automatic updates this session: 6 dependent rebuild(s), 0 kept as they were" "...and the session total is 2 + 2 + 1 + 1 rebuilds, none kept"
ha2count "History rebuild of a boolean: exact B-rep boolean declined" 3 "a boolean rebuilt automatically prints the same engine-decline reason the live command printed (3 mesh-path rebuilds)"

# ---------------------------------------------------------------------------
# viewport close (PARITY_MAP.md app_display "Per-object display mode override" +
# "View-dependent adaptive tessellation"): per-object RayTraced composited with
# rasterized objects (pixels), face-level brep refinement (triangle counts and
# sagitta vs an exact cylinder/sphere, no rebuild thrash), curve/SubD/mesh deep zoom,
# and the adaptive on/off setting persisted in settings.json.
# tests/viewport_close_script.txt builds everything; the checks are below.
# ---------------------------------------------------------------------------
mkdir -p "$TMPW/vpc"
sed "s|@TMP@|$TMPW/vpc|g" "$HERE/viewport_close_script.txt" > "$TMPW/viewport_close_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  VPC="$(timeout 900 env DINO8_RT_FRAMES=1 "$BIN" --smoke 30 --script "$TMPW/viewport_close_script.txt" 2>&1)" || { echo "$VPC"; echo "FAIL: viewport_close script exited non-zero"; exit 1; }
else
  VPC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" env DINO8_RT_FRAMES=1 "$BIN" --smoke 30 --script "$TMPW/viewport_close_script.txt" 2>&1)" || { echo "$VPC"; echo "FAIL: viewport_close script exited non-zero"; exit 1; }
fi
vpccheck() { if grep -q "$1" <<<"$VPC"; then echo "ok   $2"; else echo "FAIL $2"; near "$VPC" "$1"; fail=1; fi; }
vpcnum() { # DESC EXPR : EXPR is an awk expression over already-substituted numbers
  local r; r="$(awk "BEGIN { print ($2) ? \"yes\" : \"no\" }")"
  if [ "$r" = yes ]; then echo "ok   $1"; else echo "FAIL $1 [$2]"; fail=1; fi
}
# vpchdr N FIELD: FIELD of the N-th "LodStats: adaptive=" header line.
vpchdr() {
  awk -v n="$1" -v f="$2" '
    /LodStats: adaptive=/ { k++; if (k == n) { if (match($0, f "=[a-z0-9]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPC"
}
# vpcval N VIEWPORT FIELD: FIELD of the first object line of viewport VIEWPORT in the N-th LodStats call.
vpcval() {
  awk -v n="$1" -v v="$2" -v f="$3" '
    /LodStats: adaptive=/ { k++ }
    k == n && index($0, "LodStats: viewport " v " object ") { if (match($0, f "=[-0-9.e+]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } }' <<<"$VPC"
}
# vpcsag N FIELD: FIELD of the N-th "LodSagitta:" line.
vpcsag() {
  awk -v n="$1" -v f="$2" '
    /^LodSagitta: / || /history: LodSagitta: / { k++; if (k == n) { if (match($0, f "=[-0-9.e+]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPC"
}
vpccheck "gl_error=0" "viewport_close script ran without OpenGL errors"

# ---- Part A: per-object RayTraced, pixel level --------------------------------
python3 - "$TMPW/vpc" <<'PY' && echo "ok   per-object display modes work in a RayTraced viewport and RayTraced works per object: rasterized objects are depth-composited with the traced frame in BOTH directions (sphere in front hides the Pen box; Pen box in front hides the sphere)" || { echo "FAIL per-object RayTraced pixel check"; fail=1; }
import struct, sys
d = sys.argv[1]
def load(name):
    b = open(f'{d}/{name}.bmp', 'rb').read()
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', b[2:30])
    assert hdr == 40 and planes == 1 and bpp == 24, (name, hdr, planes, bpp)
    row = (w * 3 + 3) & ~3
    px = b[off:]
    def get(x, y):
        r = h - 1 - y
        i = r * row + x * 3
        return px[i + 2], px[i + 1], px[i]
    return w, h, get
def white(p): return all(c >= 235 for c in p)
all_t, front, back = load('a_all_traced'), load('a_sphere_front'), load('a_sphere_back')
sh_base, sh_rt = load('a_shaded_base'), load('a_shaded_rtsphere')
w, h, gb = back
ws = [(x, y) for y in range(h) for x in range(w) if white(gb(x, y))]
assert ws, 'no Pen-white pixels in a_sphere_back: the rasterized Pen box is missing from the RayTraced viewport'
xs, ys = [p[0] for p in ws], [p[1] for p in ws]
x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
s = (x1 - x0) / 8.6            # pixels per world unit (box B is 8.6 wide)
bx = int(cx + 3.8 * s)         # a point on B outside the sphere's radius-3 silhouette
ax = int(cx - 30 * s)          # centre of box A (x=-15)
print(f'B white bbox x {x0}..{x1} y {y0}..{y1} centre ({cx},{cy}) scale {s:.2f} px/unit; probes: B-edge ({bx},{cy}) A ({ax},{cy})')
def show(tag, im, pts):
    print(f'{tag:18s}', ' '.join(f'{n}={im[2](*p)}' for n, p in pts.items()))
pts = {'Bcentre': (cx, cy), 'Bside': (bx, cy), 'A': (ax, cy)}
for tag, im in (('all_traced', all_t), ('sphere_front', front), ('sphere_back', back), ('shaded_base', sh_base), ('shaded_rtsphere', sh_rt)): show(tag, im, pts)
g = lambda im, p: im[2](*p)
# NOTE: this environment's software GL (xvfb/llvmpipe) shows the GPU trace's OWN pixels as the dark background even for a
# plain box (the pre-existing RayTraced viewport has no pixel assertion anywhere), so what is measured here is what the
# composite itself decides: which objects the rasterizer draws, and depth occlusion between rasterized and traced objects.
# 1. B -> Pen (rasterized, flat white) while the sphere in FRONT is traced: B is visible beside the sphere, and the TRACED sphere
#    (whose depth the composite wrote) hides B's centre - there the traced frame shows through instead of the flat white
assert white(g(front, (bx, cy))), f'Pen box not rasterized beside the sphere: {g(front, (bx, cy))}'
assert not white(g(front, (cx, cy))), f'traced sphere in front does not hide the rasterized box centre: {g(front, (cx, cy))}'
# 2. sphere BEHIND the Pen box: the rasterized box hides the traced sphere
assert white(g(back, (cx, cy))), f'rasterized Pen box does not hide the traced sphere behind it: {g(back, (cx, cy))}'
# 3. A (never overridden) is traced in a RayTraced viewport, so the rasterizer must NOT draw it: it is not its Shaded red
assert g(front, (ax, cy)) != g(sh_base, (ax, cy)) and not white(g(front, (ax, cy))), 'box A was rasterized in the RayTraced viewport'
# 4. Shaded viewport + sphere overridden to RayTraced: the sphere is no longer rasterized-green, A and B (still rasterized) are
#    byte-identical to the all-Shaded capture
assert g(sh_base, (cx, cy))[1] > g(sh_base, (cx, cy))[0] + 40, 'shaded base sphere is not green'
assert g(sh_rt, (cx, cy)) != g(sh_base, (cx, cy)) and not (g(sh_rt, (cx, cy))[1] > g(sh_rt, (cx, cy))[0] + 40), 'sphere still rasterized after the RayTraced override'
assert g(sh_base, (ax, cy)) == g(sh_rt, (ax, cy)), 'rasterized box A changed when only the sphere was overridden to RayTraced'
assert g(sh_base, (bx, cy)) == g(sh_rt, (bx, cy)), 'rasterized box B changed when only the sphere was overridden to RayTraced'
PY
vpccheck "ObjectDisplayModes: object [0-9]* polysurface = Pen (viewport Top)" "ObjectDisplayModes lists the Pen override in the RayTraced viewport"
vpccheck "ObjectDisplayModes: object [0-9]* polysurface = RayTraced (viewport Top)" "ObjectDisplayModes lists RayTraced as a per-object (per-viewport) mode"
vpccheck "SetObjectDisplayMode: 1 object(s) now always shown RayTraced" "SetObjectDisplayMode RayTraced is accepted (no longer refused)"
VPC_RT_RT="$(grep -c 'ObjectDisplayModes: object [0-9]* polysurface = RayTraced (viewport Top)' <<<"$VPC" || true)"
vpcnum "RayTraced survives Save/New/Open through the .3dm (listed before and after the round trip)" "$VPC_RT_RT == 2"
if grep -q "GpuRaytracer::Init failed" <<<"$VPC"; then echo "FAIL GpuRaytracer::Init failed in the viewport_close script"; fail=1; else echo "ok   GpuRaytracer::Init did not fail in the viewport_close script"; fi

# ---- Part B: face-level refinement (sphere R500 + cylinder R100 through it, Front view) ----
V_OLD_TRIS="$(vpcval 2 Front tris)"; V_NEW_TRIS="$(vpcval 3 Front tris)"
V_OLD_FF="$(vpcval 2 Front fine_faces)"; V_NEW_FF="$(vpcval 3 Front fine_faces)"; V_TOT="$(vpcval 3 Front total_faces)"
V_OLD_MAX="$(vpcsag 1 max_sagitta)"; V_NEW_MAX="$(vpcsag 2 max_sagitta)"
V_OLD_MEAN="$(vpcsag 1 mean_sagitta)"; V_NEW_MEAN="$(vpcsag 2 mean_sagitta)"
V_OLD_IN="$(vpcsag 1 in_region)"; V_NEW_IN="$(vpcsag 2 in_region)"
echo "     visible-corner deep zoom on the +Z cylinder tip: whole-object (old) $V_OLD_TRIS tris, $V_OLD_IN in view, max/mean sagitta $V_OLD_MAX / $V_OLD_MEAN;  face-level (new) $V_NEW_TRIS tris ($V_NEW_FF of $V_TOT faces fine), $V_NEW_IN in view, max/mean sagitta $V_NEW_MAX / $V_NEW_MEAN"
vpcnum "face-level: only the visible faces are fine (fine_faces < total_faces, >= 1); the old whole-object build has fine_faces=0 (all faces at one level)" "$V_NEW_FF >= 1 && $V_NEW_FF < $V_TOT && $V_OLD_FF == 0"
vpcnum "face-level: the whole mesh is much smaller than the whole-object build ($V_NEW_TRIS < $V_OLD_TRIS)" "$V_NEW_TRIS < $V_OLD_TRIS"
vpcnum "face-level: the visible corner is MORE accurate (max sagitta new $V_NEW_MAX <= old $V_OLD_MAX) with the same budget" "$V_NEW_MAX <= $V_OLD_MAX"
vpcnum "face-level: and has at least as many triangles in the visible region (new $V_NEW_IN >= old $V_OLD_IN)" "$V_NEW_IN >= $V_OLD_IN"
vpcnum "the per-object budget still holds in both builds (<= 150000 triangles + 10%)" "$V_NEW_TRIS <= 165000 && $V_OLD_TRIS <= 165000"
# no thrash: steady frames never rebuild; moving to another face is ONE rebuild; returning is a stash hit
R3="$(vpchdr 3 rebuilds)"; R4="$(vpchdr 4 rebuilds)"; R5="$(vpchdr 5 rebuilds)"; R6="$(vpchdr 6 rebuilds)"; R7="$(vpchdr 7 rebuilds)"; R8="$(vpchdr 8 rebuilds)"
H3="$(vpchdr 3 stash_hits)"; H7="$(vpchdr 7 stash_hits)"
echo "     rebuilds across the face-level steps: after build $R3, +10 frames $R4, other face $R5, +10 frames $R6, back $R7, +10 frames $R8;  stash_hits $H3 -> $H7"
vpcnum "no per-frame rebuild thrash: ten more frames at the same view rebuild nothing" "$R4 == $R3"
vpcnum "...also after moving the view to a different face and after returning" "$R6 == $R5 && $R8 == $R7"
vpcnum "moving to another face rebuilds (at most 2 levels), returning is served from the stash (rebuilds unchanged, stash_hits up)" "$R5 - $R4 <= 2 && $R7 == $R6 && $H7 > $H3"
vpcnum "the other face is the fine one there (sphere view: fine_faces >= 1 and < total)" "$(vpcval 5 Front fine_faces) >= 1 && $(vpcval 5 Front fine_faces) < $(vpcval 5 Front total_faces)"
echo "     sphere face in view (R500, one face, nothing to cull inside it): $(vpcval 5 Front tris) tris, max/mean sagitta in the 25x30 window $(vpcsag 3 max_sagitta) / $(vpcsag 3 mean_sagitta) (the face alone exhausts the budget; a face this big is not refined only where visible)"
vpcnum "the single visible face may use the whole budget (>100000 triangles, <= 165000) - the other four faces stay at their small off-screen cap" "$(vpcval 5 Front tris) > 100000 && $(vpcval 5 Front tris) <= 165000"

# measurement commands do not depend on the camera: BoundingBox/Volume/Area at zoom-extents and at the deepest zoom agree exactly
VPC_BBN="$(grep -ac 'Bounding box min' <<<"$VPC" || true)"; VPC_BBD="$(grep -a 'Bounding box min' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"
VPC_VOD="$(grep -a 'Volume = ' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"; VPC_ARD="$(grep -a 'Area = ' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"
vpcnum "BoundingBox, Volume and Area read the same at zoom-extents and at a 12-unit deep zoom with the face-level mesh built (each printed twice, one distinct value)" "$VPC_BBN == 2 && $VPC_BBD == 1 && $VPC_VOD == 1 && $VPC_ARD == 1"

# ---- Part D: curves, SubD, mesh ------------------------------------------------
C0_N="$(vpcsag 5 total)"; C0_S="$(vpcsag 5 max_sagitta)"; C1_N="$(vpcsag 6 total)"; C1_S="$(vpcsag 6 max_sagitta)"
echo "     circle R500: whole view $C0_N segments max sagitta $C0_S;  deep zoom (12-unit window) $C1_N segments max sagitta $C1_S"
vpcnum "curve: deep zoom re-samples the circle finer (more segments) and the chord error drops with the zoom" "$C1_N > $C0_N && $C1_S < $C0_S"
vpcnum "curve: at deep zoom the chord error is below half a pixel of that zoom ($(vpcval 9 Top surface_tol) units)" "$C1_S < $(vpcval 9 Top surface_tol)"
S0="$(vpcval 10 Top tris)"; S1="$(vpcval 11 Top tris)"
echo "     SubD box 1000: smooth display triangles at zoom-extents $S0, in a 4-unit window $S1"
vpcnum "SubD: smooth display is subdivided deeper on zoom (more triangles at deep zoom), within the 150000-triangle budget" "$S1 > $S0 && $S1 <= 165000"
M0="$(vpcval 12 Top tris)"; M1="$(vpcval 13 Top tris)"
M0S="$(vpcsag 7 max_sagitta)"; M1S="$(vpcsag 8 max_sagitta)"
echo "     MeshSphere R500 (528 faces): display triangles at extents $M0 and at deep zoom $M1; sagitta of the mesh itself vs the exact sphere $M0S / $M1S"
vpcnum "mesh: the display level IS the mesh (same triangle count at every zoom; nothing re-tessellated)" "$M0 == $M1"

# ---- Part C: the adaptive on/off setting persists in settings.json -------------
mkdir -p "$TMPW/vpc_persist"
printf 'AdaptiveTessellation Off\n' > "$TMPW/vpc_persist/off.txt"
printf 'LodStats\n' > "$TMPW/vpc_persist/status.txt"
printf 'AdaptiveTessellation On\n' > "$TMPW/vpc_persist/on.txt"
run_vpc_persist() {
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 300 "$BIN" --smoke 10 --script "$1" 2>&1
  else
    timeout 300 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 10 --script "$1" 2>&1
  fi
}
VPC_P1="$(run_vpc_persist "$TMPW/vpc_persist/off.txt")" || { echo "$VPC_P1"; echo "FAIL: persist-off launch exited non-zero"; fail=1; }
if grep -q '"adaptive_tessellation": false' "$CONFIG_DIR/settings.json"; then echo "ok   settings.json stores \"adaptive_tessellation\": false after AdaptiveTessellation Off"; else echo "FAIL settings.json has no adaptive_tessellation=false"; grep -n adaptive "$CONFIG_DIR/settings.json"; fail=1; fi
VPC_P2="$(run_vpc_persist "$TMPW/vpc_persist/status.txt")" || { echo "$VPC_P2"; echo "FAIL: persist-status launch exited non-zero"; fail=1; }
if grep -q "LodStats: adaptive=off" <<<"$VPC_P2"; then echo "ok   a fresh launch reads adaptive tessellation OFF back from settings.json (the toggle survives sessions)"; else echo "FAIL fresh launch did not restore adaptive=off"; near "$VPC_P2" "LodStats: adaptive"; fail=1; fi
VPC_P3="$(run_vpc_persist "$TMPW/vpc_persist/on.txt")" || { echo "$VPC_P3"; echo "FAIL: persist-on launch exited non-zero"; fail=1; }
if grep -q '"adaptive_tessellation": true' "$CONFIG_DIR/settings.json"; then echo "ok   turning it back On is persisted too (\"adaptive_tessellation\": true)"; else echo "FAIL settings.json has no adaptive_tessellation=true"; fail=1; fi

# SetObjectDisplayMode is an undo step (independent review found it mutated the
# object with no BeginChange): Undo returns the object to the viewport's own mode,
# Redo reapplies it. (display_mode_undo_script.txt)
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  DMU="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/display_mode_undo_script.txt" 2>&1)" || { echo "$DMU"; echo "FAIL: display-mode undo script exited non-zero"; exit 1; }
else
  DMU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/display_mode_undo_script.txt" 2>&1)" || { echo "$DMU"; echo "FAIL: display-mode undo script exited non-zero"; exit 1; }
fi
dmu_count() { grep -c -- "$1" <<<"$DMU" || true; }
[ "$(dmu_count 'ObjectDisplayModes: 1 of 1 object(s) carry a per-object display mode Pen=1')" = "2" ] \
  && echo "ok   SetObjectDisplayMode Pen was applied, and Redo applied it again (two reports of Pen=1)" \
  || { echo "FAIL SetObjectDisplayMode Pen / Redo did not report Pen=1 twice"; fail=1; }
[ "$(dmu_count 'ObjectDisplayModes: 0 of 1 object(s) carry a per-object display mode')" = "1" ] \
  && echo "ok   Undo reverted SetObjectDisplayMode: the object is back on the viewport's own mode" \
  || { echo "FAIL Undo did not revert SetObjectDisplayMode"; fail=1; }


# Construction history persists in the .3dm (HPS_; hps_save_script.txt +
# hps_reopen_script.txt). Document::HistoryRecords() is written as the document
# user string "Dino8.HistoryMeta" (object uuids on disk, remapped to the fresh
# ids on Open), so after Save -> New -> Open, and in a brand-new process, moving a
# source object rebuilds its dependents automatically (no UpdateHistory).
# Phase 1 builds + saves three documents (History Off = negative control; root
# curve deleted before Save = dangling source; the real chain, whose saved ids
# are NOT 1,2,3.. because a throw-away box was deleted first) and reopens the
# chain in-process; phase 2 is a fresh process that opens the files. Volumes and
# bounding boxes come from measured Volume / BoundingBox output, compared with a
# tolerance (the Windows CI tessellates the mesh offset/boolean slightly
# differently).
# ---------------------------------------------------------------------------
HPS_DIR="$TMPW/hps"
mkdir -p "$HPS_DIR"
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_save_script.txt" > "$HPS_DIR/hps_save_script.txt"
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_reopen_script.txt" > "$HPS_DIR/hps_reopen_script.txt"
hps_run() {  # hps_run <script>: one app launch, output on stdout
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$1" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$1" 2>&1
  fi
}
HPS_S="$(hps_run "$HPS_DIR/hps_save_script.txt")" || { echo "$HPS_S"; echo "FAIL: hps save script exited non-zero"; exit 1; }
HPS_R="$(hps_run "$HPS_DIR/hps_reopen_script.txt")" || { echo "$HPS_R"; echo "FAIL: hps reopen script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$HPS_S" || { echo "$HPS_S"; echo "FAIL: hps save script produced no smoke line"; fail=1; }
grep -q "^smoke:" <<<"$HPS_R" || { echo "$HPS_R"; echo "FAIL: hps reopen script produced no smoke line"; fail=1; }
hps_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
# hps_vol <output> <n>: the n-th "Volume = X" value; hps_bb <output> <n>: the n-th bounding box as "x0,y0,z0,x1,y1,z1"
hps_vol() { { grep -oE 'Volume = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Volume = //'; }
hps_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
# hps_closev <a> <b> <tol> / hps_closebb <a-list> <b-list> <tol>: prints 1 when every number is within tol
hps_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
hps_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
hps_sh() { hps_ok "$(hps_closev "$(hps_vol "$1" "$2")" "$3" "$4")" "$5 (measured $(hps_vol "$1" "$2"), expected $3 +/- $4)"; }
hps_sb() { hps_ok "$(hps_closebb "$(hps_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(hps_bb "$1" "$2"), expected $3)"; }
hps_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
hps_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- phase 1: the building process (3 documents, then the chain reopened in-process)
hps_count "$HPS_S" "Saved $HPS_DIR/hps_" 3 "HPS_save: the three documents (History Off, deleted source, the chain) were written"
hps_has "$HPS_S" "History recording: off. 0 object(s) with live construction history" "HPS_off: built with History Off, nothing is recorded"
hps_has "$HPS_S" "History recording: on. 2 object(s) with live construction history" "HPS_del: extrude + offset recorded before the root curve was deleted"
hps_has "$HPS_S" "object 3: Extrude <- 2  [distance=10" "HPS_on: before Save the ids are shifted (the throw-away box took id 1): extrude 3 <- curve 2"
hps_has "$HPS_S" "object 2: Extrude <- 1  [distance=10" "HPS_on: after New + Open the same records are back with REMAPPED ids (extrude 2 <- curve 1)"
hps_has "$HPS_S" "object 7: BooleanIntersection <- 5,6  [operation=intersection]" "HPS_on: the two-source boolean record came back with both sources remapped (5,6) and its operation"
hps_count "$HPS_S" "History recording: on. 4 object(s) with live construction history:" 2 "HPS_on: the History report lists 4 records both before Save and after the in-process reopen"
# Volume order in phase 1: 1 off(1728) 2 del(1728) 3 on id4 before save(1728) 4 id8 before save(250), then after reopen 5 id3 after Move(1728) 6 id7 before(250) 7 id7 after Move(500)
hps_sh "$HPS_S" 3 1728 1 "HPS_on before Save: the offset solid (box 12^3) has the expected volume"
hps_sh "$HPS_S" 4 250 1 "HPS_on before Save: the boolean intersection volume"
hps_sb "$HPS_S" 1 "-1,-1,-1,11,11,11" 0.05 "HPS_on before Save: offset solid bounding box"
hps_sb "$HPS_S" 2 "-1,-1,-1,11,11,11" 0.05 "HPS_on after New + Open (before any edit): the SAME bounding box as before Save"
hps_sb "$HPS_S" 3 "4,-1,-1,16,11,11" 0.05 "HPS_on after reopen, curve moved +5 in X: the offset solid FOLLOWED (bbox moved with no UpdateHistory)"
hps_sh "$HPS_S" 5 1728 1 "HPS_on after reopen + Move: the rebuilt offset solid keeps its volume"
hps_sh "$HPS_S" 6 250 1 "HPS_on after reopen (before edit): boolean volume equals the value before Save"
hps_sh "$HPS_S" 7 500 2 "HPS_on after reopen, second source curve moved +5: the boolean rebuilt automatically (250 -> 500)"
hps_has "$HPS_S" "History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)" "HPS_on in-process reopen: automatic propagation line for the offset chain"
hps_has "$HPS_S" "History: source object(s) 4 changed - 2 dependent(s) re-evaluated (5,7)" "HPS_on in-process reopen: automatic propagation line for the boolean chain"

# --- phase 2: a FRESH process opens the files
hps_count "$HPS_R" "History recording: on. 4 object(s) with live construction history:" 1 "HPS_fresh: the records are read from the .3dm by a new process"
hps_has "$HPS_R" "object 5: Extrude <- 4  [distance=10" "HPS_fresh: remapped ids (second extrude 5 <- curve 4)"
hps_has "$HPS_R" "object 3: OffsetSrf <- 2  [distance=1, solid=no]" "HPS_fresh: numeric options survived (distance=1, solid=no)"
# Volumes in phase 2: 1 id3 before(1728) 2 after Scale 2x(5808) 3 after Undo(1728) 4 id7(250) 5 id7 after Move(500) 6 after Undo(250) 7 OFF(1728) 8 DEL before(1728) 9 DEL after UpdateHistory(1728)
hps_sb "$HPS_R" 1 "-1,-1,-1,11,11,11" 0.05 "HPS_fresh: opened offset solid bounding box"
hps_sb "$HPS_R" 2 "4,-1,-1,16,11,11" 0.05 "HPS_fresh: curve moved +5 in X, no UpdateHistory: the offset solid bounding box followed"
hps_sh "$HPS_R" 1 1728 1 "HPS_fresh: offset solid volume before any edit"
hps_sh "$HPS_R" 2 5808 6 "HPS_fresh: curve scaled 2x about (5,0,0): offset solid volume rebuilt (same value as the live-session test in history_auto_script.txt)"
hps_sh "$HPS_R" 3 1728 1 "HPS_fresh: Undo restores the offset solid (the rebuild is inside the edit's undo step)"
hps_sh "$HPS_R" 4 250 1 "HPS_fresh: boolean volume before the edit"
hps_sh "$HPS_R" 5 500 2 "HPS_fresh: second curve moved: the boolean rebuilt (250 -> 500)"
hps_sh "$HPS_R" 6 250 1 "HPS_fresh: Undo restores the boolean"
hps_count "$HPS_R" "History: source object(s)" 4 "HPS_fresh: exactly 4 automatic updates (Move, Scale, Move of the 2nd curve, and the Move after the SECOND Save/Open) - none for the controls"
hps_has "$HPS_R" "History: source object(s) 4 changed - 2 dependent(s) re-evaluated (5,7)" "HPS_fresh: boolean chain propagation line"
hps_sb "$HPS_R" 3 "4,4,-1,16,16,11" 0.05 "HPS_resave: records written from a LOADED document survive a second Save/New/Open (curve moved +5 in Y: bbox follows on top of the earlier +5 X)"
# negative control 1: saved with History Off
hps_has "$HPS_R" "History recording: on. 0 object(s) with live construction history" "HPS_off control: a document saved with History Off has no records to restore"
hps_sb "$HPS_R" 4 "-1,-1,-1,11,11,11" 0.05 "HPS_off control: the source curve was moved and NOTHING followed (bbox unchanged)"
hps_has "$HPS_R" "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry" "HPS_off control: UpdateHistory says it has nothing to re-evaluate"
hps_sb "$HPS_R" 5 "-1,-1,-1,11,11,11" 0.05 "HPS_off control: still unchanged after UpdateHistory"
hps_sh "$HPS_R" 7 1728 1 "HPS_off control: volume unchanged"
# negative control 2: the source curve was deleted before Save
hps_has "$HPS_R" "object 1: Extrude <- (deleted)" "HPS_del control: the extrude's record kept its slot but names its source as deleted"
hps_has "$HPS_R" "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry, 2 skipped" "HPS_del control: UpdateHistory re-evaluates nothing and reports 2 skipped"
hps_has "$HPS_R" "UpdateHistory: object 1 (Extrude) kept as it was: its source object was deleted before the file was saved" "HPS_del control: the reason is the deleted source"
hps_sb "$HPS_R" 6 "-1,-1,-1,11,11,11" 0.05 "HPS_del control: offset solid bounding box before UpdateHistory"
hps_sb "$HPS_R" 7 "-1,-1,-1,11,11,11" 0.05 "HPS_del control: ...and after UpdateHistory (geometry untouched)"
hps_sh "$HPS_R" 8 1728 1 "HPS_del control: volume before UpdateHistory"
hps_sh "$HPS_R" 9 1728 1 "HPS_del control: volume after UpdateHistory (unchanged)"

# --- part 3: Shell records history (hps_shell_script.txt). Plain Shell (closed solid,
# uniform thickness, no opened faces) hides its source and records {source,
# thickness}; the shell follows edits of the source, survives Save/New/Open and
# EditHistory thickness=..., and an opened-face Shell / History Off record nothing.
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_shell_script.txt" > "$HPS_DIR/hps_shell_script.txt"
HPS_H="$(hps_run "$HPS_DIR/hps_shell_script.txt")" || { echo "$HPS_H"; echo "FAIL: hps shell script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$HPS_H" || { echo "$HPS_H"; echo "FAIL: hps shell script produced no smoke line"; fail=1; }
# Volumes: 1 shell(1408) 2 source scaled 2x (6008) 3 after Undo(1408) 4 after reopen + EditHistory thickness=2 (2464)
#          5 curve->Extrude->Shell (1408) 6 same after the curve moved (1408) 7 History Off (1408) 8 opened-face Shell (1084)
# Bounding boxes: 1 shell (0..20) 2 source moved +5 X 3 reopened source moved +5 Y 4 extrude chain moved +7 X
hps_has "$HPS_H" "Shell: thickness 1, closed, exact B-rep, volume 1408" "HPS_shell: a plain Shell of a box still takes the exact B-rep path"
hps_has "$HPS_H" "object 2: Shell <- 1  [thickness=1]" "HPS_shell: with History On the Shell is recorded (source 1, thickness 1) and the source box is kept (hidden) not deleted"
hps_sh "$HPS_H" 1 1408 2 "HPS_shell: hollowed 20x20x10 box, wall 1 (4000 - 18*18*8)"
hps_sb "$HPS_H" 2 "5,0,0,25,20,10" 0.05 "HPS_shell: source box moved +5 in X, no UpdateHistory: the shell followed"
hps_sh "$HPS_H" 2 6008 6 "HPS_shell: source box scaled 2x: the shell was re-shelled with the same wall (40*40*20 - 38*38*18)"
hps_sh "$HPS_H" 3 1408 2 "HPS_shell: Undo restores the previous shell (the rebuild is in the edit's undo step)"
hps_has "$HPS_H" "History recording: on. 1 object(s) with live construction history:" "HPS_shell: the Shell record is read back from the .3dm after New + Open"
hps_sb "$HPS_H" 3 "5,5,0,25,25,10" 0.05 "HPS_shell: after Save/New/Open the shell follows its (reopened) source moved +5 in Y"
hps_has "$HPS_H" "EditHistory: object 2 (Shell): thickness 1 -> 2." "HPS_shell: EditHistory exposes and changes the recorded thickness"
hps_sh "$HPS_H" 4 2464 4 "HPS_shell: after EditHistory thickness=2 (4000 - 16*16*6)"
hps_has "$HPS_H" "Shell: object 2 - exact B-rep shell not used" "HPS_shell: curve -> Extrude -> Shell takes the mesh construction (the extrusion's faces are not recognised as planar) and says so, live and on rebuild"
hps_sh "$HPS_H" 5 1408 5 "HPS_shell: curve -> Extrude -> Shell (mesh path) volume before the edit"
hps_sb "$HPS_H" 4 "7,0,0,27,20,10" 0.05 "HPS_shell: source curve moved +7 in X: Extrude AND Shell followed (2-deep chain)"
hps_has "$HPS_H" "History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)" "HPS_shell: the chain propagation line names both dependents"
hps_sh "$HPS_H" 6 1408 5 "HPS_shell: ...and the mesh-path shell keeps its volume"
hps_has "$HPS_H" "History recording: off. 0 object(s) with live construction history" "HPS_shell control: Shell with History Off records nothing"
hps_sh "$HPS_H" 7 1408 2 "HPS_shell control: History Off Shell result unchanged from before"
hps_has "$HPS_H" "History recording: on. 0 object(s) with live construction history" "HPS_shell control: a Shell with an opened (clicked) face records nothing"
hps_sh "$HPS_H" 8 1084 2 "HPS_shell control: the opened-face Shell is the same exact open shell as before (volume 1084)"

# --- Tutorial video pipeline (tutorials/record.py, verify.py; docs/TUTORIALS.md).
# Records one real tutorial headless (the app's own ScreenCaptureToFile under
# Xvfb 1280x720, encoded with ffmpeg), then verifies the finished artifact from
# the files themselves: size, frame count, duration, resolution, non-blank
# frames (pixel variance, Python stdlib) and WebVTT validity/cue order.
# Skipped, loudly, where ffmpeg/ffprobe/python3 are missing or off Linux.
TUT_ID="04-extrude-revolve-vase"
TUT_OUT="$TMPW/tut_out"
if [ "$(uname -s)" = "Linux" ] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  TUT_SELF="$(python3 "$HERE/../tutorials/verify.py" --selftest 2>&1)" || true
  tut_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
  tut_has "$TUT_SELF" "TUT_selftest_flat_blank=1" "TUT_selftest: a flat frame is classified blank"
  tut_has "$TUT_SELF" "TUT_selftest_noisy_not_blank=1" "TUT_selftest: a textured frame is not blank"
  tut_has "$TUT_SELF" "TUT_selftest_good_vtt=1" "TUT_selftest: a valid WebVTT is accepted"
  tut_has "$TUT_SELF" "TUT_selftest_bad_order_rejected=1" "TUT_selftest: out-of-order cues are rejected"
  tut_has "$TUT_SELF" "TUT_selftest_no_header_rejected=1" "TUT_selftest: a file without the WEBVTT header is rejected"
  tut_has "$TUT_SELF" "TUT_selftest_too_long_rejected=1" "TUT_selftest: a cue running past the video end is rejected"
  TUT_REC="$(timeout 900 python3 "$HERE/../tutorials/record.py" --bin "$BIN" --id "$TUT_ID" --out "$TUT_OUT" 2>&1)" || { echo "$TUT_REC" | tail -20; echo "FAIL TUT_record: recorder exited non-zero"; fail=1; }
  tut_has "$TUT_REC" "record: $TUT_ID ->" "TUT_record: recorder reported the finished video"
  TUT_VER="$(python3 "$HERE/../tutorials/verify.py" "$TUT_OUT" "$TUT_ID" 2>&1)" || { echo "$TUT_VER" | tail -20; echo "FAIL TUT_verify: verifier crashed (no video produced?)"; fail=1; TUT_VER=""; }
  tut_val() { { grep "^$2=" <<<"$1" || true; } | head -1 | cut -d= -f2-; }
  TUT_BYTES="$(tut_val "$TUT_VER" TUT_video_bytes)"
  if [ -n "$TUT_BYTES" ] && [ "$TUT_BYTES" -gt 50000 ] && [ "$TUT_BYTES" -lt 40000000 ]; then echo "ok   TUT_size: video file is $TUT_BYTES bytes (plausible: 50 kB..40 MB)"; else echo "FAIL TUT_size: video file size '$TUT_BYTES' not in 50 kB..40 MB"; fail=1; fi
  TUT_PF="$(tut_val "$TUT_VER" TUT_probe_frames)"; TUT_EF="$(tut_val "$TUT_VER" TUT_expected_frames)"
  if [ -n "$TUT_PF" ] && [ "$TUT_PF" = "$TUT_EF" ]; then echo "ok   TUT_frames: decoded frame count $TUT_PF equals the count expected from tutorial.txt"; else echo "FAIL TUT_frames: decoded '$TUT_PF' != expected '$TUT_EF'"; fail=1; fi
  TUT_PD="$(tut_val "$TUT_VER" TUT_probe_duration)"; TUT_ED="$(tut_val "$TUT_VER" TUT_expected_duration)"
  if [ -n "$TUT_PD" ] && python3 -c "import sys; sys.exit(0 if abs(float('$TUT_PD')-float('$TUT_ED')) <= 0.2 else 1)"; then echo "ok   TUT_duration: container duration $TUT_PD s matches expected $TUT_ED s"; else echo "FAIL TUT_duration: '$TUT_PD' vs expected '$TUT_ED'"; fail=1; fi
  tut_has "$TUT_VER" "TUT_probe_size=1280x720" "TUT_size720: video is 1280x720"
  tut_has "$TUT_VER" "TUT_probe_fps=10/1" "TUT_fps: video is 10 fps"
  TUT_SAMP="$(tut_val "$TUT_VER" TUT_sampled_frames)"
  if [ -n "$TUT_SAMP" ] && [ "$TUT_SAMP" -ge 10 ]; then echo "ok   TUT_sample: $TUT_SAMP frames sampled for the variance check"; else echo "FAIL TUT_sample: only '$TUT_SAMP' frames could be sampled"; fail=1; fi
  tut_has "$TUT_VER" "TUT_blank_frames=0" "TUT_blank: no sampled frame is blank (luminance variance >= 4)"
  TUT_DIFF="$(tut_val "$TUT_VER" TUT_first_last_diff)"
  if [ -n "$TUT_DIFF" ] && python3 -c "import sys; sys.exit(0 if float('$TUT_DIFF') > 0.5 else 1)"; then echo "ok   TUT_progress: first and last sampled frames differ (mean abs diff $TUT_DIFF)"; else echo "FAIL TUT_progress: first and last frames are identical (diff '$TUT_DIFF')"; fail=1; fi
  tut_has "$TUT_VER" "TUT_vtt=ok" "TUT_vtt: captions are valid WebVTT with strictly increasing, non-overlapping cues inside the video"
  TUT_NC="$(tut_val "$TUT_VER" TUT_vtt_cues)"; TUT_XC="$(tut_val "$TUT_VER" TUT_expected_cues)"
  if [ -n "$TUT_NC" ] && [ "$TUT_NC" = "$TUT_XC" ] && [ "$TUT_NC" -ge 3 ]; then echo "ok   TUT_cues: $TUT_NC caption cues, one per #narrate: line"; else echo "FAIL TUT_cues: '$TUT_NC' cues vs expected '$TUT_XC'"; fail=1; fi
  TUT_TXT="$TUT_OUT/$TUT_ID/$TUT_ID.txt"
  if [ -s "$TUT_TXT" ]; then echo "ok   TUT_transcript: voice-over transcript written"; else echo "FAIL TUT_transcript: $TUT_TXT missing or empty"; fail=1; fi
  # The generated site lists every tutorial and is self-contained (no CDN/tracker).
  TUT_SITE_OUT="$(python3 "$HERE/../tutorials/build_site.py" 2>&1)" || { echo "$TUT_SITE_OUT"; echo "FAIL TUT_site: build_site.py failed"; fail=1; }
  tut_has "$TUT_SITE_OUT" "(10 tutorials)" "TUT_site: index.html built for all 10 tutorials"
  if [ -z "$({ grep -E 'src="https?://|href="https?://|<script' "$HERE/../tutorials/index.html" || true; })" ]; then echo "ok   TUT_site_selfcontained: index.html has no external URLs and no scripts"; else echo "FAIL TUT_site_selfcontained: index.html references an external URL or script"; fail=1; fi
else
  echo "skip TUT_*: tutorial pipeline checks need Linux with ffmpeg, ffprobe and python3 (see docs/TUTORIALS.md)"
fi

# ---------------------------------------------------------------------------
# Third-party plug-in ecosystem (docs/PLUGIN_GUIDE.md, docs/COMMUNITY.md):
#  * psdk_*  - tests/plugin_sdk_test.sh installs the SDK (plugin-sdk/) to a temp
#    prefix, generates each plugin-templates/ template into a clean directory,
#    builds it against that prefix ALONE, loads the built plug-ins into this very
#    $BIN headless and checks each plug-in's command ran; also the ABI
#    compatibility rule, a package + localhost-HTTP marketplace round trip with
#    sha256 refusal, and DigitalSign/VerifySignature on a manifest.
#  * psite_* - tests/plugin_site_test.sh renders the plug-in index with
#    tools/site/build_site.py and checks no external requests, escaping of
#    hostile index data, parity with the app's own index parser, and that the
#    app loads the plugin-index.json the site publishes.
# The helpers print "ok   <name>" / "FAIL <name>"; the lists below make sure a
# helper that silently skipped a check cannot pass. Skipped on Windows runners
# (the helpers drive cmake/python3/bash job control, validated on Linux/macOS).
PSDK_REQUIRED="psdk_sdk_install psdk_sdk_header_identical psdk_find_package_ok psdk_find_package_too_new psdk_cmd_builds psdk_xyz_builds psdk_rep_builds psdk_templates_self_contained psdk_templates_rendered psdk_template_needs_sdk psdk_cmd_loaded psdk_xyz_loaded psdk_rep_loaded psdk_cmd_ran psdk_xyz_export_ran psdk_xyz_export_file psdk_xyz_import_ran psdk_rep_ran psdk_rep_total psdk_app_objects psdk_abi_newer_declined psdk_abi_newer_message psdk_abi_older_loads psdk_abi_older_ran psdk_package_layout psdk_market_index psdk_market_sha_refused psdk_market_install psdk_market_ran psdk_market_verify psdk_sign_verify psdk_sign_sidecar psdk_sign_tamper"
PSITE_REQUIRED="psite_renders_index psite_index_verbatim psite_install_instructions psite_community_link psite_no_external_requests psite_one_local_script psite_csp psite_no_tracker psite_app_reads_site_index psite_escapes_script psite_escapes_markup psite_no_javascript_url psite_rejects_schema2 psite_rejects_both psite_app_parity_schema psite_app_parity_both psite_stricter_trav psite_stricter_badsha psite_placeholder_entry_refused psite_packaged_entry_accepted psite_warns_missing_sha psite_github_forms"
if [ "$IS_WINDOWS" = 1 ]; then
  echo "skip psdk_*/psite_* (Windows runner: plug-in SDK and site helpers run on Linux/macOS)"
elif ! command -v cmake >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "skip psdk_*/psite_* (cmake or python3 not installed)"
else
  PSDK="$(timeout 900 bash "$HERE/plugin_sdk_test.sh" "$BIN" 2>&1)" || { echo "$PSDK" | tail -40; echo "FAIL: plugin_sdk_test.sh exited non-zero"; fail=1; }
  echo "$PSDK" | grep -E "^(ok|FAIL|skip)" || true
  if grep -q "^FAIL" <<<"$PSDK"; then fail=1; fi
  if grep -q "^skip psdk_market" <<<"$PSDK"; then
    PSDK_REQUIRED="$(sed -E 's/ psdk_(package_layout|market_[a-z_]+)//g' <<<"$PSDK_REQUIRED")"
  fi
  for n in $PSDK_REQUIRED; do
    if ! grep -q "^ok   $n[: ]" <<<"$PSDK"; then echo "FAIL $n did not report ok (check missing or helper skipped it)"; fail=1; fi
  done
  PSITE="$(timeout 900 bash "$HERE/plugin_site_test.sh" "$BIN" 2>&1)" || { echo "$PSITE" | tail -40; echo "FAIL: plugin_site_test.sh exited non-zero"; fail=1; }
  echo "$PSITE" | grep -E "^(ok|FAIL|skip)" || true
  if grep -q "^FAIL" <<<"$PSITE"; then fail=1; fi
  for n in $PSITE_REQUIRED; do
    if ! grep -q "^ok   $n[: ]" <<<"$PSITE"; then echo "FAIL $n did not report ok (check missing or helper skipped it)"; fail=1; fi
  done
  # Touch support of the exported web viewer (src/io/WebViewer.cpp): markers in
  # the real exported HTML, plus - where node + Playwright + Chromium exist - real
  # touch input (one-finger orbit, two-finger pinch) via tests/web_viewer_touch_check.js.
  PWV="$(timeout 900 bash "$HERE/web_viewer_touch_test.sh" "$BIN" 2>&1)" || { echo "$PWV" | tail -30; echo "FAIL: web_viewer_touch_test.sh exited non-zero"; fail=1; }
  echo "$PWV" | grep -E "^(ok|FAIL|skip)" || true
  if grep -q "^FAIL" <<<"$PWV"; then fail=1; fi
  for n in pwv_export pwv_viewport_meta pwv_touch_action pwv_pointer_events pwv_coarse_ui pwv_no_mouse_only pwv_self_contained; do
    if ! grep -q "^ok   $n[: ]" <<<"$PWV"; then echo "FAIL $n did not report ok"; fail=1; fi
  done
fi

# ---------------------------------------------------------------------------
# Dino 8 Touch (touch/, the PWA companion app) + its /touch/ and /touch/api/
# server routes (src/net/TouchApi.cpp). touch/tests/touch_gestures.test.js
# starts this very binary headless with --serve --serve-touch under its own
# xvfb-run, loads the PWA in touch-emulating Chromium (Playwright), drives it
# with synthetic CDP touch events and asserts measured camera changes (orbit
# angle, pan distance, pinch ratio), long-press selection, a three-finger
# undo and a typed command read back through the server, that unauthenticated
# requests are refused, and that the service worker loads the app with the
# network blocked. Skipped with a clear line when node, the playwright
# package or xvfb-run is missing (it is not a hard dependency of the app).
TCH_TEST="$HERE/../touch/tests/touch_gestures.test.js"
if ! command -v node >/dev/null 2>&1; then
  echo "skip TCH_ Dino 8 Touch PWA test (node is not installed)"
elif ! node -e "require('playwright')" >/dev/null 2>&1; then
  echo "skip TCH_ Dino 8 Touch PWA test (the node 'playwright' package is not installed)"
elif ! command -v xvfb-run >/dev/null 2>&1; then
  echo "skip TCH_ Dino 8 Touch PWA test (xvfb-run is not installed)"
elif [ ! -f "$TCH_TEST" ]; then
  echo "skip TCH_ Dino 8 Touch PWA test ($TCH_TEST not found)"
else
  TCH_RC=0
  TCH_OUT="$(timeout 900 node "$TCH_TEST" "$BIN" 2>&1)" || TCH_RC=$?
  TCH_OK="$(grep -c '^ok ' <<<"$TCH_OUT" || true)"
  TCH_BAD="$(grep -c '^FAIL' <<<"$TCH_OUT" || true)"
  if [ "$TCH_RC" -eq 0 ] && grep -q '^all passed' <<<"$TCH_OUT"; then
    echo "ok   TCH_touch: Dino 8 Touch PWA test passed ($TCH_OK checks: gestures, auth refusal, command round trip, offline service worker)"
  else
    echo "$TCH_OUT"
    echo "FAIL TCH_touch: Dino 8 Touch PWA test exited $TCH_RC ($TCH_OK ok, $TCH_BAD failed)"
    fail=1
  fi
fi

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


exit $fail

