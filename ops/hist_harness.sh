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
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests
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
hcheck "History recording: on - new results of 29 construction commands (BlendSrf/Boolean2Objects/BooleanDifference/BooleanIntersection/BooleanUnion/Cap/ChamferEdge/Extrude/" "History On toggled recording on and now lists the registry-driven set of recordable constructions (was a hand-written 10-name sentence; the registry now has 29 names - 23 before the H2R_ additions BlendSrf, Cap, ChamferEdge, FilletEdge, Project and Pull - e.g. Shell, ExtrudeSrf, Offset, OffsetSrf, RailRevolve and the four booleans on top of the old Extrude/ExtrudeCrvToPoint/Revolve/Loft/SubDLoft/Pipe/Sweep1/Sweep2/Patch/NetworkSrf2)"
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
hnscheck "Bounding box min 0,0,0 max 10,10,5" "UpdateHistory genuinely re-derived the ruled surface's geometry from source line 1's new z=5 position - not the flat z=0 surface baked at creation time"

# RecordMacro: a real action recorder for the Macro Editor's buffer (see
# record_macro_script.txt's own header comment for exactly what this
# checks) - PARITY_MAP.md's "VBA-style macro recorder and editor" item.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RMAC="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/record_macro_script.txt" 2>&1)" || { echo "$RMAC"; echo "FAIL: record-macro script exited non-zero"; exit 1; }
else
  RMAC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/record_macro_script.txt" 2>&1)" || { echo "$RMAC"; echo "FAIL: record-macro script exited non-zero"; exit 1; }
fi
echo "$RMAC" | grep -E "^(ok|FAIL)"
if echo "$RMAC" | grep -q "^FAIL"; then fail=1; fi
echo "$RMAC" | grep -q "^smoke:" || { echo "$RMAC"; echo "FAIL: record-macro script produced no smoke line"; fail=1; }
rmaccheck() { if echo "$RMAC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RMAC" "$1"; fail=1; fi; }
rmaccheck "Macro recording: off (type On to start). Buffer:" "RecordMacro with no argument reports Off and dumps the buffer before anything was recorded"
rmaccheck "Macro recording: on - every command line you type is appended to the Macro Editor's buffer" "RecordMacro On reports the state changed"
rmaccheck "  Line 0,0,0 10,0,0" "the Line command typed while recording was on was appended to the buffer verbatim"
rmaccheck "  Box 20,0,0 25,5,5 5" "the Box command typed while recording was on was appended to the buffer verbatim, in order after Line"
RMAC_LINE50_COUNT="$(echo "$RMAC" | grep -cF "Line 50,0,0 60,0,0" || true)"
[ "$RMAC_LINE50_COUNT" = "1" ] && echo "ok   the Line command typed AFTER RecordMacro Off was run but NOT appended to the buffer (it appears exactly once, as the typed command line itself, not a second time in the final dump)" || { echo "FAIL a command typed after RecordMacro Off leaked into the buffer (expected 1 occurrence, got $RMAC_LINE50_COUNT)"; fail=1; }
RMAC_SELF_COUNT="$(echo "$RMAC" | grep -cF "  RecordMacro" || true)"
[ "$RMAC_SELF_COUNT" = "0" ] && echo "ok   RecordMacro never recorded itself into its own buffer" || { echo "FAIL RecordMacro recorded one of its own toggle lines into the buffer"; fail=1; }

# Named macro library (MacroSave/MacroLoad/MacroDelete/RunSavedMacro,
# cmd_misc.cpp) - see macro_library_script.txt's own header comment for
# exactly what this checks - PARITY_MAP.md's "VBA-style macro recorder and
# editor" item, the "only one macro could ever be kept at a time" half.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  MLIB="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/macro_library_script.txt" 2>&1)" || { echo "$MLIB"; echo "FAIL: macro-library script exited non-zero"; exit 1; }
else
  MLIB="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/macro_library_script.txt" 2>&1)" || { echo "$MLIB"; echo "FAIL: macro-library script exited non-zero"; exit 1; }
fi
echo "$MLIB" | grep -E "^(ok|FAIL)"
if echo "$MLIB" | grep -q "^FAIL"; then fail=1; fi
echo "$MLIB" | grep -q "^smoke:" || { echo "$MLIB"; echo "FAIL: macro-library script produced no smoke line"; fail=1; }
mlibcheck() { if echo "$MLIB" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$MLIB" "$1"; fail=1; fi; }
mlibcheck "Saved macro 'saved macro'" "MacroSave confirms the name, including a space, round-tripped through Tokenize's quoting"
mlibcheck "Bounding box min 20,0,0 max 25,5,5" "RunSavedMacro really executed its saved Box line - SelLast's real geometry, not just a printed confirmation, and immune to how many other lines the shared buffer happened to carry in from an earlier script in this same smoke.sh run"
mlibcheck "  Line 0,0,0 10,0,0" "RunSavedMacro/MacroLoad's effect is visible via the buffer dump, starting with the saved Line text"
mlibcheck "  Box 20,0,0 25,5,5 5" "the saved macro's second recorded line"
MLIB_CIRCLE_IN_DUMP="$(echo "$MLIB" | grep -cF "  Circle 50,0,0 5" || true)"
[ "$MLIB_CIRCLE_IN_DUMP" = "0" ] && echo "ok   the buffer dump after MacroLoad shows the saved snapshot, not the Circle line typed into the live buffer after MacroSave ran" || { echo "FAIL MacroLoad did not actually restore the saved snapshot - the later Circle edit leaked through"; fail=1; }
mlibcheck "Loaded macro 'saved macro' into the Macro Editor buffer" "MacroLoad's own confirmation"
mlibcheck "Deleted macro 'saved macro'" "MacroDelete's own confirmation"
mlibcheck "MacroDelete: no saved macro named 'saved macro'" "deleting an already-deleted name warns instead of silently no-oping"
mlibcheck "RunSavedMacro: no saved macro named 'saved macro'" "running a deleted name warns instead of silently doing nothing or crashing"
mlibcheck "MacroLoad: no saved macro named 'saved macro'" "loading a deleted name warns instead of silently clearing the buffer"

# Alias targets that are real command lines (CommandEngine::Execute's new
# "!Find(name) && (space or ';')" branch) - see alias_macro_script.txt's
# own header comment for exactly what this checks and why it used to be
# silently broken rather than merely narrow. PARITY_MAP.md "Command
# aliases and shortcut customization" (the fix itself) and "VBA-style
# macro recorder and editor" (the "bind a saved macro to an alias" half
# this fix also closes).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  AMAC="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/alias_macro_script.txt" 2>&1)" || { echo "$AMAC"; echo "FAIL: alias-macro script exited non-zero"; exit 1; }
else
  AMAC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/alias_macro_script.txt" 2>&1)" || { echo "$AMAC"; echo "FAIL: alias-macro script exited non-zero"; exit 1; }
fi
echo "$AMAC" | grep -E "^(ok|FAIL)"
if echo "$AMAC" | grep -q "^FAIL"; then fail=1; fi
echo "$AMAC" | grep -q "^smoke:" || { echo "$AMAC"; echo "FAIL: alias-macro script produced no smoke line"; fail=1; }
amaccheck() { if echo "$AMAC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$AMAC" "$1"; fail=1; fi; }
amaccheck "Alias ln1 -> Line 0,0,0 10,0,0" "a multi-word alias target is captured verbatim, args included"
amaccheck "Command: Line 0,0,0 10,0,0" "invoking the alias really runs its full target line (used to fail with Unknown command before this fix), proven by the real object it creates (expect_objects just above)"
amaccheck "Command: Line 20,0,0 30,0,0" "a ';'-separated multi-command alias runs its first command"
amaccheck "Command: Circle 40,0,0 5" "...and its second command, in order"
amaccheck "Command: RunSavedMacro mymac" "a saved macro, bound to an alias, really runs when the alias is invoked"
amaccheck "Bounding box min 50,0,0 max 55,5,5" "the alias-bound macro's own replayed Box is real, freshly-created geometry (SelLast), not a stale object or a printed-only confirmation"
amaccheck "Added 'runmac1' to the Standard toolbar" "a macro-bound alias (not just a bare command name) can now go on a toolbar button via AddToolbarCommand - the toolbar half of the same fix"

# BlockSetArraySpacing/BlockSetArrayCount command-line wiring: PARITY_MAP.md
# "Dynamic blocks" Array parameter/action (the Document-level math itself is
# unit-tested directly in dino8_block_array/test_block_array.cpp) - see
# block_array_script.txt's own header comment.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BAR="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/block_array_script.txt" 2>&1)" || { echo "$BAR"; echo "FAIL: block-array script exited non-zero"; exit 1; }
else
  BAR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/block_array_script.txt" 2>&1)" || { echo "$BAR"; echo "FAIL: block-array script exited non-zero"; exit 1; }
fi
echo "$BAR" | grep -E "^(ok|FAIL)" || true
if echo "$BAR" | grep -q "^FAIL"; then fail=1; fi
echo "$BAR" | grep -q "^smoke:" || { echo "$BAR"; echo "FAIL: block-array script produced no smoke line"; fail=1; }
barcheck() { if echo "$BAR" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BAR" "$1"; fail=1; fi; }
barcheck "  1,0,0" "the block-defining leftover instance (created before BlockAddState/BlockSetArraySpacing ran) keeps its untouched original point"
barcheck "  11,0,0" "array copy 0 lands at the plain insert point (local 1,0,0 + insert 10,0,0)"
barcheck "  16,0,0" "array copy 1 is stepped 5 units along X from copy 0, not stacked on top of it"
barcheck "  21,0,0" "array copy 2 is stepped 10 units along X from copy 0"

# BlockSetLookupTable/BlockSetLookup command-line wiring: PARITY_MAP.md
# "Dynamic blocks" Lookup parameter/action - the fourth and last of the
# four named parameter/action types, after Visibility states, Flip and
# Array above (the Document-level math itself is unit-tested directly in
# dino8_block_lookup/test_block_lookup.cpp) - see block_lookup_script.txt's
# own header comment.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BLK="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/block_lookup_script.txt" 2>&1)" || { echo "$BLK"; echo "FAIL: block-lookup script exited non-zero"; exit 1; }
else
  BLK="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/block_lookup_script.txt" 2>&1)" || { echo "$BLK"; echo "FAIL: block-lookup script exited non-zero"; exit 1; }
fi
echo "$BLK" | grep -E "^(ok|FAIL)" || true
if echo "$BLK" | grep -q "^FAIL"; then fail=1; fi
echo "$BLK" | grep -q "^smoke:" || { echo "$BLK"; echo "FAIL: block-lookup script produced no smoke line"; fail=1; }
blkcheck() { if echo "$BLK" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BLK" "$1"; fail=1; fi; }
blkcheck "  12,0,0" "lookup key 'L' switches the instance to state Large: local (2,0,0) + insert (10,0,0) = (12,0,0)"
blkcheck "  11,0,0" "an unmatched lookup key falls back to the instance's own explicit state (Small): local (1,0,0) + insert (10,0,0) = (11,0,0)"

# BlockSetStretchAxis/BlockSetStretchGroup/BlockSetStretch command-line
# wiring: PARITY_MAP.md "Dynamic blocks" Stretch parameter/action - the
# fifth and last of the five named parameter/action types, after
# Visibility states, Flip, Array and Lookup above (the Document-level math
# itself is unit-tested directly in dino8_test_block_stretch/
# test_block_stretch.cpp) - see block_stretch_script.txt's own header
# comment.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BST="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/block_stretch_script.txt" 2>&1)" || { echo "$BST"; echo "FAIL: block-stretch script exited non-zero"; exit 1; }
else
  BST="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/block_stretch_script.txt" 2>&1)" || { echo "$BST"; echo "FAIL: block-stretch script exited non-zero"; exit 1; }
fi
echo "$BST" | grep -E "^(ok|FAIL)" || true
if echo "$BST" | grep -q "^FAIL"; then fail=1; fi
echo "$BST" | grep -q "^smoke:" || { echo "$BST"; echo "FAIL: block-stretch script produced no smoke line"; fail=1; }
bstcheck() { if echo "$BST" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BST" "$1"; fail=1; fi; }
bstcheck "  2,0,0" "the block-defining leftover instance (created before BlockAddState/BlockSetStretchAxis ran) keeps its untouched original tagged point"
bstcheck "  -3,0,0" "...and its untouched original untagged point"
bstcheck "  106,0,0" "the placed instance's tagged point moved 4 units along the stretch axis: local (2,0,0) + insert (100,0,0) + stretch 4 = (106,0,0)"
bstcheck "  97,0,0" "the placed instance's untagged point is unaffected by the same stretch: local (-3,0,0) + insert (100,0,0) = (97,0,0)"

# LayerPlotColor command-line wiring: PARITY_MAP.md "Print and plot output"
# item - the color half of "plot styles (CTB/STB)", alongside
# print_width_mm/LayerPrintWidth's lineweight half (the pure
# EffectivePlotColor function itself is unit-tested directly in
# dino8_plot_color/test_plot_color.cpp) - see plot_color_script.txt's own
# header comment. Checked directly against the real exported SVG files'
# stroke colors, not just a printed command confirmation.
sed "s|@TMP@|$TMPW|g" "$HERE/plot_color_script.txt" > "$TMPW/plot_color_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PLC="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/plot_color_script.txt" 2>&1)" || { echo "$PLC"; echo "FAIL: plot-color script exited non-zero"; exit 1; }
else
  PLC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/plot_color_script.txt" 2>&1)" || { echo "$PLC"; echo "FAIL: plot-color script exited non-zero"; exit 1; }
fi
echo "$PLC" | grep -E "^(ok|FAIL)" || true
if echo "$PLC" | grep -q "^FAIL"; then fail=1; fi
grep -q 'stroke="#000000"' "$TMPW/plot_color_off.svg" && echo "ok   with no plot color override, the exported SVG strokes the line in its own display color (black)" || { echo "FAIL plot_color_off.svg does not stroke black"; fail=1; }
grep -q 'stroke="#ff0000"' "$TMPW/plot_color_on.svg" && echo "ok   LayerPlotColor 255,0,0 makes the exported SVG stroke the line red, not its unchanged on-screen display color" || { echo "FAIL plot_color_on.svg does not stroke red"; fail=1; }
grep -q 'stroke="#000000"' "$TMPW/plot_color_cleared.svg" && echo "ok   LayerPlotColor ByLayer clears the override back to the display color (black)" || { echo "FAIL plot_color_cleared.svg does not stroke black again after clearing"; fail=1; }

# PlotStyleTable/LayerPlotStyle command-line wiring: PARITY_MAP.md "Print
# and plot output" item - the named, reusable CTB/STB-table half of "plot
# styles", alongside LayerPlotColor's own flat per-layer-only field just
# above (the pure ResolvePlotStyle/EffectivePlotColor overloads themselves
# are unit-tested directly in dino8_plot_style/test_plot_style.cpp) - see
# plot_style_script.txt's own header comment. Checked directly against the
# real exported SVG files' stroke colors, same as the LayerPlotColor check
# above, specifically proving two layers sharing one named style change
# together when the style's own row is edited.
sed "s|@TMP@|$TMPW|g" "$HERE/plot_style_script.txt" > "$TMPW/plot_style_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PST="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/plot_style_script.txt" 2>&1)" || { echo "$PST"; echo "FAIL: plot-style script exited non-zero"; exit 1; }
else
  PST="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/plot_style_script.txt" 2>&1)" || { echo "$PST"; echo "FAIL: plot-style script exited non-zero"; exit 1; }
fi
echo "$PST" | grep -E "^(ok|FAIL)" || true
if echo "$PST" | grep -q "^FAIL"; then fail=1; fi
RED_COUNT="$(grep -c 'stroke="#ff0000"' "$TMPW/plot_style_red.svg" || true)"
[ "$RED_COUNT" = "2" ] && echo "ok   both layers' lines stroke the named style's own red, though neither layer's own flat plot color was ever set" || { echo "FAIL plot_style_red.svg: expected 2 red strokes (one per layer sharing the style), got $RED_COUNT"; fail=1; }
BLUE_COUNT="$(grep -c 'stroke="#0000ff"' "$TMPW/plot_style_blue.svg" || true)"
[ "$BLUE_COUNT" = "2" ] && echo "ok   editing the shared style's color to blue changes both layers' lines together, with neither layer touched again" || { echo "FAIL plot_style_blue.svg: expected 2 blue strokes, got $BLUE_COUNT"; fail=1; }
grep -q 'stroke="#000000"' "$TMPW/plot_style_cleared.svg" && echo "ok   LayerPlotStyle None on the Default layer clears it back to its own display color (black)" || { echo "FAIL plot_style_cleared.svg: Default layer's line is not black after clearing its style"; fail=1; }
grep -q 'stroke="#0000ff"' "$TMPW/plot_style_cleared.svg" && echo "ok   ...while SecondLayer, never cleared, still strokes the shared style's current color (blue)" || { echo "FAIL plot_style_cleared.svg: SecondLayer's line lost its still-assigned style's color"; fail=1; }
# Transparency (PlotStyle::transparency, the third real CTB/STB plot-style
# column - no flat per-layer equivalent, so only reachable through a named
# style): Mono's own transparency set to 50% must halve the stroke-opacity
# of both layers sharing it in the exported SVG, and the exported PDF must
# carry a real ExtGState resource switched in via "gs" before the stroked
# content, not just a printed confirmation.
OPACITY_COUNT="$(grep -c 'stroke-opacity="0.5"' "$TMPW/plot_style_transparent.svg" || true)"
[ "$OPACITY_COUNT" = "2" ] && echo "ok   PlotStyleTable's optional 4th token (50% transparency) halves both layers' stroke-opacity to 0.5 in the exported SVG" || { echo "FAIL plot_style_transparent.svg: expected 2 stroke-opacity=\"0.5\" groups (one per layer sharing the style), got $OPACITY_COUNT"; fail=1; }
grep -aq '/ExtGState' "$TMPW/plot_style_transparent.pdf" && echo "ok   plot_style_transparent.pdf's page carries a real /ExtGState resource dict, not just a printed confirmation" || { echo "FAIL plot_style_transparent.pdf: no /ExtGState resource"; fail=1; }
grep -aq '/CA 0.5' "$TMPW/plot_style_transparent.pdf" && echo "ok   the ExtGState's own /CA (stroking alpha) is 0.5, matching the style's 50% transparency" || { echo "FAIL plot_style_transparent.pdf: no /CA 0.5 ExtGState"; fail=1; }
grep -aq '/GS1 gs' "$TMPW/plot_style_transparent.pdf" && echo "ok   the content stream switches the ExtGState in with a real \"gs\" operator before the stroked paths" || { echo "FAIL plot_style_transparent.pdf: no /GS1 gs operator in the content stream"; fail=1; }
# Linetype override (PlotStyle::linetype, the fourth and last real CTB/STB
# column this bullet named as missing): LinetypeLayer's line is really on
# the "Dashed" (5,3) linetype, but its own style (LTStyle) names "Hidden"
# (2,2) - the exported SVG must carry the STYLE's own dasharray, not the
# object's real one, and clearing the style's linetype column (PlotStyleTable
# re-saved without that token) must revert it back to the object's own.
grep -q 'stroke-dasharray="2,2"' "$TMPW/plot_style_linetype_override.svg" && echo "ok   a named style's own linetype override (Hidden, 2,2) drives the exported dasharray, not the object's own real linetype (Dashed, 5,3)" || { echo "FAIL plot_style_linetype_override.svg: expected a 2,2 dasharray from the style's own linetype override"; fail=1; }
grep -q 'stroke-dasharray="5,3"' "$TMPW/plot_style_linetype_cleared.svg" && echo "ok   clearing the style's own linetype column (PlotStyleTable re-saved without that token) reverts the same line to its own real linetype (Dashed, 5,3)" || { echo "FAIL plot_style_linetype_cleared.svg: expected the object's own 5,3 dasharray once the style's override was cleared"; fail=1; }
echo "$PST" | grep -qF "PlotStyle 'LTStyle': color ByLayer, width 0.5 mm, transparency 0%, linetype Hidden, screening 100%" && echo "ok   the linetype column survives a real Save/Open round trip through the native .3dm file (Dino8.PlotStyle.<name> user string, io/File3dm.cpp), not just kept in memory for this one process" || { echo "FAIL PlotStyleTable's own linetype column did not survive a real .3dm Save/Open round trip"; fail=1; }
# Screening (PlotStyle::screening, the fifth and last real CTB/STB column):
# ScreenStyle's own color is pure black and its screening column is 50% -
# the exported SVG must stroke exact mid-gray (#808080), not black, and
# re-saving the style with the screening token omitted (the same "one-shot,
# set every field" convention transparency/linetype above already have)
# must revert the same line to full black.
grep -q 'stroke="#808080"' "$TMPW/plot_style_screening_on.svg" && echo "ok   a named style's own 50% screening lightens its black color to exact mid-gray (#808080) in the exported SVG, not a see-through alpha blend" || { echo "FAIL plot_style_screening_on.svg: expected a #808080 stroke from the style's own 50% screening"; fail=1; }
grep -q 'stroke="#000000"' "$TMPW/plot_style_screening_cleared.svg" && echo "ok   clearing the style's own screening column (PlotStyleTable re-saved without that token, resetting to 100%) reverts the same line to full black" || { echo "FAIL plot_style_screening_cleared.svg: expected a #000000 stroke once the style's screening was cleared"; fail=1; }

# Print/Export linetype (dash pattern) wiring: PARITY_MAP.md "Print and
# plot output" item - ExportSvg/ExportPdf (io/FileExchange.cpp) now carry
# each curve's own real linetype through to a real vector dasharray/d
# operator, independent of the on-screen-only "Linetype Display" toggle
# (see dash_export_script.txt's own header comment for the real bug this
# fixes: the old behavior silently depended on that cosmetic toggle).
# Checked directly against the real exported SVG/PDF files, with an exact
# forced Scale=1 from a Top (parallel) view so the expected values are
# exact, not fit-to-page-dependent.
sed "s|@TMP@|$TMPW|g" "$HERE/dash_export_script.txt" > "$TMPW/dash_export_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  DES="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/dash_export_script.txt" 2>&1)" || { echo "$DES"; echo "FAIL: dash-export script exited non-zero"; exit 1; }
else
  DES="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/dash_export_script.txt" 2>&1)" || { echo "$DES"; echo "FAIL: dash-export script exited non-zero"; exit 1; }
fi
echo "$DES" | grep -E "^(ok|FAIL)" || true
if echo "$DES" | grep -q "^FAIL"; then fail=1; fi
grep -q 'stroke-dasharray="5,3"' "$TMPW/dash_scale1.svg" && echo "ok   a dashed line's real linetype (5,3) is exported as a real SVG stroke-dasharray, not a silently solid stroke, even with on-screen Linetype Display off" || { echo "FAIL dash_scale1.svg: no stroke-dasharray=\"5,3\""; fail=1; }
grep -aq '\[14.173 8.504\] 0 d' "$TMPW/dash_scale1.pdf" && echo "ok   the same linetype reaches ExportPdf as a real \"d\" dash operator (14.173/8.504 pt = 5/3 mm at Scale=1)" || { echo "FAIL dash_scale1.pdf: no [14.173 8.504] 0 d operator"; fail=1; }
grep -q 'stroke-dasharray' "$TMPW/solid_scale1.svg" && grep -q 'stroke-dasharray="5,3"' "$TMPW/solid_scale1.svg" || { echo "FAIL solid_scale1.svg: expected exactly one dasharray (the dashed line), none or more found"; fail=1; }
SOLID_DASH_COUNT="$(grep -c 'stroke-dasharray' "$TMPW/solid_scale1.svg" || true)"
[ "$SOLID_DASH_COUNT" = "1" ] && echo "ok   the Continuous-linetype line exported alongside it has no stray dasharray of its own" || { echo "FAIL solid_scale1.svg: expected exactly 1 stroke-dasharray (only the dashed line's), got $SOLID_DASH_COUNT"; fail=1; }
grep -aq '\[\] 0 d' "$TMPW/solid_scale1.pdf" && echo "ok   ExportPdf resets to a plain solid \"[] 0 d\" before the Continuous-linetype line, not leaking the other line's dash pattern" || { echo "FAIL solid_scale1.pdf: no [] 0 d reset operator"; fail=1; }

# Automatic associative-annotation recompute (PARITY_MAP.md "Associative
# annotation updating" - see auto_annotation_update_script.txt's own
# header comment for the full construction/reasoning): a dimension
# associative to a real Line's endpoints must already carry a brand new
# object id by the time this script's SECOND "List" runs, with no
# UpdateDimensions call anywhere in between the Scale1D that stretched
# the line and that second List - proof Application::Frame()'s new
# per-frame hook, not this script, already tore the old dimension down
# and rebuilt it. The explicit UpdateDimensions at the very end (run only
# to confirm correctness, not to cause the rebuild) must still report the
# correct stretched 40-unit measurement.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  AAU="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/auto_annotation_update_script.txt" 2>&1)" || { echo "$AAU"; echo "FAIL: auto-annotation-update script exited non-zero"; exit 1; }
else
  AAU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/auto_annotation_update_script.txt" 2>&1)" || { echo "$AAU"; echo "FAIL: auto-annotation-update script exited non-zero"; exit 1; }
fi
printf '%s' "$AAU" > "$TMPW/auto_annotation_update_output.txt"
python3 - "$TMPW/auto_annotation_update_output.txt" <<'PY' && echo "ok   the dimension already carried a brand new object id by the second List - proving Frame()'s new per-frame hook rebuilt it with no UpdateDimensions call in between" || { echo "FAIL the dimension's object id did not change between the two List calls (no automatic rebuild happened)"; fail=1; }
import re, sys
text = open(sys.argv[1]).read()
ids = [int(m.group(1)) for m in re.finditer(r"^history: Object (\d+) ", text, re.MULTILINE)]
assert len(ids) >= 2, f"expected at least 2 'Object <id>' List lines, got {ids}"
before, after = ids[0], ids[1]
assert after > before, f"expected the second List id ({after}) to be strictly greater than the first ({before}) - Add() always allocates higher ids, so an unchanged or lower id means no automatic rebuild happened"
PY
echo "$AAU" | grep -q "^history: UpdateDimensions:   DimLinear now measures 40$" && echo "ok   the automatically-rebuilt dimension's measurement is correct (40, the stretched length) - UpdateDimensions, run afterward only to confirm, agrees with what the per-frame hook already built" || { echo "FAIL auto-annotation-update: expected UpdateDimensions to confirm a 40-unit measurement"; fail=1; }

# Undo id-reuse regression (see the last section of history_script.txt):
# a Box drawn right after undoing a tracked Extrude used to be handed the
# undone extrusion's own id (6), so its HistoryRecord/Provenance entries -
# side tables keyed by ObjectId, deliberately outside the undo history -
# attached to the Box, and UpdateHistory rebuilt the Box into "surface
# (40,0,0)-(50,0,5)". Document::ApplyDelta now keeps the id counter
# monotonic across Undo, so the Box gets a fresh id (7) and the stale
# record resolves to nothing.
hcheck_absent() { if echo "$HS" | grep -qF "$1"; then echo "FAIL $2"; fail=1; else echo "ok   $2"; fi; }
hcheck "object 6: Extrude <- 5" "an Undo/Redo round trip keeps the redone extrusion's own id (6) and its HistoryRecord (the record survives Undo+Redo, it is only ever orphaned by a real removal)"
hcheck "  ID: 7" "a Box drawn after undoing the tracked extrusion (id 6) gets a fresh id (7), not the undone object's id"
# History records are now part of the undo deltas (automatic propagation work): undoing a
# tracked construction removes its record with it, so UpdateHistory has no orphan to clear
# (the old output said "1 orphaned entry cleared"). The invariant the test protects is
# unchanged: only the still-live tracked surface (4) is re-evaluated, and the new Box is
# NOT treated as a tracked object (checked just below: its geometry stays untouched).
hcheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" \
  "UpdateHistory rebuilt only the still-live tracked surface (4) - it did NOT treat the new Box as a tracked object"
hcheck_absent "orphaned entry cleared (object deleted" "an Undo takes the undone construction's history record with it, so UpdateHistory has no orphaned record to clear"
hcheck_absent "Bounding box: (40, 0, 0) to (50, 0, 5)" "the Box was never rebuilt into line 5's extrusion (the exact silent wrong result the id reuse produced before)"
hcheck "Bounding box: (50, 50, 0) to (60, 60, 10)" "the Box's own geometry is untouched after UpdateHistory"


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

exit $fail
