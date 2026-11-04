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

# SR: exact revolved-solid editing (solidsrev_script.txt) - closes two more
# sub-gaps of "Solid editing with B-rep results (booleans, fillet, shell,
# offset)": OffsetSrf Solid=Yes on a plain capped cylinder (the hollow wall
# between the original and the offset, two shells of one Brep) and OffsetSrf /
# Shell on a plain capped cone and cone frustum (the (radius, height) profile
# is offset with sharp corners and revolved: every face an exact revolved
# surface). All of these used to give meshes. Every case is bracketed by an
# SRBEGIN_<name> marker; srblock slices the app output into that case.
# Volumes are read from the display mesh, so the ranges carry that tessellation
# error (measured 0.05-0.15% low here; +-0.6% allowed for other platforms);
# face/edge counts and "closed solid" are topological, so those are exact.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SROUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/solidsrev_script.txt" 2>&1)" || { echo "$SROUT"; echo "FAIL: solidsrev script exited non-zero"; exit 1; }
else
  SROUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/solidsrev_script.txt" 2>&1)" || { echo "$SROUT"; echo "FAIL: solidsrev script exited non-zero"; exit 1; }
fi
srblock() { awk -v name="$1" '$0 ~ ("Unknown command: SRBEGIN_" name "$") { on = 1; next } on && /Unknown command: SRBEGIN_|Unknown command: SREND/ { exit } on { print }' <<<"$SROUT"; }
srcheck() { local blk; blk="$(srblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Shell|Offset|Object|  [0-9]|Volume|!)" <<<"$blk" | head -8 | sed 's/^/     actual:   /' || true; fail=1; fi; }
# srvol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
srvol() {
  local blk v; blk="$(srblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- OffsetSrf Solid=Yes on a plain cylinder
srcheck O_cyl_solid_out "OffsetSrf: distance 1, 1 object(s), solid, 1 exact B-rep" "cylinder Solid=Yes is an exact B-rep (before: a 13420-triangle mesh, reason 'planar-only B-rep boolean')"
srcheck O_cyl_solid_out "(polysurface)" "...a polysurface"
srcheck O_cyl_solid_out "6 faces, 6 edges, closed solid" "...6 faces (outer 3 + reversed inner 3), a closed solid"
srvol O_cyl_solid_out 912 922 "cylinder r5 h20 Solid=Yes +1: Volume = pi*(36*22 - 25*20) = 917.35"
srcheck O_cyl_solid_out "Object 2: valid" "...and Check reports the result valid"
srcheck O_cyl_solid_out "0 bad object(s) selected" "...SelBadObjects selects nothing"
srcheck O_cyl_solid_in "solid, 1 exact B-rep" "Solid=Yes inward (the offset cylinder is the inner shell) is exact too"
srcheck O_cyl_solid_in "6 faces, 6 edges, closed solid" "...6 faces, closed solid"
srvol O_cyl_solid_in 662 670 "cylinder Solid=Yes -1: Volume = pi*(25*20 - 16*18) = 666.0"
srcheck O_cyl_solid_in "Object 2: valid" "...valid"
srcheck O_cyl_plain "3 faces, 3 edges, closed solid" "control: Solid=No on a cylinder is still the single exact 3-face cylinder"
srvol O_cyl_plain 2473 2503 "control: grown cylinder Volume = pi*36*22 = 2488.1"
srcheck O_cyl_solid_collapse "exact B-rep offset not used (the cylinder would collapse at that offset)" "shrinking past the radius: exact refused WITH the reason"
srcheck O_cyl_solid_collapse "(mesh)" "...and the mesh offset runs"
srcheck O_cyl_solid_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
# --- OffsetSrf on a plain cone / frustum
srcheck O_cone "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "cone offset is exact (before: a mesh)"
srcheck O_cone "2 faces, 3 edges, closed solid" "...the offset is again a 2-face cone"
srvol O_cone 603.5 610.5 "cone r5 h10 +1 = cone r6.618 h13.236: Volume = 607.08"
srcheck O_cone "Object 2: valid" "...valid"
srcheck O_cone_solid "solid, 1 exact B-rep" "cone Solid=Yes is exact"
srcheck O_cone_solid "4 faces, 6 edges, closed solid" "...4 faces (outer 2 + inner 2), closed solid"
srvol O_cone_solid 343 347.5 "cone Solid=Yes hollow wall Volume = 607.08 - 261.80 = 345.28"
srcheck O_cone_solid "Object 2: valid" "...valid"
srcheck O_tcone "1 exact B-rep" "frustum offset is exact"
srcheck O_tcone "3 faces, 5 edges, closed solid" "...3 faces, closed solid"
srvol O_tcone 962 974 "frustum r5->r3 h10 +1: Volume = 968.05"
srcheck O_tcone "Object 2: valid" "...valid"
srcheck O_tcone_solid_in "solid, 1 exact B-rep" "frustum Solid=Yes inward is exact"
srcheck O_tcone_solid_in "6 faces, 10 edges, closed solid" "...6 faces, closed solid"
srvol O_tcone_solid_in 282.8 286.3 "frustum hollow wall Volume = 513.13 - 228.58 = 284.55"
srcheck O_tcone_solid_in "Object 2: valid" "...valid"
srcheck O_cone_collapse "exact B-rep offset not used (the cone would collapse or self-intersect at that offset)" "shrinking a cone past its axial inradius: exact refused WITH the reason"
srcheck O_cone_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
# --- Shell of a plain cone / frustum
srcheck S_cone_closed "Shell: thickness 1, closed, exact B-rep" "cone closed shell is exact (before: a mesh)"
srcheck S_cone_closed "4 faces, 6 edges, closed solid" "...4 faces (outer 2 + inner 2), closed solid"
srvol S_cone_closed 179.5 182 "hollow cone Volume = 261.80 - 81.02 = 180.78"
srcheck S_cone_closed "Object 2: valid" "...valid"
srcheck S_cone_cap "open (1 face(s) removed), exact B-rep" "cone with its flat cap removed is an exact open cup"
srcheck S_cone_cap "3 faces, 5 edges, closed solid" "...3 faces (outer wall, inner wall, rim annulus), closed solid"
srvol S_cone_cap 138.3 140.3 "cone cup Volume = 139.28"
srcheck S_cone_cap "Object 2: valid" "...valid"
srcheck S_cone_wall "exact B-rep shell not used (only one flat cap of a cone can be removed exactly" "removing the cone's WALL: no exact construction, reason printed, mesh kept"
srcheck S_cone_wall "(mesh)" "...a mesh"
srcheck S_cone_thick "exact B-rep shell not used (the wall thickness is too large for this cone)" "a wall as thick as the cone: refused WITH the reason"
srcheck S_tcone_closed "Shell: thickness 1, closed, exact B-rep" "frustum closed shell is exact"
srcheck S_tcone_closed "6 faces, 10 edges, closed solid" "...6 faces, closed solid"
srvol S_tcone_closed 282.8 286.3 "hollow frustum Volume = 284.55"
srcheck S_tcone_closed "Object 2: valid" "...valid"
srcheck S_tcone_top "open (1 face(s) removed), exact B-rep" "frustum with the small (top) cap removed is an exact cup"
srcheck S_tcone_top "5 faces, 9 edges, closed solid" "...5 faces, closed solid"
srvol S_tcone_top 269.2 272.7 "frustum top-open cup Volume = 270.94"
srcheck S_tcone_top "Object 2: valid" "...valid"
srcheck S_tcone_bottom "open (1 face(s) removed), exact B-rep" "frustum with the big (bottom) cap removed is an exact cup"
srcheck S_tcone_bottom "5 faces, 9 edges, closed solid" "...5 faces, closed solid"
srvol S_tcone_bottom 235.7 238.8 "frustum bottom-open cup Volume = 237.24"
srcheck S_tcone_bottom "Object 2: valid" "...valid"
srcheck S_cone_exactno "(mesh)" "old behaviour reachable: Exact=No gives the mesh shell"
# --- ChamferEdge on the rim of a plain cone / frustum
srcheck C_tcone_bottom "replaced with an exact chamfer (radius 1; exact cone on the cylinder rim" "frustum bottom-rim chamfer is an exact revolved bevel (before: the approximate mesh fallback)"
srcheck C_tcone_bottom "(polysurface)" "...a polysurface"
srcheck C_tcone_bottom "4 faces, 7 edges, closed solid" "...4 faces (cap, bevel cone, wall, top cap), 7 edges, closed solid"
srvol C_tcone_bottom 496 501.5 "frustum r5->r3 h10 with a 1x1 bottom bevel: Volume = 498.95"
srcheck C_tcone_bottom "Object 1: valid" "...Check reports it valid"
srcheck C_tcone_top "replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "frustum top-rim chamfer with Distance2 (wall 1, cap 2) is exact: the two distances are honoured"
srcheck C_tcone_top "4 faces, 7 edges, closed solid" "...4 faces, closed solid"
srvol C_tcone_top 495.4 501.3 "frustum top bevel wall 1 / cap 2: Volume = 498.35"
srcheck C_tcone_top "Object 1: valid" "...valid"
srcheck C_cone_rim "replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "plain cone rim chamfer with Distance2 is exact"
srcheck C_cone_rim "3 faces, 5 edges, closed solid" "...3 faces, closed solid"
srvol C_cone_rim 236.9 239.7 "cone r5 h10 rim bevel wall 1 / cap 2: Volume = 238.28"
srcheck C_cone_rim "Object 1: valid" "...valid"
srcheck C_cone_toobig "cone-rim attempt: a chamfer distance consumes the whole wall or cap" "a cap distance larger than the cap: refused WITH the cone-rim reason in the diagnostic"
srcheck C_cone_toobig "2 faces, 2 edges, closed solid" "...and the cone is left untouched"
if grep -q "^FAIL" <<<"$SROUT"; then echo "FAIL solidsrev script reported an in-script FAIL"; fail=1; fi

# --- SBX: ToSubD on a closed Brep box (sbx_script.txt) -------------------------
# MeshFromSelection's exact path (SubD::FromBrep) used to count every Brep it
# accepted as "verified" with worst deviation 0.000000 WITHOUT measuring, and
# FromBrep creases only naked edges, so a closed box became a 6-face cage with
# 0 creases whose Catmull-Clark limit surface is a rounded blob (ToNURBS
# volume 327.1 instead of 1000). The sharp Brep edges (dihedral > 35 degrees)
# are now creased and the limit surface is measured against the Brep.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SBX_OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/sbx_script.txt" 2>&1)" || { echo "$SBX_OUT"; echo "FAIL: sbx script exited non-zero"; exit 1; }
else
  SBX_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/sbx_script.txt" 2>&1)" || { echo "$SBX_OUT"; echo "FAIL: sbx script exited non-zero"; exit 1; }
fi
sbxcheck() { if grep -q -- "$1" <<<"$SBX_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$SBX_OUT" "$1"; fail=1; fi; }
# The first ToSubD line is the box's, the last is the sphere's (negative control).
SBX_BOX_LINE="$(grep -m1 "^history: ToSubD: created" <<<"$SBX_OUT" || true)"
SBX_SPH_LINE="$(grep "^history: ToSubD: created" <<<"$SBX_OUT" | tail -n 1 || true)"
SBX_BOX_VERIFIED="$(grep -o "([0-9]* of 1 limit-surface-fidelity" <<<"$SBX_BOX_LINE" | grep -o "[0-9]*" | head -n 1 || true)"
SBX_BOX_DEV="$(grep -o "worst measured deviation [0-9.]*" <<<"$SBX_BOX_LINE" | grep -o "[0-9.]*$" || true)"
# (1) the printed fidelity claim is consistent with the measured number: "1 of 1"
# only when the deviation is within the printed 0.001 tolerance, "0 of 1" otherwise.
if [ -n "$SBX_BOX_DEV" ] && [ -n "$SBX_BOX_VERIFIED" ] && awk -v d="$SBX_BOX_DEV" -v v="$SBX_BOX_VERIFIED" 'BEGIN{exit !((v==1 && d<=0.001) || (v==0 && d>0.001))}'; then
  echo "ok   sbx: the box's printed fidelity claim ($SBX_BOX_VERIFIED of 1, deviation $SBX_BOX_DEV) is consistent with the measured deviation vs tolerance 0.001"
else
  echo "FAIL sbx: the box's fidelity line is inconsistent or unparseable: $SBX_BOX_LINE"; fail=1
fi
sbxcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); exact Brep-face cage (no tessellation), 12 sharp edge(s) creased (dihedral above 35 degrees), deviation measured at [1-9][0-9]* exact limit-surface points" "ToSubD on a 10x10x10 Brep box reports 1 of 1 verified from MEASURED limit-surface samples (not an unconditional claim), within 0.001, with 12 sharp edges creased"
# (2) crease count: the cage's 12 box edges are creases (was 0 creases).
sbxcheck "6 faces, 12 edges, 8 vertices, 12 creases" "the box's SubD cage has 12 creases (was 0)"
sbxcheck "Crease edges: 12" "What reports the box SubD's 12 crease edges"
# (3) the limit surface, converted to a NURBS solid, is a box again: volume 1000
# (measured 1000.0; asserted 995..1005 - tessellation-derived numbers differ
# slightly across platforms). With the old uncreased cage this was 327.1.
sbxcheck "closed solid: yes, manifold" "ToNURBS of the creased box SubD is a closed manifold solid"
SBX_VOL="$(grep -o "Volume = [0-9.e+-]*" <<<"$SBX_OUT" | head -n 1 | awk '{print $3}' || true)"
if [ -n "$SBX_VOL" ] && awk -v a="$SBX_VOL" 'BEGIN{exit !(a>995 && a<1005)}'; then echo "ok   sbx: ToNURBS of the converted 10x10x10 box encloses $SBX_VOL (true 1000, asserted 995..1005; the uncreased cage gave 327.1)"; else echo "FAIL sbx: ToNURBS volume of the converted box is '$SBX_VOL' (expected 995..1005)"; fail=1; fi
SBX_NVOL="$(grep -c "Volume = " <<<"$SBX_OUT" || true)"
if [ "$SBX_NVOL" = "1" ]; then echo "ok   sbx: exactly one Volume line was printed (the NURBS solid's)"; else echo "FAIL sbx: expected exactly one Volume line, got $SBX_NVOL"; fail=1; fi
# (4) negative control: a smooth shape keeps its existing tessellate-and-verify figure.
if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); cage interpolated onto the Brep surface (limit surface passes through every cage vertex: [0-9]* iteration(s), residual 0\.0000[0-9]*), 0 feature edge(s) creased" <<<"$SBX_SPH_LINE" && ! grep -q "exact Brep-face cage" <<<"$SBX_SPH_LINE"; then echo "ok   sbx: Sphere ToSubD still reports its tessellate-and-verify figure (1 of 1, 0.000x, 0 feature edges) and does not take the exact-cage path"; else echo "FAIL sbx: Sphere ToSubD line changed: $SBX_SPH_LINE"; fail=1; fi
sbxcheck "18240 faces, 27360 edges, 9122 vertices, 0 creases" "the Sphere SubD is still the 96 x 96 grid cage with 0 creases"

exit $fail
