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
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-a0c10ee7b8bb9e4e5/dino8-app/tests
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
# SubD editing: Crease, ExtrudeSubD, Inset, Bridge, OffsetSubD, RepairSubD, InsertEdge,
# DivideAlongCreases, Fill, AutomaticSubDFromMesh, SubDTruncatedCone, ShrinkWrap (see subd_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SD="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/subd_script.txt" 2>&1)" || { echo "$SD"; echo "FAIL: subd script exited non-zero"; exit 1; }
else
  SD="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/subd_script.txt" 2>&1)" || { echo "$SD"; echo "FAIL: subd script exited non-zero"; exit 1; }
fi
sdcheck() { if echo "$SD" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SD" "$1"; fail=1; fi; }
sdcheck "Crease: 2 edge(s) creased on 1 SubD(s)" "Crease tagged the two picked edges"
sdcheck "Crease edges: 2" "What reports the crease edges on the control net"
sdcheck "ExtrudeSubD: extruded 1 face(s) by 3 on 1 SubD(s), 4 side face(s) added" "ExtrudeSubD extruded the top face with four side faces"
sdcheck "Inset: 1 face(s) inset by 1" "Inset built an inner face and ring"
sdcheck "Bridge: joined 2 faces with a tube of 4 quads, 2 SubDs merged" "Bridge joined the two boxes"
sdcheck "Faces: 22" "the bridged SubD has 22 control faces (6+4+5 for the boxes and tube, plus the inset)"
sdcheck "OffsetSubD: solid shell, distance 1, 1 SubD(s)" "OffsetSubD Solid=Yes built a shell"
sdcheck "44 face(s) (was 44), 0 naked edge(s), 0 non-manifold edge(s), closed" "RepairSubD reports the offset shell closed"
sdcheck "InsertEdge: 4 edge(s) inserted at 0.5 along the ring" "InsertEdge inserted an edge loop around the box"
sdcheck "Crease: 6 edge(s) creased on 1 SubD(s)" "Crease tagged the loop around the split top face"
sdcheck "DivideAlongCreases: 1 SubD(s) divided into 2 piece(s)" "DivideAlongCreases split the box at the crease loop"
sdcheck "Fill: 1 hole(s) filled with a face" "Fill closed the naked loop"
sdcheck "AutomaticSubDFromMesh: SubD with 6 face(s), 12 crease edge(s) sharper than 30 degrees" "AutomaticSubDFromMesh creased the box edges"
sdcheck "SubDTruncatedCone: base radius 5, top radius 2.5, height 10, 32 faces" "SubDTruncatedCone built its control net"
sdcheck "SubDDisplayToggle: 4 SubD(s) show the control polygon" "SubDDisplayToggle switched the closed SubDs to the control polygon"
sdcheck "ShrinkWrap: signed-distance wrap with [0-9]* vertices, [0-9]* faces (closed)" "ShrinkWrap built a closed signed-distance wrap"
sdcheck "Volume = 3[0-9][0-9][0-9] cubic" "ShrinkWrap volume is close to the union of the wrapped solids"
sdcheck "InsertPoint: 1 point(s) inserted on edges" "InsertPoint split an edge on the new box"
sdcheck "Slide: vertex moved" "Slide moved the picked vertex along its best-aligned edge"
sdcheck "SubDSpinEdge: 1 edge(s) spun" "SubDSpinEdge spun the picked edge"
sdcheck "SubDExpandEdges: 2 strip face(s) added, width 1" "SubDExpandEdges added a strip on both sides of the picked edge"
# PackSubDFaces: a real per-face planar-unwrap + shelf-bin-packing UV atlas,
# not just a face count. These checks are programmatic, not "didn't crash":
# the command's own printed UV bounds/overlap-count/coverage are themselves
# computed directly from the packed rectangles (UnwrapFacesLocally/
# ShelfPackFaces in cmd_subd.cpp) - "within [0,1]x[0,1]" is a real bounds
# check against every placed corner, "0 overlapping island pair(s)" a real
# brute-force pairwise rectangle-overlap check, and the coverage percentage
# the actual packed-content-area fraction of the unit square, not eyeballed.
sdcheck "PackSubDFaces: object 11: 6 face(s) packed independently (own island each, no adjacent-face grouping) via per-face planar unwrap + shelf bin-packing; UV bounds \[0\.[0-9]*,0\.[0-9]*\]x\[0\.[0-9]*,0\.[0-9]*\] within \[0,1\]x\[0,1\], 0 overlapping island pair(s), coverage 5[0-9]\.[0-9]*%" "PackSubDFaces built a real, non-overlapping, in-bounds UV atlas for a plain SubD box (6 faces) with reasonable (~53%) coverage"
sdcheck "PackSubDFaces: object 12: 48 face(s) packed independently (own island each, no adjacent-face grouping) via per-face planar unwrap + shelf bin-packing; UV bounds \[0\.[0-9]*,0\.[0-9]*\]x\[0\.[0-9]*,0\.[0-9]*\] within \[0,1\]x\[0,1\], 0 overlapping island pair(s), coverage [3-9][0-9]\.[0-9]*%" "PackSubDFaces built a real, non-overlapping, in-bounds UV atlas for a SubD sphere (48 faces) with reasonable (>=30%) coverage"
sdcheck "gl_error=0" "subd script ran without OpenGL errors"
# ToNURBS: a real Catmull-Clark limit-surface-to-bicubic-NURBS conversion
# (kernel::SubD::ToNurbsPatchesAdaptive), not the old flat-facetted dense
# mesh, and not the plain non-adaptive ToNurbsPatches() either - the
# adaptive converter is now wired in (2 extra levels beyond the existing
# whole-mesh pre-refinement), replacing each irregular face's one coarse
# flat patch with several smaller, more accurate ones. The regular-patch
# count on SubDPlane (a mostly-interior-regular quad grid) must be
# genuinely nonzero - that's the real regular-stencil code path actually
# firing, not just "didn't crash" - and the resulting Brep's own face
# count (from List) must match the adaptively-split SubD's own patch
# count, not the original 16/6 control faces a facetted conversion would
# have produced, nor the smaller non-adaptive patch count either.
sdcheck "Converted 1 object(s) (1248 exact, 288 approximated near extraordinary vertices/creases/boundaries)" "ToNURBS on SubDPlane (open surface) produced 1248 exact regular limit patches plus 288 Coons patches on the shared edge curves via the watertight converter (SubD::ToNurbsPatchesWatertight; the earlier adaptive converter gave 1504 exact + 416 flat approximations)"
sdcheck "1536 faces, 6144 edges, open" "ToNURBS's SubDPlane Brep has one real bicubic patch per face of its 3-round refinement (1536); it stays open because the SubDPlane itself is an open sheet (its 128 boundary edges are naked)"
sdcheck "Converted 1 object(s) (360 exact, 24 approximated near extraordinary vertices/creases/boundaries)" "ToNURBS on SubDBox: 360 exact limit patches + 24 Coons patches (the 3 faces around each of the cube corner's valence-3 vertices) - every corner patch now meets its neighbours instead of being a flat bilinear approximation"
sdcheck "384 faces, 1536 edges, closed solid" "ToNURBS's SubDBox Brep is a CLOSED SOLID (384 faces; before this pass the same conversion reported 240 faces, open, and Volume refused it)"
# ToSubD: a Brep -> SubD conversion now tessellates at the document's real
# modeling tolerance (ctx.Settings().absolute_tolerance, default 0.001)
# instead of the display-quality surface_display_tolerance (default 0.05,
# 50x coarser) it used before - a real, documented chord-tolerance fidelity
# bound on the control cage, not "whatever happens to look right on
# screen". The face count below is a real, measured consequence of that
# tighter tolerance actually driving the tessellation, not just "didn't
# crash"; this command had no test coverage at all before this check.
sdcheck "ToSubD: created 1 object(s)" "ToSubD converted the Brep sphere"
sdcheck "18240 faces, 27360 edges, 9122 vertices, 0 creases" "ToSubD's sphere SubD is built on the kernel's 96 x 96 grid tessellation (every vertex on the sphere, no sliver triangles; a real Euler check: 9122 - 27360 + 18240 = 2, a closed surface) instead of the 11310-face chord-tolerance mesh whose long triangles sagged up to 0.09 off the sphere"
# ToSubD limit-surface fidelity: BuildSubDVerifiedAgainstBrep (cmd_solids.cpp)
# now measures the resulting SubD's own true Catmull-Clark LIMIT surface
# against the original Brep - not just the control cage's own tessellation
# tolerance, which is all the two checks above cover - and reports a real,
# measured bound instead of no guarantee at all. The sphere's cage is almost
# entirely extraordinary vertices (every original triangle corner), and its
# own tessellation is already at the mesher's per-edge subdivision cap, so
# retightening can't shrink it further; the exact deviation below is this
# check's own honestly-disclosed, unconverged measurement, not a success
# silently claimed. The measured number is the worst of a bounded sample of
# limit-surface patch midpoints chosen by position (lexicographic x/y/z
# order), not by patch storage index: the cage's face order is whatever
# the Brep mesher's Delaunay refinement emitted, which differs between
# GCC and MSVC for this very same 11310-face cage (the index-strided
# sample used to report 0.016850 here and 0.023475 on Windows CI; merely
# reversing the face order on Linux moved it to 0.017945), so the
# position-sorted sample is what makes this one number comparable across
# platforms at all.
sdcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); cage interpolated onto the Brep surface (limit surface passes through every cage vertex: [0-9]* iteration(s), residual 0\.0000[0-9]*), 0 feature edge(s) creased" "ToSubD on the Brep sphere now VERIFIES (before: 0 of 1, worst measured deviation 0.0202): the measured limit-surface deviation from a 384 x 384 reference of the sphere is under the 0.001 tolerance, with the cage interpolated onto the surface"
# The opposite, provable case: a flat planar patch's control points are all
# already coplanar, so Catmull-Clark's own limit-point formula (an affine
# combination of coplanar points) introduces no deviation regardless of
# valence - this must fully verify on the very first round, proving the
# "verified" branch of the same check genuinely fires, not only the
# "honest miss" branch above.
sdcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0.000000)" "ToSubD on a flat planar patch fully verifies its limit surface against the original Brep within tolerance"
# ToSubD exact path: SubD::FromBrep (dino8-kernel) now runs first for a
# Brep whose every face is already an untrimmed, planar, axis-aligned-
# in-own-uv quad (PlanarSrf's trimmed rectangle above, and the Sphere's
# curved faces, both correctly fall through to the tessellate-and-verify
# path unchanged - confirmed by the two checks just above still matching
# byte for byte). Confirmed directly against the pre-this-change binary
# that a Box was previously a genuine MISS here too (0 of 1 verified,
# deviation ~0.8, a 24-face triangulated-then-recombined cage) - the
# same honest-miss failure mode the Sphere check above discloses, not
# merely a missing optimization. The exact path must now report full
# verification at exactly 0 deviation, with the natural, clean 6-face
# control cage a Box's own 6 flat faces should give, not a triangulated
# approximation of it.
sdcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); exact Brep-face cage (no tessellation), 12 sharp edge(s) creased" "ToSubD on a Box verifies within tolerance by a MEASURED limit-surface deviation (the exact path used to claim 'verified, 0.000000' without measuring; it is now measured against the Brep, with the box's 12 sharp edges creased)"
sdcheck "6 faces, 12 edges, 8 vertices, 12 creases" "ToSubD on a Box takes the exact SubD::FromBrep path: the natural 6-face cube cage, not a triangulated-then-recombined approximation of it, with its 12 sharp edges creased so the limit surface stays a box (was '0 creases', a rounded blob; unique among this script's own SubD List outputs - the Sphere gives 11310/16965/5657, the PlanarSrf rectangle gives 6/13/8/8)"
# SubDRevolve/SubDMultiPipe: the SubD menu (MenuBar.cpp) has always listed
# both names, with no command of either name ever registered - a broken
# menu entry, not an implemented-but-limited feature (PARITY_MAP.md's own
# "SubD-result revolve and multi-pipe menu entries are broken references"
# item). Both now run the real underlying command (Revolve / MultiPipe) and
# convert its result to a genuine SubD via the same SweepThenSubDCommand
# wrapper SubDSweep1/SubDSweep2 already use and this suite already covers.
sdcheck "SubDRevolve: 1 object(s) converted to SubD" "SubDRevolve ran the real Revolve command on the selected circle and converted its resulting surface to a SubD"
sdcheck "SubDMultiPipe: 1 object(s) converted to SubD" "SubDMultiPipe ran the real MultiPipe command on the two selected lines and converted its resulting (unioned) mesh to a SubD"
# Revolve Output=SubD: the plain Revolve command's own documented "Output"
# option, not the separate SubDRevolve command above - PARITY_MAP.md's own
# "ExtrudeCrv / Revolve producing a SubD object directly" item, narrowed to
# its Revolve half. Converts via the same ConvertObjectToSubD helper
# SubDRevolve/SubDMultiPipe above were refactored to share (cmd_common.h).
# The id of the resulting SubD is NOT 25 - @expect_objects below counts
# live objects, but ConvertObjectToSubD deletes the transient Brep and adds
# a new, higher-numbered object, so ids keep climbing past the live count
# even as some are deleted along the way (same reason SubDRevolve/
# SubDMultiPipe above land on ids 20/28, not the running live count either).
# The bounding box is checked instead - exact, deterministic from the
# Circle/axis above, and independent of any upstream id shift. On its own
# this doesn't prove the object is a SubD rather than a leftover Brep, so
# it's paired with the exact "Faces:.../Edges:.../Crease edges:" shape only
# SceneObject::Describe()'s own ObjectKind::SubD branch ever prints.
sdcheck "Faces: 10[0-9][0-9][0-9]" "Revolve Output=SubD's List shows a real SubD-shaped description (Faces/Vertices/Edges/Crease edges - a Brep's own Describe() branch prints only a bare Faces count), not a leftover Brep"
sdcheck "Bounding box: (495, -5, -24\.99[0-9]*) to (544\.99[0-9]*, 5, 24\.99[0-9]*)" "Revolve Output=SubD built its usual Brep of revolution (profile circle radius 5 at x=500, axis at x=520), then converted it in place to a genuine SubD with the same real extent"
echo "$SD" | grep -E "^(ok|FAIL)"
if echo "$SD" | grep -q "^FAIL"; then fail=1; fi
sdcheck "smoke: frames=[0-9]* objects=27" "subd script produced the expected object count"
# SubD parity (app_subd_mesh): ToNURBS closes a SubD into a watertight solid,
# ToSubD verifies a smooth Brep and creases feature edges, SubD booleans work
# on the operands' limit surfaces with a creased cut, and SubD symmetry
# (radial / two-plane / welded live copy / crease-preserving Reflect) - all
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
sparcheck "64 feature edge(s) creased" "ToSubD on a cylinder creases its 64 rim edges (two 32-segment circles) instead of rounding them off (before: 512 rim edges of the 256-segment mesher cage)"
sparcheck "352 faces, 704 edges, 354 vertices, 64 creases" "the cylinder SubD is the analytic 352-face cage (32 x 5 wall + two 64-face O-grid caps, Euler 354 - 704 + 352 = 2) with the 64 rim creases (before: 11894 faces, 512 creases)"
sparcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); analytic revolved-solid cage (32 segments around x 5 along the wall" "the cylinder (trimmed planar caps the grid tessellation cannot weld) is now built as an analytic wall + cap cage and VERIFIED, deviation measured against the exact surface (before: 0 of 1 verified, 0.02x)"
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
sxcheck B_sphere_plus_box "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "box + sphere is now an exact B-rep (before: declined 'the sewn result does not tessellate to a closed mesh' because the display mesh's keyhole-corridor gaps were only closeable by a weld that also fused the sphere's pole fan; the mesher now re-welds only boundary vertices)"
sxcheck B_sphere_plus_box "(polysurface)" "...and the result is a polysurface, not a mesh"
sxvol B_sphere_plus_box 1130 1136 "box + sphere exact result is a closed solid with Volume = 1000 + 2/3*pi*64 = 1134.04"
sxcheck B_cyl_offaxis "exact B-rep boolean declined (dino8::kernel::BooleanCombineGeneral: an edge is claimed by 3 or more fragment loops" "off-axis cylinder union: the engine's own refusal is printed as the reason"
sxcheck B_chain "re-evaluated from the recorded original operands (the base and 2 tool(s) in one pass" "a second SEQUENTIAL hole is now exact (before: declined 'gaps between faces that sewing could not close'): re-evaluated as base minus both cutters in one pass"
sxcheck B_chain "(polysurface)" "...and the result is a polysurface, not a mesh"
sxvol B_chain 857 861 "...and its Volume is 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_large "7 face(s), sewn into a closed solid" "100x-size hole is now exact and closed (before: declined 'exact B-rep boolean declined' because the uniform re-weld could not close the display mesh; the boundary-only re-weld does)"
sxvol B_scale_large 870000000 879000000 "100x-size hole Volume = 1e9 - pi*200^2*1000 = 874336294"
sxcheck B_far_from_origin "exact B-rep boolean declined" "a hole 100000 units from the origin: declined with a reason"
sxcheck B_meshalias "MeshBooleanDifference: [0-9]* faces, volume" "old behaviour stays reachable: MeshBooleanDifference always returns the mesh"
sxcheck B_then_shell "Shell: thickness 0.5, closed, [A-Za-z, -]*volume" "Shell of the sewn Boolean result now works (before: 'Object 3 is not a closed solid; skipped'; exact B-rep since HSO_, so the 'exact B-rep, ' words are optional here)"
sxcheck B_then_shell "Shell: thickness 0.5, closed, exact B-rep, volume" "...and that shell is now an exact B-rep (prism-with-hole construction, HSO_; before: 'exact B-rep shell not used (' with the reason, a mesh)"
# --- Shell
sxcheck S_box_closed "Shell: thickness 1, closed, exact B-rep, volume 488" "control: closed box shell is exact (1000 - 8^3)"
sxcheck S_box_open "Shell: thickness 1, open (1 face(s) removed), exact B-rep, volume 424" "box with the top face removed is now an exact B-rep (kernel ShellConvexPlanar with removed_faces; before: a mesh)"
sxcheck S_box_open "(polysurface)" "...a polysurface"
sxcheck S_box_open "14 faces, 28 edges, closed solid" "...14 faces (5 outer + 5 inner + 4 rim) and 28 edges, a closed solid"
sxcheck S_box_perface "1 face(s) at their own thickness, closed, exact B-rep, volume 616" "per-face thickness (top 3, others 1) is exact: 1000 - 8*8*6 = 616 (before: a mesh)"
sxcheck S_box_exactno "Shell: thickness 1, closed, volume 488" "old behaviour reachable: Exact=No gives the mesh construction"
sxcheck S_box_exactno "(mesh)" "...a mesh"
sxcheck S_sphere "Shell: thickness 1, closed, exact B-rep" "whole sphere shell is exact (concentric reversed inner sphere)"
sxcheck S_sphere "2 faces, 2 edges, closed solid" "...2 faces, closed solid"
sxvol S_sphere 253.5 256.5 "sphere shell Volume = 4/3*pi*(125-64) = 255.5"
sxcheck S_torus "Shell: thickness 1, closed, exact B-rep" "whole torus shell is exact"
sxvol S_torus 970 990 "torus shell Volume = 2*pi^2*10*(9-4) = 986.96 (display mesh reads low on a torus)"
sxcheck S_cyl_closed "Shell: thickness 1, closed, exact B-rep" "plain cylinder closed hollow shell is exact (before: a 14208-triangle mesh)"
sxcheck S_cyl_closed "6 faces, 6 edges, closed solid" "...6 faces (outer 3 + inner 3), closed solid"
sxvol S_cyl_closed 381 385 "hollow cylinder Volume = pi*(250-128) = 383.27"
sxcheck S_cyl_open "open (1 face(s) removed), exact B-rep" "cylinder with the top cap removed is an exact cup (before: a mesh)"
sxcheck S_cyl_open "5 faces, 9 edges, closed solid" "...5 faces (outer wall, base disc, inner wall, floor, rim annulus), closed solid"
sxvol S_cyl_open 331 335 "cup Volume = pi*(250-16*9) = 333.01"
sxcheck S_cyl_open_bottom "open (1 face(s) removed), exact B-rep" "removing the bottom cap works too"
sxcheck S_L_nonconvex "Shell: thickness 1, closed, exact B-rep, volume 1056" "non-convex L-shaped extrusion is now an exact B-rep shell (right-prism construction; before: 'exact B-rep shell not used', mesh): 8*300 - 6*224 = 1056"
sxvol S_L_nonconvex 1050 1062 "...and its measured Volume agrees"
# --- OffsetSrf
sxcheck O_sphere "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "sphere offset is exact (before: a 4700-triangle mesh)"
sxcheck O_sphere "1 faces, 1 edges, closed solid" "...one closed spherical face"
sxvol O_sphere 902 906 "offset sphere Volume = 4/3*pi*216 = 904.78"
sxcheck O_torus "1 exact B-rep" "torus offset is exact"
sxvol O_torus 3110 3170 "offset torus Volume = 2*pi^2*10*16 = 3158.3 (display mesh)"
sxcheck O_cyl "3 faces, 3 edges, closed solid" "plain cylinder offset is an exact 3-face cylinder"
sxvol O_cyl 1353 1359 "offset cylinder Volume = pi*36*12 = 1357.17"
sxcheck O_box_solid "OffsetSrf: distance 1, 1 object(s), solid, 1 exact B-rep" "Solid=Yes on a box is exact (before: a mesh)"
sxcheck O_box_solid "(polysurface)" "...a polysurface"
sxvol O_box_solid 727.5 728.5 "box Solid=Yes Volume = 12^3 - 10^3 = 728"
sxcheck O_sphere_solid "solid, 1 exact B-rep" "sphere Solid=Yes is exact"
sxvol O_sphere_solid 379 383 "sphere Solid=Yes Volume = 4/3*pi*(216-125) = 381.2"
sxcheck O_sphere_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
sxcheck O_L_nonconvex "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "non-convex L extrusion offset is now exact (right-prism construction; before: 'exact B-rep offset not used', mesh)"
sxvol O_L_nonconvex 3830 3850 "...Volume = (20+2)*(10+2)... = 384*10 = 3840 (profile area 300 + 80 + 4 = 384, height 8 + 2)"
# --- Pipe on a closed rail
sxcheck P_closed "Pipe: radius 1, 1 pipe(s) (exact closed B-rep tube)" "Pipe on a closed circular rail is the kernel's exact closed tube (before: a 1152-triangle mesh)"
sxcheck P_closed "(polysurface)" "...a polysurface"
sxcheck P_closed "closed solid" "...a closed solid"
sxvol P_closed 186 200 "closed-rail pipe Volume ~ 2*pi^2*10*1 = 197.39 (display mesh; the Torus primitive reads 191.2 under the same mesher)"
# --- Fillet of a plain cylinder's rim
sxcheck F_cyl_top "cylinder rim(s) of object 1 replaced with an exact fillet (top radius 1; exact quarter-torus patch, 4 faces, closed solid)" "cylinder top-rim fillet is an exact quarter torus (before: a mesh whose volume INCREASED to 1594)"
sxcheck F_cyl_top "4 faces, 7 edges, closed solid" "...4 faces (wall, torus, 2 discs) and 7 edges, closed solid"
sxvol F_cyl_top 1561 1566 "top-rim fillet Volume = 25*pi*20 - 6.44 = 1564.36 (before 1594)"
sxcheck F_cyl_both "top radius 1, bottom radius 2; exact quarter-torus patches, 5 faces, closed solid" "both rims in one run become one exact solid"
sxvol F_cyl_both 1536 1542 "both-rim fillet Volume = 1539.80"
sxvol F_cyl_bottom 1543 1549 "bottom-rim fillet (radius 2) Volume = 1546.24"
sxcheck F_cyl_exactno "mesh fallback (exact B-rep trim unavailable here" "old behaviour reachable: Exact=No keeps the approximate mesh fillet"
sxcheck F_cyl_toobig "exact cylinder-rim fillet not used (the radius is not smaller than the cylinder radius)" "a radius larger than the cylinder: exact refused with the reason, fallback runs"
sxcheck F_box_control "FilletEdge: edge 10 of object 1 replaced with an exact fillet" "control: a box edge is still the kernel's exact planar fillet"
sxvol F_box_control 990.5 992.3 "box edge fillet Volume = 991.4"
if grep -q "^FAIL" <<<"$SXOUT"; then echo "FAIL solidsx script reported an in-script FAIL"; fail=1; fi

# ---------------------------------------------------------------------------
# Viewport display: per-object display modes + view-dependent adaptive
# tessellation (PARITY_MAP.md "Viewport display, rendering & visualization":
# "Per-object display mode override" and "View-dependent adaptive
# tessellation"). tests/viewport_lod_script.txt runs both against the real
exit $fail
