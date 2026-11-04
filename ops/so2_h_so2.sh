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
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-a85dac6234d906358/dino8-app/tests
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


exit $fail
