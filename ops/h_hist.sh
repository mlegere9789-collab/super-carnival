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
hcheck "History recording: on - new results of 38 construction commands (BlendSrf/Boolean2Objects/BooleanDifference/BooleanIntersection/BooleanUnion/Cap/ChamferEdge/ChamferSrf/Contour/Extrude/" "History On toggled recording on and now lists the registry-driven set of recordable constructions (was a hand-written 10-name sentence; the registry now has 38 names - 23 before the H2R_ additions BlendSrf, Cap, ChamferEdge, FilletEdge, Project and Pull, the H3R_ additions ChamferSrf and FilletSrf, and the H4R_ additions Contour, ExtrudeSrfAlongCrv, ExtrudeSrfTapered, ExtrudeSrfToPoint, OffsetCrvOnSrf, OffsetMultiple and Section - e.g. Shell, ExtrudeSrf, Offset, OffsetSrf, RailRevolve and the four booleans on top of the old Extrude/ExtrudeCrvToPoint/Revolve/Loft/SubDLoft/Pipe/Sweep1/Sweep2/Patch/NetworkSrf2)"
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
exit $fail
