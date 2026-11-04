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
if grep -qF -- "Shell: object 2 - exact B-rep shell not used" <<<"$HPS_H"; then echo "FAIL HPS_shell: curve -> Extrude -> Shell fell back to the mesh construction (it is a right prism, so the exact prism shell must apply)"; fail=1; else echo "ok   HPS_shell: curve -> Extrude -> Shell no longer declines (the extruded rectangle is a right prism: exact B-rep shell, live and on rebuild)"; fi
hps_sh "$HPS_H" 5 1408 5 "HPS_shell: curve -> Extrude -> Shell (exact prism path) volume before the edit"
hps_sb "$HPS_H" 4 "7,0,0,27,20,10" 0.05 "HPS_shell: source curve moved +7 in X: Extrude AND Shell followed (2-deep chain)"
hps_has "$HPS_H" "History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)" "HPS_shell: the chain propagation line names both dependents"
hps_sh "$HPS_H" 6 1408 5 "HPS_shell: ...and the prism-path shell keeps its volume"
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
elif [ "${DINO8_REQUIRE_TUTORIALS:-0}" = "1" ]; then
  # CI sets DINO8_REQUIRE_TUTORIALS=1: a runner without ffmpeg must not silently stop testing the pipeline.
  echo "FAIL TUT_: the tutorial pipeline is required (DINO8_REQUIRE_TUTORIALS=1) but was skipped: needs Linux with ffmpeg, ffprobe and python3"; fail=1
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
# DINO8_REQUIRE_TOUCH=1 (set only by CI) turns every skip below into a FAIL, so a
# runner that lost node / playwright / xvfb-run cannot silently stop testing the PWA.
tch_skip() {
  if [ "${DINO8_REQUIRE_TOUCH:-0}" = "1" ]; then
    echo "FAIL TCH_touch: Dino 8 Touch PWA test is required (DINO8_REQUIRE_TOUCH=1) but was skipped: $1"
    fail=1
  else
    echo "skip TCH_ Dino 8 Touch PWA test ($1)"
  fi
}
if ! command -v node >/dev/null 2>&1; then
  tch_skip "node is not installed"
elif ! (cd "$HERE/../touch" && node -e "require('playwright')") >/dev/null 2>&1; then
  # Resolved from touch/ (where CI runs npm ci), the same place the test itself requires it from.
  tch_skip "the node 'playwright' package is not installed"
elif ! command -v xvfb-run >/dev/null 2>&1; then
  tch_skip "xvfb-run is not installed"
elif [ ! -f "$TCH_TEST" ]; then
  tch_skip "$TCH_TEST not found"
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
exit $fail
