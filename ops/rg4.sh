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
HERE=/home/user/miniature-pancake/dino8-app/tests
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
# measured through the real app (see subd_parity_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SPAR="$(timeout 900 "$BIN" --smoke 300 --script "$HERE/subd_parity_script.txt" 2>&1)" || { echo "$SPAR"; echo "FAIL: subd parity script exited non-zero"; exit 1; }
else
  SPAR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 300 --script "$HERE/subd_parity_script.txt" 2>&1)" || { echo "$SPAR"; echo "FAIL: subd parity script exited non-zero"; exit 1; }
fi
sparcheck() { if grep -q -- "$1" <<<"$SPAR"; then echo "ok   $2"; else echo "FAIL $2"; near "$SPAR" "$1"; fail=1; fi; }
# (1) ToNURBS: closed SubD -> closed polysurface (was: 240 faces, open, Volume refused)
sparcheck "ToNURBS: watertight conversion of a 6-face SubD (3 Catmull-Clark refinement round(s) first): 384 bicubic patches (360 exact limit patches, 24 Coons patches on the shared edge curves; 744 exact + 24 Hermite edge curves), joined 768 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes, manifold; max distance of 3456 patch samples from the Subdivide(+2) limit reference 0\.00[0-9]*" "ToNURBS turns SubDBox into 384 bicubic patches (360 exact + 24 Coons) joined at 1e-6 into a closed manifold solid with 0 naked edges, within 0.01 of the limit surface"
sparcheck "384 faces, 1536 edges, closed solid" "the ToNURBS result of SubDBox lists as a closed solid (before: 240 faces, open)"
sparcheck "ToNURBS: watertight conversion of a 48-face SubD (3 Catmull-Clark refinement round(s) first): 2304 bicubic patches (2016 exact limit patches, 288 Coons patches on the shared edge curves; 4320 exact + 288 Hermite edge curves), joined 4608 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes, manifold" "ToNURBS closes the triangulated-cage SubD sphere (almost every vertex extraordinary) into a closed manifold solid with 0 naked edges (before: 2304 faces, open)"
sparcheck "2304 faces, 9216 edges, closed solid" "the ToNURBS result of the SubD sphere lists as a closed solid"
sparcheck "384 bicubic patches (312 exact limit patches, 72 Coons patches on the shared edge curves; 696 exact + 72 Hermite edge curves), joined 768 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes" "ToNURBS of a box with 4 creased edges is also a closed solid (crease chains are shared exact cubic B-spline curves: 696 exact edge curves)"
# (2) Brep -> SubD
sparcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); cage interpolated onto the Brep surface (limit surface passes through every cage vertex: [0-9]* iteration(s), residual 0\.0000[0-9]*), 0 feature edge(s) creased" "ToSubD on a Brep sphere VERIFIES: measured limit-surface deviation < 0.001 (before: 0 of 1 verified, 0.0202) with the cage interpolated onto the surface"
sparcheck "18240 faces, 27360 edges, 9122 vertices, 0 creases" "the verified sphere SubD is the 96 x 96 grid cage (Euler 9122 - 27360 + 18240 = 2)"
sparcheck "512 feature edge(s) creased" "ToSubD on a cylinder creases its 512 rim edges (two 256-segment circles) instead of rounding them off"
sparcheck "11894 faces, 17841 edges, 5949 vertices, 512 creases" "the cylinder SubD carries the 512 rim creases (before: 0 creases)"
sparcheck "ToSubD: created 1 object(s) (0 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.02[0-9]*)" "the cylinder (trimmed planar caps the grid tessellation cannot weld) still falls back to the mesher cage and honestly reports it is NOT verified (0.02x)"
# (3) SubD booleans on the limit surfaces
sparcheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), 815 face(s), 158 crease edge(s) (158 on the cut seam, 0 along operand creases, 0 sharp-angle); cage interpolated onto the Boolean surface" "BooleanUnion of two overlapping SubD boxes: 815 faces, the 158 edges of the cut seam are creases"
sparcheck "BooleanDifference: SubD boolean (operands refined to their limit surfaces, seam creased), 640 face(s), 160 crease edge(s) (160 on the cut seam" "BooleanDifference: 640 faces, 160 seam creases"
sparcheck "BooleanIntersection: SubD boolean (operands refined to their limit surfaces, seam creased), 462 face(s), 159 crease edge(s) (159 on the cut seam" "BooleanIntersection: 462 faces, 159 seam creases"
sparcheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), [0-9]* face(s), 64 crease edge(s) (0 on the cut seam, 64 along operand creases" "a creased operand's 8 crease edges survive the union (64 crease edges along operand creases after 3 refinement rounds)"
sparcheck "Crease edges: 158" "the union SubD reports its 158 crease edges in What"
# volumes in script order: ToNURBS x3, ToSubD x2, union, difference, intersection, Reflect, Weld=No
mapfile -t SPAR_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SPAR" | awk '{print $3}')
if [ "${#SPAR_VOLS[@]}" -ge 10 ]; then
  echo "ok   subd parity script printed ${#SPAR_VOLS[@]} volumes"
  # The two boxes are translates of each other, so |A union B| = |A-B| + |A intersect B| + |B-A| = 2|A-B| + |A intersect B|.
  SPAR_RES="$(awk -v u="${SPAR_VOLS[5]}" -v d="${SPAR_VOLS[6]}" -v i="${SPAR_VOLS[7]}" 'BEGIN{r=u-(2*d+i); if(r<0) r=-r; printf "%.4f", r}')"
  if awk -v r="$SPAR_RES" 'BEGIN{exit !(r<0.05)}'; then echo "ok   SubD booleans are mutually consistent: union ${SPAR_VOLS[5]} = 2 x difference ${SPAR_VOLS[6]} + intersection ${SPAR_VOLS[7]} (residual $SPAR_RES < 0.05)"; else echo "FAIL SubD boolean volumes inconsistent: union ${SPAR_VOLS[5]}, difference ${SPAR_VOLS[6]}, intersection ${SPAR_VOLS[7]} (residual $SPAR_RES)"; fail=1; fi
  if awk -v a="${SPAR_VOLS[0]}" 'BEGIN{exit !(a>300 && a<340)}'; then echo "ok   ToNURBS SubDBox volume ${SPAR_VOLS[0]} (a smooth cube blob, in 300..340)"; else echo "FAIL ToNURBS SubDBox volume ${SPAR_VOLS[0]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[3]}" 'BEGIN{exit !(a>523 && a<525)}'; then echo "ok   verified sphere SubD encloses ${SPAR_VOLS[3]} (true sphere 523.6)"; else echo "FAIL sphere SubD volume ${SPAR_VOLS[3]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[8]}" 'BEGIN{exit !(a>1999 && a<2001)}'; then echo "ok   Reflect of a closed SubD box across its far face has volume ${SPAR_VOLS[8]} (two boxes, one body)"; else echo "FAIL Reflect volume ${SPAR_VOLS[8]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[9]}" 'BEGIN{exit !(a>999 && a<1001)}'; then echo "ok   Symmetry Weld=No mirror copy has positive volume ${SPAR_VOLS[9]} (outward winding)"; else echo "FAIL Weld=No mirrored copy volume ${SPAR_VOLS[9]}"; fail=1; fi
else
  echo "FAIL subd parity script printed only ${#SPAR_VOLS[@]} volumes (expected 10)"; fail=1
fi
# (4) symmetry
sparcheck "Symmetry: 1 live radial copy created (1 welded into one SubD with creases kept \[128 faces, 32 crease edges\])" "Symmetry Mode=Radial Count=4 welds a 32-face triangulated sector into one 128-face SubD"
sparcheck "Bounding box: (290, -10, 0) to (310, 10, 0)" "the radial SubD spans the full 20 x 20 about the axis through (300, 0)"
sparcheck "Symmetry: 1 live two-plane copy created (1 welded into one SubD with creases kept \[128 faces, 32 crease edges\])" "Symmetry Mode=TwoPlane mirrors the sector across two perpendicular planes into one 128-face SubD"
sparcheck "Bounding box: (390, -10, 0) to (410, 10, 0)" "the two-plane SubD spans the full 20 x 20"
sparcheck "Reflect: mirrored across the plane through 510,0,0 and welded original . mirror image into one symmetric SubD (10 faces)" "Reflect of a closed SubD box across its own far-face plane drops the shared wall: 10 faces"
sparcheck "10 faces, 20 edges, 12 vertices, 0 creases" "the reflected box is one closed body (Euler 12 - 20 + 10 = 2)"
sparcheck "Crease edges: 8" "Reflect mirrors the 4 creased edges of the source onto the other half (4 + 4 = 8 crease edges)"
sparcheck "Symmetry: 1 live mirrored copy created (1 welded into one SubD with creases kept \[64 faces, 32 crease edges\])" "Symmetry on a SubD plane welds source + mirror into one 64-face SubD by default"
sparcheck "Bounding box: (785, 0, 0) to (815, 10, 0)" "the live symmetric copy first spans the source plus its mirror about x = 800"
sparcheck "Bounding box: (775, 0, 0) to (825, 10, 0)" "after the source is MOVED +10 the live symmetric copy re-derived itself and now spans (775 .. 825) - a live link, rebuilt from the changed cage"
sparcheck "Bounding box: (730.608[0-9]*, 0.60763[0-9]*, 0.60763[0-9]*) to (739.39[0-9]*, 9.3923[0-9]*, 9.3923[0-9]*)" "Symmetry Weld=No gives a separate mirror copy on the other side of the plane (x 730.6 .. 739.4)"
sparcheck "gl_error=0" "subd parity script ran without OpenGL errors"
sparcheck "smoke: frames=[0-9]* objects=24" "subd parity script produced the expected object count"

# ---------------------------------------------------------------------------
# SX: exact curved-solid QC (solidsx_script.txt) - the audit/closure of the
# "Solid editing with B-rep results (booleans, fillet, shell, offset)" bullet:
# Boolean of curved solids (General engine, sewn closed and cross-checked
# against the mesh boolean), exact Shell/OffsetSrf/Pipe(closed rail) and the
# exact torus fillet of a plain cylinder's rim. Every case is bracketed by an
# SXBEGIN_<name> marker; sxblock slices the app output into that case.
# Volumes are read from the display mesh (chord 0.005), so the ranges below
# carry that tessellation error (up to ~1% on a torus, ~3% on a thin pipe).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SXOUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/solidsx_script.txt" 2>&1)" || { echo "$SXOUT"; echo "FAIL: solidsx script exited non-zero"; exit 1; }
else
  SXOUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/solidsx_script.txt" 2>&1)" || { echo "$SXOUT"; echo "FAIL: solidsx script exited non-zero"; exit 1; }
fi
sxblock() { awk -v name="$1" '$0 ~ ("Unknown command: SXBEGIN_" name "$") { on = 1; next } on && /Unknown command: SXBEGIN_|Unknown command: SXEND/ { exit } on { print }' <<<"$SXOUT"; }
sxcheck() { local blk; blk="$(sxblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Boolean|Shell|Offset|Pipe|FilletEdge|Object|  [0-9]|Volume|!)" <<<"$blk" | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
# sxvol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
sxvol() {
  local blk v; blk="$(sxblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/')"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- Booleans of curved solids: exact, sewn closed, volume = closed form
sxcheck B_box_minus_cyl "BooleanDifference: exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "box minus a through-hole cylinder is the General engine's result sewn into a closed solid (before: an 'open' polysurface that Volume refused)"
sxcheck B_box_minus_cyl "(polysurface)" "...and stays a polysurface (not a mesh)"
sxcheck B_box_minus_cyl "faces, [0-9]* edges, closed solid" "...List reports it as a closed solid (before: 188 edges, open)"
sxvol B_box_minus_cyl 873.5 875.5 "box minus a through-hole cylinder: Volume = 1000 - pi*2^2*10 = 874.34 (before: 'Object 3 is not closed', Volume 0)"
sxcheck B_box_minus_cyl "mesh cross-check" "...every accepted exact result prints its independent mesh-boolean cross-check volume"
sxcheck B_box_minus_cyl "Area = " "...and Area works on it"
sxcheck B_box_minus_blind "8 face(s), sewn into a closed solid" "blind hole: exact, closed"
sxvol B_box_minus_blind 936.2 938.2 "blind hole Volume = 1000 - pi*4*5 = 937.17"
sxcheck B_box_plus_boss "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sewn into a closed solid" "boss: exact, closed"
sxvol B_box_plus_boss 1139.5 1143 "cylindrical boss Volume = 1000 + pi*9*5 = 1141.37"
sxcheck B_tube "4 face(s), sewn into a closed solid" "tube (cylinder minus coaxial cylinder): exact, closed"
sxvol B_tube 656 662 "tube Volume = pi*(25-4)*10 = 659.73"
sxcheck B_cyl_stack "5 face(s), sewn into a closed solid" "stacked cylinders union: exact, closed"
sxvol B_cyl_stack 343 347.5 "stacked cylinders Volume = pi*9*10 + pi*4*5 = 345.58"
sxcheck B_cyl_minus_sphere "4 face(s), sewn into a closed solid" "cylinder minus a dome-cutting sphere: exact, closed"
sxvol B_cyl_minus_sphere 649 653.5 "dome cut Volume = 250*pi - 2/3*pi*64 = 651.36"
sxcheck B_two_holes_at_once "8 face(s), sewn into a closed solid" "two holes cut in one Boolean (cutters selected together): exact, closed"
sxvol B_two_holes_at_once 857.5 860.5 "two holes Volume = 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_small "closed solid" "the same hole at 1/10 size is still exact and closed"
sxvol B_scale_small 0.870 0.880 "1/10-size hole Volume = 1 - pi*0.04*1 = 0.8743"
# --- Declined with a reason; the result is a closed mesh (never an open polysurface)
sxcheck B_sphere_plus_box "exact B-rep boolean declined (the sewn result does not tessellate to a closed mesh); using the mesh boolean, so the result is a mesh" "box + sphere: declined WITH the reason (the sphere's pole does not weld watertight), mesh boolean used"
sxcheck B_sphere_plus_box "(mesh)" "...and the result is a mesh"
sxvol B_sphere_plus_box 1130 1136 "box + sphere mesh result is a closed solid with Volume = 1000 + 2/3*pi*64 = 1134.04"
sxcheck B_cyl_offaxis "exact B-rep boolean declined (dino8::kernel::BooleanCombineGeneral: an edge is claimed by 3 or more fragment loops" "off-axis cylinder union: the engine's own refusal is printed as the reason"
sxcheck B_chain "exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a second SEQUENTIAL hole in an already-sewn result is declined with the reason (cut both holes in one Boolean, above, to stay exact)"
sxvol B_chain 857 861 "...and the mesh fallback still gives the right volume 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_large "exact B-rep boolean declined" "100x-size hole: declined with a reason (the engine's absolute 1e-3 refinement leaves gaps the closed-mesh check rejects)"
sxcheck B_far_from_origin "exact B-rep boolean declined" "a hole 100000 units from the origin: declined with a reason"
sxcheck B_meshalias "MeshBooleanDifference: [0-9]* faces, volume" "old behaviour stays reachable: MeshBooleanDifference always returns the mesh"
exit $fail
