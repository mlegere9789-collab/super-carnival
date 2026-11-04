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
# Rendering: materials (scripted options), texture mapping, lights, sun, ground plane,
# Render / RenderArctic / SaveRenderWindowAs, ExtractRenderMesh, .3dm round-trip (see render_script.txt).
sed "s|@TMP@|$TMPW|g" "$HERE/render_script.txt" > "$TMPW/render_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RN="$(timeout 900 "$BIN" --smoke 200 --script "$TMPW/render_script.txt" 2>&1)" || { echo "$RN"; echo "FAIL: render script exited non-zero"; exit 1; }
else
  RN="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$TMPW/render_script.txt" 2>&1)" || { echo "$RN"; echo "FAIL: render script exited non-zero"; exit 1; }
fi
rncheck() { if echo "$RN" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RN" "$1"; fail=1; fi; }
rncheck "Created material Plastic" "RenderAssignMaterialToObjects created a material"
rncheck "Material Glass: color=200,225,240 transparency=0.6 reflectivity=0.3 gloss=0.9" "material options were applied"
rncheck "Material Brass assigned to 1 object(s)" "material assigned to the cylinder"
rncheck "Cylindrical mapping applied to 1 object(s), Scale=2" "ApplyCylindricalMapping set the mapping and scale"
rncheck "UVEditor: '(unnamed)' (Cylindrical mapping) UV bounding box: u\[0\.[0-9]*, 2\] v\[0, 2\], [0-9]* triangle(s)" "UVEditor computed a real UV bounding box (ComputeUVWireframeInfo/EnsureMappedUVs) for the cylinder's own cylindrical mapping - u wraps to width Scale=2, v spans height Scale=2, same as the panel would draw"
rncheck "AssignBlankTexture: .*blank_texture.ppm assigned to 1 object(s)" "AssignBlankTexture wrote and assigned a checker texture"
rncheck "SynchronizeRenderColors: 1 material(s)" "SynchronizeRenderColors made a material from the display colour"
rncheck "Point light 1: Point light at 10,-30,40, Intensity=1.5" "PointLight took its point and Intensity option"
rncheck "Spot light 2: Spot light at -30,-30,40, cone angle 7.12" "Spotlight built its cone from base, radius and end"
rncheck "Directional light 3: Directional light direction" "DirectionalLight ran"
rncheck "Sun on: Azimuth=200 Altitude=50" "Sun options applied"
rncheck "GroundPlane on: Height=Automatic Color=150,158,168 Shadows=Yes" "GroundPlane options applied"
rncheck "Environment: background Sky" "Environments switched to the sky background"
rncheck "Render: rendered Perspective at 320 x 240" "Render produced an offscreen image"
rncheck "Saved rendering $TMPW/render.bmp (320 x 240)" "SaveRenderWindowAs wrote the BMP"
rncheck "RenderArctic: rendered Perspective at 1280 x 720" "RenderArctic rendered at the document size"
rncheck "Saved rendering $TMPW/arctic.ppm (1280 x 720)" "SaveRenderWindowAs wrote a PPM"
rncheck "RenderPreview: rendered Perspective" "RenderPreview rendered at viewport size"
rncheck "PolygonCount: [0-9]* triangles in 4 visible object(s)" "PolygonCount counted the display meshes"
rncheck "RenderReportMissingImageFiles: 0 missing image file(s)" "RenderReportMissingImageFiles found every texture"
rncheck "ExtractRenderMesh: 4 mesh(es)" "ExtractRenderMesh added the display meshes"
rncheck "SetSpotlightToView: 1 spotlight(s) moved" "SetSpotlightToView moved the spotlight"
rncheck "Opened $TMPW/render.3dm (8 objects)" "the .3dm with materials and lights re-opened"
rncheck "RenderReportImageFiles: 1 image file(s) referenced" "material textures survived the .3dm round-trip"
rncheck "^history: 3 light(s) selected" "lights survived the .3dm round-trip"
rncheck "Current renderer: Dino 8 built-in renderer" "SetCurrentRenderPlugIn reports the built-in renderer"
rncheck "EditLightByHighlight: selected Point light 1 (nearest the pick, 0 units away)" "EditLightByHighlight picked the nearest light"
rncheck "EditLightByLooking: Perspective now looks through Point light 1" "EditLightByLooking aimed the view through the light"
exit $fail
