# Surfaces: Pipe, OffsetSrf, Shell, Sweep1/2, NetworkSrf, Patch, ExtrudeCrvAlongCrv,
# ExtrudeCrvTapered, Project, Pull (see surface_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SF="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/surface_script.txt" 2>&1)" || { echo "$SF"; echo "FAIL: surface script exited non-zero"; exit 1; }
else
  SF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/surface_script.txt" 2>&1)" || { echo "$SF"; echo "FAIL: surface script exited non-zero"; exit 1; }
fi
sfcheck() { if echo "$SF" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SF" "$1"; fail=1; fi; }
sfcheck "Pipe: radius 1, 1 pipe(s) (exact capped B-rep)" "Pipe on an open rail now calls the kernel's exact Brep::Pipe instead of building a mesh"
sfcheck "Volume = 31.29 cubic" "Pipe r=1 along 10 units has volume ~ pi*10 (closer than the old mesh's 31.06, read from the exact B-rep's own tessellation)"
sfcheck "Area = 62.79 square" "uncapped Pipe surface area ~ 2*pi*10"
sfcheck "degree 3 x 1, CVs 27 x 2" "uncapped Pipe is a periodic NURBS tube"
sfcheck "Bounding box min 20,0,-2 max 30,10,-2" "OffsetSrf moved the plane by 2 along its normal"
sfcheck "Volume = 200 cubic" "OffsetSrf Solid=Yes closed a 10x10x2 slab"
sfcheck "Shell: thickness 1, closed, exact B-rep, volume 1408" "Shell hollowed the box (4000 - 18*18*8) via the kernel's exact ShellConvexPlanar, not the mesh path"
sfcheck "ExtrudeCrvAlongCrv: 1 surface(s)" "ExtrudeCrvAlongCrv built a sum surface"
sfcheck "Sweep1: exact kernel sweep (rotation-minimizing frames)" "Sweep1's single-section case now calls the kernel's exact Brep::Sweep1"
sfcheck "Area = 125.6 square" "Sweep1 area ~ 2*pi*2*10 (kernel's exact NURBS circle reused directly, not a resampled fit)"
sfcheck "Sweep2: exact kernel sweep (two-rail frame transport)" "Sweep2's single-section case now calls the kernel's exact Brep::Sweep2"
sfcheck "NetworkSrf: exact Coons patch through 4 curves (all 4 boundaries reproduced exactly)" "NetworkSrf sorted 4 curves into a loop and built the kernel's exact Coons patch (real NURBS algebra, not the sample-and-refit approximation)"
sfcheck "NetworkSrf: ruled surface between 2 curves" "NetworkSrf ruled two curves"
sfcheck "Patch: planar face bounded by the closed curve" "Patch trimmed a plane with the circle"
sfcheck "Area = 78.51 square" "Patch disc area ~ pi*25"
sfcheck "Patch: least-squares plane through 0 curve(s) and 3 point(s)" "Patch fitted a plane through points"
sfcheck "ExtrudeCrvTapered: distance 5, draft 10 deg, 1 object(s)" "ExtrudeCrvTapered ran"
sfcheck "3 faces, 3 edges, closed solid" "ExtrudeCrvTapered capped and joined into a closed solid (wall + 2 planar trimmed cap faces; the cap loops share the wall seam, so 3 edges, where the old fan caps needed 5)"
sfcheck "Project: 1 curve(s), 0 point(s)" "Project produced one curve"
sfcheck "CV\[1\] 240,20,0" "Project landed the line on the plane"
if [ "$(echo "$SF" | grep -c "CV\[1\] 240,20,0")" -eq 2 ]; then echo "ok   Project with an explicit custom direction (two typed points, +Z) lands on the exact same result as the CPlane-normal default - the real \"no way to choose a direction\" gap this command's own PARITY_MAP bullet named is now closed"; else echo "FAIL Project with an explicit custom direction (two typed points, +Z) lands on the exact same result as the CPlane-normal default"; near "$SF" "CV\[1\] 240,20,0"; fail=1; fi
sfcheck "Pull: 0 curve(s), 1 point(s)" "Pull produced one point"
sfcheck "  225,5,0" "Pull moved the point onto the plane"
# Shell (open): picking the top face before entering thickness removes that
# face's own wall layer from the result rather than producing another
# fully-closed solid - real material gone, not a cosmetic label. The result
# is still a single valid closed 2-manifold (a real opening is a cavity
# reachable through empty space, not a literal hole in the mesh - the same
# reason a 3D-printable mug's own mesh has no naked edges either), so the
# proof is the exact Volume/Area/BoundingBox difference from the closed case
# above, not IsClosedManifold()/SelOpenMesh.
sfcheck "Shell: face 5 on object" "Shell registered the clicked top face to remove"
sfcheck "Shell: thickness 1, open (1 face(s) removed), exact B-rep, volume 1084" "Shell (open) is now the kernel's exact ShellConvexPlanar with the clicked top face removed (a real polysurface, no longer the welded mesh): volume 1408 - 18*18*1 = 1084"
sfcheck "Area = 2248 square" "Shell (open) area matches the outer+inner+rim geometry exactly (all flat, no curvature error)"
sfcheck "Bounding box min 300,0,0 max 320,20,10" "Shell (open) left the outer wall's own bounding box untouched"
sfcheck "Volume = 1084 cubic" "Shell (open) volume is exactly the closed shell's 1408 minus the removed top layer's own 18x18x1"
# Shell (per-face thickness): no face removed, but the top face is given
# its own thickness of 3 while every other face keeps the default 1 - a
# real different-thickness-per-face wall, not just a global number. The
# per-vertex offset solve (OffsetMeshPerFace) makes each kept face's own
# vertices hit the exact intersection of its neighbours' own offset planes,
# so a box's orthogonal faces still meet in clean corners even though two
# of them moved by different amounts; proved numerically by hand below.
sfcheck "Shell: face 5 on object" "Shell registered the clicked top face for its own thickness"
sfcheck "set to thickness 3" "the top face's override was recorded as 3"
sfcheck "Shell: thickness 1, 1 face(s) at their own thickness, closed, exact B-rep, volume 2056" "Shell (per-face) is now one exact B-rep shell (kernel ShellConvexPlanar with a per-face thickness array) with a mixed-thickness wall"
sfcheck "Area = 2680 square" "Shell (per-face) area matches outer 1600 + inner 1080 (two disjoint nested boxes, no boolean rework needed)"
sfcheck "Bounding box min 340,0,0 max 360,20,10" "Shell (per-face) left the outer wall's own bounding box untouched"
sfcheck "Volume = 2056 cubic" "Shell (per-face) volume is exactly 4000 - 18*18*6 (inner box shrunk to height 6 by the top face's own thickness 3, not the default 1) - 648 less material removed than the same box's uniform thickness-1 shell above (1408), i.e. 1408 + 18*18*2 = 2056"
# OffsetSrf on a polysurface (Solid=No): the kernel's exact
# OffsetSolidConvexPlanar now takes this case directly for a convex,
# all-planar-faced solid - a real polysurface result, not a tessellated
# mesh, closing PARITY_MAP.md's own "OffsetSrf on polysurfaces gives
# meshes" gap for this common case. OffsetSrf keeps the original box as
# its own separate object (same as it already does for a plain
# Surface), so List on the new result alone (SelLast) is what proves
# the kind, not SelPolysrf (which would also catch the untouched
# original box).
sfcheck "6 faces, 12 edges, closed solid" "OffsetSrf on a polysurface (Solid=No) produced a real polysurface - the kernel's exact OffsetSolidConvexPlanar, not the mesh-offset fallback"
sfcheck "Volume = 5808 cubic" "OffsetSrf on a polysurface (Solid=No) grew a 20x20x10 box by 1 on every face via the kernel's exact OffsetSolidConvexPlanar, giving the exact closed-form volume of a 22x22x12 box"
sfcheck "Bounding box min 439,-1,-1 max 461,21,11" "OffsetSrf on a polysurface moved every one of the box's own 6 planar faces outward by exactly 1, not an approximate vertex-normal mesh offset"
sfcheck "smoke: frames=200 objects=50" "surface script produced the expected object count"
# Solids: Ellipsoid/SubDEllipsoid (real axis picking), Pyramid (NumSides=),
# Loft (Normal vs Style=Straight), Cap (multiple separate openings) (see solids_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SO="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/solids_script.txt" 2>&1)" || { echo "$SO"; echo "FAIL: solids script exited non-zero"; exit 1; }
else
  SO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/solids_script.txt" 2>&1)" || { echo "$SO"; echo "FAIL: solids script exited non-zero"; exit 1; }
fi
socheck() { if echo "$SO" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SO" "$1"; fail=1; fi; }
socheck "Volume = 132 cubic" "Ellipsoid volume is close to the analytic 4/3*pi*5*3*2 (~125.7)"
socheck "48 faces, 72 edges, 26 vertices, 0 creases" "SubDEllipsoid built a SubD from the same three axes"
socheck "7 vertices, 10 faces" "Pyramid NumSides=6 built a 7-vertex hexagonal-base mesh"
socheck "degree 1 x 2, CVs 2 x 3" "Loft (Normal) of three straight lines is the exact interpolating kernel loft: degree 1 along the lines (the old 24 x 3 control-point fit was cubic along them), degree 2 (sections - 1) through the 3 sections"
socheck "degree 1 x 1, CVs 2 x 3" "Loft Style=Straight keeps degree 1 in the loft direction (a ruled loft with a sharp edge at the middle section)"
socheck "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.e+-]*" "Loft (Normal) prints that it is the exact interpolating kernel loft and the measured section deviation"
socheck "Loft: exact interpolating kernel loft through 3 curves (degree 1 in the loft direction); every section reproduced" "Loft Style=Straight prints that it is the exact kernel loft at degree 1 in the loft direction"
socheck "4 faces, 12 edges, open" "DeleteFaces removed the box's top and bottom (two separate naked-edge loops)"
socheck "Capped 1 object(s), 2 opening(s)" "Cap closed both separate openings in one call"
socheck "6 faces, 76 edges, open" "Cap added both cap faces back (4 sides + 2 caps)"
socheck "Volume = 17[4-6][0-9] cubic" "Torus volume is close to the analytic 2*pi^2*10*9 (~1776.5)"
socheck "Volume = 50[0-2].[0-9] cubic" "Tube volume is close to the analytic pi*(5^2-3^2)*10 (~502.7)"
socheck "smoke: frames=150 objects=14" "solids script produced the expected object count"
# Surface editing: ExtractSrf, DeleteFaces, DupBorder/DupEdge, Untrim, isocurves, ExtendSrf, UnrollSrf, Silhouette, RailRevolve, Fin/Ribbon, grids (see srfedit_script.txt).

# Fillet family: FilletEdge/ChamferEdge exact box-corner trims, FilletSrf, BlendEdge,
# MatchSrf, SplitFace, MergeFaces, ConnectSrf, surface/surface and curve/surface
# Intersect (see fillet_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FL="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/fillet_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: fillet script exited non-zero"; exit 1; }
else
  FL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/fillet_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: fillet script exited non-zero"; exit 1; }
fi
flcheck() { if echo "$FL" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FL" "$1"; fail=1; fi; }
flcheck "FilletEdge: edge 10 of object 1 replaced with an exact fillet (radius 2)" "FilletEdge trimmed the box corner into a real B-rep, not a mesh fallback"
flcheck "Volume = 991.4 cubic" "a 10x10x10 box minus a r=2 edge fillet has volume 1000 - 10*4*(1-pi/4) = 991.42"
flcheck "ChamferEdge: edge 10 of object 2 replaced with an exact chamfer (radius 3)" "ChamferEdge trimmed the box corner exactly"
flcheck "Volume = 955 cubic" "a 10x10x10 box minus a 3x3 edge chamfer has volume 1000 - 10*3^2/2 = 955 exactly"
flcheck "FilletSrf: built between object 4 and 6, radius 2; both surfaces trimmed" "FilletSrf trimmed two independently-picked planar surfaces"
flcheck "Area = 31.41 square" "the r=2 fillet's quarter-cylinder lateral area is (pi/2)*2*10 = 31.42"
flcheck "ChamferSrf: faces .* and .* of object .* replaced with an exact chamfer (distance 3)" "ChamferSrf's two-face-pick UI now reaches kernel::ChamferConvexEdge (the same exact construction ChamferEdge's own path uses) when both picks land on the same solid's own adjacent planar faces, instead of always building the approximate RuledBetween ruled surface"
flcheck "Volume = 955 cubic" "a 10x10x10 box minus a 3x3 ChamferSrf chamfer has the identical exact volume as the plain ChamferEdge case above: 1000 - 10*3^2/2 = 955"
flcheck "BlendEdge: edge 10 of object .* trimmed and joined into the polysurface (Continuity=Tangency)" "BlendEdge now real-trims both adjacent planar faces and stitches the G1 blend in as a genuine third face, closing PARITY_MAP.md's own 'Edge blend trimmed and joined into the polysurface' gap - fixing a real, previously-undiscovered degeneracy along the way: the un-offset construction this replaced fed BuildBlendSurfaceG1 the SAME shared edge as both its 'face A' and 'face B' boundary, collapsing every row to one point (confirmed directly, not assumed - the resulting surface sampled to the identical 3D point everywhere), an invisible, zero-area patch rather than a real blend"
flcheck "7 faces, 15 edges, closed solid" "BlendEdge's own trim-and-join result is a genuine closed solid (6 box faces - 2 trimmed-in-place + the new blend face = 7), not three independent disconnected pieces"
flcheck "Volume = 994.5 cubic" "the box's own corner material actually removed by the blend (a real, reproducible number - no closed form for an arbitrary Hermite blend's own removed volume, the same 'no closed form, check the real number' convention this file's own FilletSrf/Area checks already use), stable across repeated runs"
flcheck "MatchSrf: 2 boundary control point.s. moved to position on the target curve" "MatchSrf moved a plane's edge onto a target line"
flcheck "MatchSrf: 2 boundary control point.s. moved to position on the target curve" "MatchSrf moved a plane's edge onto a target line"
flcheck "MatchSrf: exact edge match (G1) to the target surface, max position error 0, max tangent error 0" "MatchSrf against a target *surface* edge now uses the kernel's exact NurbsSurface::MatchEdge() (self-checked by evaluation, both residuals genuinely ~0), not the app's older per-control-point loop that only assumed a shared parameterization"
flcheck "degree 2 x 1, CVs 3 x 2" "the matched floor plane's real G1 bend toward the box's vertical front face: degree elevated 1->2 and one control point added in the edge-crossing direction to hold position+tangent rows, the other direction (degree 1, 2 CVs) untouched"
# MatchSrf Curvature (G2): closes PARITY_MAP.md's surfaceops "Kernel
# MatchEdge() - wire G2 into MatchSrf" gap - previously only Position/
# Tangency reached kernel::NurbsSurface::MatchEdge(); Curvature was wired
# but unreachable from any app command.
flcheck "MatchSrf: exact edge match (G2) to the target surface, max position error 0, max tangent error 0, max curvature error 0" "MatchSrf's new Curvature option reaches kernel::NurbsSurface::MatchEdge()'s own G2 level for the first time, matched against a genuinely curved quarter-cylinder panel (not a trivial zero-curvature planar target) with every residual self-checked at ~0"
flcheck "degree 1 x 3, CVs 2 x 4" "the matched flat panel's real G2 bend toward the quarter-cylinder's own curvature: degree elevated 1->3 and two control points added in the edge-crossing direction to hold position+tangent+curvature rows, the other direction (degree 1, 2 CVs) untouched"
flcheck "MatchSrf: Curvature continuity needs an exact edge match against a target SURFACE edge (kernel::NurbsSurface::MatchEdge) - the exact match failed (periodic edge, or the target's degree is too low to carry a curvature row); nothing was changed" "MatchSrf's Curvature option fails closed, not silently downgraded to G1/G0, against a target whose own degree structurally can't carry a curvature row (two flat planar faces)"
flcheck "MatchSrf: Curvature continuity needs an exact edge match against a target SURFACE edge (kernel::NurbsSurface::MatchEdge) - a target curve has no curvature-match fallback; nothing was changed" "MatchSrf's Curvature option fails closed against a target CURVE too - MatchEdge() only ever matches two surface edges, and the per-control-point fallback has no curvature construction at all"
flcheck "SplitFace: face 0 split into 2 surfaces along the curve's crossing" "SplitFace found a real CSX crossing of a piercing polyline (a coplanar line can't cross a flat face twice)"
flcheck "MergeFaces: 2 coplanar face.s. merged into 1" "MergeFaces recombined two joined coplanar planes"
flcheck "Area = 100 square" "the merged 5x10 + 5x10 planes have area 100"
flcheck "ConnectSrf: extended both surfaces to their real intersection curve; both surfaces trimmed to the join" "ConnectSrf found the real SSX join line between two already-touching planes"
flcheck "ConnectSrf: extended both surfaces to their real intersection curve; 1/2 surfaces trimmed (surface .*: the join curve does not reach this surface's own domain edge anywhere" "ConnectSrf's general (non-planar) trim: a real quarter-cylinder (exact rational-arc extrusion) genuinely trimmed to the SSX join curve against an oversized plane that honestly reports why IT was left untrimmed, instead of both silently falling back to Split"
flcheck " 1 faces, [0-9]* edges, open" "the cylinder's own real trim produced a single-face open B-rep (not a mesh fallback, not the untrimmed extended surface)"
flcheck "Area = 193.8 square" "the trimmed cylinder patch's real, reproducible lateral area (stable across repeated runs; not a hand-derived closed form, since ON_NurbsSurface::Extend() only continues the original arc smoothly - matching end tangent/curvature - not as an exact circle, past the original 90 degrees the join curve needed to reach the domain edge on)"
flcheck "Intersect: 1 surface intersection curve.s., 0 curve/surface point.s." "Intersect (SSX) found the crossing line of two planes meeting at a right angle"
flcheck "Intersect: 0 surface intersection curve.s., 1 curve/surface point.s." "Intersect (CSX) found where a line pierces a plane"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (variable radius: 1 at t=0, 3 at t=1 (exact))" "FilletEdge Radii= built a genuine variable-radius fillet via the exact planar closed form, not the constant-radius approximation"
flcheck "Volume = 990.8 cubic" "a 10x10x10 box minus a variable r=1->3 edge fillet now goes through kernel::FilletConvexEdgeTapered: the naive closed-form integral of a linear radius ramp with a plain quarter-circle cross-section gives 1000 - (1-pi/4)*10*(1+3+9)/3 = 990.70, but that ignores the elliptical corner-notch splice the kernel builds at each end (see TestFilletConvexEdgeTaperedClosesCornerNotch) - a genuinely different, more faithful notch than the app's old RoundFaceCorner splice - so the tessellated (tol 0.005, not exact analytic) Volume lands one display digit away, at 990.8"
flcheck "FilletSrf: built between object .* and .*, radius 1 to 2; one surface trimmed (the other could not be split)" "VariableFilletSrf built a plane+cylinder variable-radius fillet via BuildPlaneCylinderVariableFillet, not the constant-radius approximation (no 'approximate' suffix means every sample landed exactly on the plane and exactly on the cylinder); the cylinder's own full-circumference contact curve is a closed loop, which TrimBySplit's kernel::SplitFaceByCurve correctly refuses to split (a closed loop can only become an interior hole, not a two-way split), so it still falls back to left-untrimmed there - the planar cap is the one TrimWholeLoop trims"
flcheck "degree 2 x 3, CVs 3 x 33" "the plane+cylinder variable fillet lofted all 33 (samples+1) exact rows into its NURBS surface"
flcheck "VariableBlendSrf: blend surface added between object .* and .*, width 0.2 to 0.8 .Continuity=Curvature: quintic blend, cross-boundary curvature matched exactly to both surfaces." "VariableBlendSrf built a real independent blend (BuildBlendSurfaceG2, same construction as BlendSrf/BlendEdge) with a width that genuinely ramps from 0.2 to 0.8 along the rail, not the rolling-ball fillet VariableFilletSrf uses"
flcheck "degree 5 x 3, CVs 6 x 49" "VariableBlendSrf's Continuity=Curvature output is the degree-5x3 quintic-Hermite blend, the same construction BuildBlendSurfaceG2 gives BlendSrf/BlendEdge - not a rolling-ball fillet arc, and see tests/test_variable_blend.cpp for the numeric proof the width itself (measured on the constructed surface's own control points) actually varies along the rail while the G2 curvature match still holds at both ends. 49 (not the old fixed-sample 24+1=25) rows: VariableBlendSrfCommand now builds through BuildBlendSurfaceG2Adaptive (geom/BlendSurface.h) instead of a bare fixed-sample call - PARITY_MAP.md's own disclosed 'tolerance enforcement exists in the geometry library but is not yet reachable from any app command' gap for Surface-to-surface continuity blend - so this box-face-to-extracted-face pair's own real measured gap at 24 samples exceeded the scale-aware max_gap floor and the adaptive wrapper genuinely doubled to 48 (49 rows) to certify it, rather than silently accepting the coarser build's own unmeasured error the way the fixed-sample call used to"
# BlendSrf (plain, not Variable): now tries the exact kernel::NurbsSurface::
# BlendSurfaces() Hermite-skin construction FIRST, reachable because this
# fixture's two picks (the TOP edge of two separate boxes' facing
# extracted faces, 10 units apart with a real gap between them - unlike
# VariableBlendSrf's own shared-corner-edge fixture just above, where both
# rails are actually the SAME physical box edge and the exact construction
# correctly rejects it as degenerate) are both genuine isoparametric
# boundaries. One run per Continuity value on the identical two-box gap,
# so the three are directly comparable: Tangency (G1) is the degree-3
# cubic BlendCurves() itself builds per row, Curvature (G2) the degree-5
# quintic, and G3 the degree-7 septic - the genuine new capability neither
# BlendSrf nor VariableBlendSrf could reach at all before this wiring
# (BuildBlendSurfaceG1/G2 cap out at G2). All three converge at 16 rows
# (doubled once from the 8-row floor) since this is flat, simple geometry.
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=Tangency, exact kernel blend." "BlendSrf's default Continuity=Tangency now reaches the exact kernel::NurbsSurface::BlendSurfaces() construction, not the approximate BuildBlendSurfaceG1Adaptive fallback"
flcheck "degree 3 x 3, CVs 4 x 16" "BlendSrf's Continuity=Tangency (G1) output is the expected degree-3 (2*1+1) row curve, skinned over 16 rows"
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=Curvature, exact kernel blend." "BlendSrf's Continuity=Curvature now reaches the exact kernel construction too"
flcheck "degree 5 x 3, CVs 6 x 16" "BlendSrf's Continuity=Curvature (G2) output is the expected degree-5 (2*2+1) row curve - one degree past the G1 case just above, same 16-row convergence on the identical fixture"
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=G3, exact kernel blend." "BlendSrf's new Continuity=G3 option reaches kernel::NurbsSurface::BlendSurfaces()'s own continuity=3 path - unreachable from any app command before this wiring, since BuildBlendSurfaceG1/G2 cap out at G2"
flcheck "degree 7 x 3, CVs 8 x 16" "BlendSrf's Continuity=G3 output is the expected degree-7 (2*3+1) row curve - one degree past the G2 case just above, same 16-row convergence on the identical fixture"
flcheck "BlendSrf: blend surface added between object .* and .* .Continuity=G4, exact kernel blend." "BlendSrf's new Continuity=G4 option reaches kernel::NurbsSurface::BlendSurfaces()'s own continuity=4 path - the genuine new capability this round's own kernel-side pass adds, one degree past G3"
flcheck "degree 9 x 3, CVs 10 x 16" "BlendSrf's Continuity=G4 output is the expected degree-9 (2*4+1) row curve - one degree past the G3 case just above, same 16-row convergence on the identical fixture"
flcheck "FilletEdge: edge .* -- mesh fallback (exact B-rep trim unavailable here; result is an approximate mesh, not a clean B-rep)" "FilletEdge succeeded on a solid cylinder's own closed (periodic) rim edge via the mesh fallback - this used to fail unconditionally with a watertight-gap error regardless of radius (see adversarial_corpus_notes.md SS3)"
flcheck "FilletEdge: edge .* -- mesh fallback (exact B-rep trim unavailable here; result is an approximate mesh, not a clean B-rep)\$" "BuildFilletAdaptive's own offset-sampling refinement (cmd_fillet.cpp) drives this plane+cylinder pair's contact-point gap below the scale-aware tolerance floor (measured directly during development: 0.4497 unrefined -> 0.0369 at an 8x8 offset-sample grid -> 0.00309 at 16x16, well under the ~0.0245 target) - the trailing \$ anchor means this line carries NO '(surface quality: contact points off by up to ...)' qualifier, i.e. BuildFillet's own long-unenforced max_gap signal is now genuinely under control here, not just silently approximate; PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact conic fillet (rho 0.5, distance 2)" "FilletEdge's Rho option wires straight to kernel::FilletConvexEdgeConic, a genuine ellipse/parabola/hyperbola cross-section blend distinct from the default rolling-ball circular arc"
flcheck "Volume = 993.3 cubic" "a 10x10x10 box minus a rho=0.5 (exact parabola) conic edge fillet at distance 2 has volume 1000 - 2*2*sin(90deg)*10/6 = 993.3, the closed form FilletConvexEdgeConic's own doc comment derives for rho=0.5"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (RailType=DistFromEdge, distance 2)" "FilletEdge's RailType=DistFromEdge option wires straight to kernel::FilletConvexEdgeByDistanceFromEdge, the same rolling-ball circular fillet as a plain Radius= but specified as a distance-from-edge instead of the radius directly"
flcheck "Volume = 991.4 cubic" "a 10x10x10 box minus a DistFromEdge=2 edge fillet: on a box corner (dihedral 90 degrees) radius = distance*tan(45deg) = 2 exactly, the same r=2 rolling-ball fillet the very first FilletEdge case already verified, now reached via the distance-based RailType path"
flcheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (RailType=DistBetweenRails, distance 2)" "FilletEdge's RailType=DistBetweenRails option wires straight to kernel::FilletConvexEdgeByDistanceBetweenRails, the same rolling-ball circular fillet specified by the straight-line distance between the two rails instead of the radius"
flcheck "Volume = 995.7 cubic" "a 10x10x10 box minus a DistBetweenRails=2 edge fillet: radius = rail_distance/(2*cos(45deg)) gives radius^2 = 2 exactly, so removed volume = 10*2*(1-pi/4) = 4.292, leaving 1000 - 4.292 = 995.7"
flcheck "FilletEdge: 3 staged edges of object .* replaced with an exact multi-edge fillet (RailType=DistFromEdge, distance 2)" "closes PARITY_MAP.md's Blending .. chamfering Alternative blend rail types .no multi-edge/vertex-blend form. gap: FilletEdgeCommand's pending_rail_ staging now batches every RailType pick into one kernel::FilletConvexEdgesByDistanceFromEdge call, the same staging idea pending_conic_/pending_fillet_ already established, reaching that function's own m == 3 trihedral spherical-corner blend instead of rejecting the 2nd/3rd pick's own PlanarFaces() check"
flcheck "Volume = 975.4 cubic" "all 3 edges of a fresh box corner share the identical 90-degree dihedral, so DistFromEdge's own closed-form distance-to-radius conversion lands every edge on radius = 2, the identical closed solid and tessellated volume the plain multi-edge Radius=2 FilletConvexEdges case verifies elsewhere in this script"
flcheck "RemoveFillet: fillet on object .* removed, sharp edge.vertex restored" "RemoveFillet's kernel::RemoveBlend wiring inverts a plain box-corner FilletEdge, restoring the sharp edge purely from the solid's own geometry - PARITY_MAP.md's Blending .. chamfering .Blend removal . defeaturing with healing. entry's own .nothing in the app calls any of these. gap"
flcheck "Volume = 1000 cubic" "RemoveFillet's fillet round trip restores the box's own exact original volume"
flcheck "RemoveFillet: chamfer on object .* removed, sharp edge.vertex restored" "RemoveFillet's kernel::RemoveChamfer wiring inverts a plain box-corner ChamferEdge the same way, dispatched automatically since RemoveFillet tries RemoveBlend then RemoveChamfer then RemoveChamferVertex from a single picked face with no separate face-type option"
flcheck "Volume = 1000 cubic" "RemoveFillet's chamfer round trip also restores the box's own exact original volume"
flcheck "FilletVertex: convex spherical corner at vertex .* of object .* filleted (radius 2)" "FilletVertex reached kernel::FilletConvexEdges' own m==3 spherical-corner blend from a single picked vertex - PARITY_MAP.md's Blending .. chamfering .Vertex blend. entry's own previously-zero app reachability for FilletConvexEdges/FilletConcaveEdges"
flcheck "10 faces, [0-9]* edges, closed solid" "the rounded corner is a genuine closed solid: 6 planar + 3 cylindrical + 1 spherical face, matching kernel::FilletConvexEdges' own single-corner regression test"
flcheck "Volume = 975.4 cubic" "a 10x10x10 box minus one r=2 spherical vertex-blend corner: the closed form 3(1-r)r^2(1-pi/4) + r^3(1-pi/6) at r=0.2 scaled by 1000 gives 1000*(1 - 3*0.8*0.04*(1-pi/4) - 0.008*(1-pi/6)) = 975.587, but Volume tessellates the exact analytic sphere/cylinder/plane solid at a fixed 0.005 tolerance rather than measuring it exactly, and a coarse polygonal approximation of a convex curved surface always inscribes chords slightly inside the true surface, landing at 975.4"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact tapered fillet (radius 1 to 3)" "VariableFilletSrf's two-face-pick UI now reaches kernel::FilletConvexEdgeTapered (the same exact construction FilletEdge's own Radii= path uses) when both picks land on the same solid's own adjacent planar faces with r0 != r1, instead of always building the approximate BuildPlaneCylinderVariableFillet/BuildFillet loft"
flcheck "Volume = 990.8 cubic" "a 10x10x10 box minus a radius 1->3 VariableFilletSrf taper has the identical exact volume as the plain FilletEdge Radii=0:1,1:3 case above: same kernel::FilletConvexEdgeTapered construction, just reached via two picked faces instead of one picked edge"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact conic fillet (rho 0.5, distance 2)" "FilletSrf's own new Rho option (previously FilletEdgeCommand-only) wires straight to kernel::FilletConvexEdgeConic when both picks land on the same solid's own adjacent planar faces with Trim=Yes"
flcheck "Volume = 993.3 cubic" "a 10x10x10 box minus a rho=0.5 FilletSrf conic fillet at distance 2 has the identical exact volume as the plain FilletEdge Rho=0.5 case above"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact fillet (RailType=DistFromEdge, distance 2)" "FilletSrf's own new RailType option (previously FilletEdgeCommand-only) wires straight to kernel::FilletConvexEdgeByDistanceFromEdge when both picks land on the same solid's own adjacent planar faces with Trim=Yes"
flcheck "Volume = 991.4 cubic" "a 10x10x10 box minus a DistFromEdge=2 FilletSrf fillet has the identical exact volume as the plain FilletEdge RailType=DistFromEdge case above"
flcheck "FilletSrf: faces 1 and 2 of object .* replaced with an exact fillet (RailType=DistBetweenRails, distance 2)" "FilletSrf's own new RailType=DistBetweenRails option reaches kernel::FilletConvexEdgeByDistanceBetweenRails the same way"
flcheck "Volume = 995.7 cubic" "a 10x10x10 box minus a DistBetweenRails=2 FilletSrf fillet has the identical exact volume as the plain FilletEdge RailType=DistBetweenRails case above"
flcheck "ChamferVertex: convex corner at vertex .* of object .* chamfered (distance 3)" "ChamferVertex wires kernel::ChamferConvexVertex, previously zero call sites anywhere in dino8-app (RemoveFillet already reached its own inverse, RemoveChamferVertex, but nothing built one forward)"
flcheck "Volume = 995.5 cubic" "a 10x10x10 box minus a distance=3 vertex chamfer has the exact closed-form volume 1000 - 3^3/6 = 995.5"
flcheck "FilletEdge: edge .* of object .* staged for an exact conic fillet (rho 0.5, distance 2) - 1 staged, Enter to apply" "the first Rho pick is staged, not applied immediately - kernel::FilletConvexEdgesConic/FilletConcaveEdgesConic need one shared PlanarFaces() snapshot of every staged edge"
flcheck "FilletEdge: edge .* of object .* staged for an exact conic fillet (rho 0.5, distance 2) - 2 staged, Enter to apply" "the second Rho pick, on the same object, is staged alongside the first rather than applied against the (still untouched) object"
flcheck "FilletEdge: an exact conic (Rho) fillet of the 2 staged edge(s) on object .* failed (convex attempt:.*concave attempt:" "two staged Rho edges that share a face (this box's own TOP-front and TOP-back edges) are rejected as ONE atomic batch - kernel::FilletConvexEdgesConic's own 'two edges in this batch share a face' validation - instead of the pre-fix bug where the first edge's own committed conic result would silently apply, then the second pick would fail confusingly (already-curved solid no longer PlanarFaces()-describable)"
flcheck "Volume = 1000 cubic" "neither staged edge touched the box - a clean atomic failure, not a partially-filleted object"
flcheck "FilletSrf: built between object .* and .*, radius 0.3; both surfaces trimmed" "FilletSrf's TrimBySplit (cmd_fillet.cpp) genuinely trims a NON-planar pick too now, not just a planar one: a bounded quarter-cylinder panel (open, non-periodic - its contact curve crosses the trim boundary at exactly two points) built from the same Arc+ExtrudeCrv fixture ConnectSrf's own general-trim case uses, paired with an oversized tilted plane - kernel::SplitFaceByCurve (boolean_general.h) is general to ANY ON_Surface, unlike TrimWholeLoop's ON_BrepTrimmedPlane"
flcheck "Area = 167 square" "the trimmed quarter-cylinder panel's real, reproducible combined area (stable across repeated runs; not a hand-derived closed form, the same 'no closed form, check the real number' convention the ConnectSrf case above uses) - reads 167, not the pre-BuildFilletAdaptive value of 169.1, since the underlying contact curve is now built from a genuinely more accurate (point-sampled, not per-CV-translated) offset surface; see PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
flcheck "FilletSrf: built between object .* and .*, radius 0.3; both surfaces trimmed\$" "BuildFilletAdaptive's own offset-sampling refinement converges dramatically on this curved-panel-plus-tilted-plane pair (measured directly during development: 0.295421 unrefined -> 0.00028232 at the very first, 8x8 offset-sample grid attempt - roughly a 1000x reduction), landing well under the scale-aware tolerance floor; the trailing \$ anchor means this line carries NO '(approximate: contact points off by up to ...)' suffix, confirming the certification actually succeeded rather than just not crashing - PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
flcheck "FilletEdge: edge .* of object .* staged for an exact fillet (radius 2) - 1 staged, Enter to apply" "the first of 3 box-corner edges is staged, not applied immediately, for the plain (non-Rho) radius case too now"
flcheck "FilletEdge: edge .* of object .* staged for an exact fillet (radius 2) - 2 staged, Enter to apply" "the second box-corner edge is staged alongside the first rather than applied against the (still untouched) object"
flcheck "FilletEdge: edge .* of object .* staged for an exact fillet (radius 2) - 3 staged, Enter to apply" "the third box-corner edge completes the staged batch"
flcheck "FilletEdge: 3 staged edges of object .* replaced with an exact multi-edge fillet (radius 2)" "all 3 staged edges were built as ONE kernel::FilletConvexEdges call, reaching its own m == 3 trihedral spherical-corner blend - PARITY_MAP.md's own 'no app command surfaces either function's own chain-pick at all' gap for the plain circular case"
flcheck "10 faces, 21 edges, closed solid" "one spherical corner blend: 6 planar + 3 cylindrical + 1 spherical = 10 faces, a genuine closed solid - not three independent disconnected pieces the old per-edge-immediate behavior would have left (the second and third picks would have hit a non-planar PlanarFaces() rejection and fallen back to the approximate BuildFillet path instead)"
flcheck "Volume = 975.4 cubic" "matches the app's own tessellated reading of the exact closed form 1000 - 3*8*4*(1-pi/4) - 8*(1-pi/6) = 975.587 (see this section's own comment in fillet_script.txt for why the app's coarser spherical-patch tessellation reads 975.4, not 975.587, and why that gap is pre-existing and unrelated to this fix)"
echo "$FL" | grep -E "^(ok|FAIL)"
if echo "$FL" | grep -q "^FAIL"; then fail=1; fi
flcheck "^ok   expect_objects 62" "fillet script produced the expected object count"

# Adversarial fillets: tiny/at-the-limit/too-large radii relative to the
# shortest adjacent edge, a huge-coordinate-scale box (now fixed for the
# plain constant-radius planar case by TryExactFillet - see
# adversarial_corpus_notes.md), and a shallow-bend FilletSrf (see
# fillet_adversarial_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FA="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/fillet_adversarial_script.txt" 2>&1)" || { echo "$FA"; echo "FAIL: fillet-adversarial script exited non-zero"; exit 1; }
else
  FA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/fillet_adversarial_script.txt" 2>&1)" || { echo "$FA"; echo "FAIL: fillet-adversarial script exited non-zero"; exit 1; }
fi
facheck() { if echo "$FA" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FA" "$1"; fail=1; fi; }
facheck "FilletEdge: edge 10 of object 1 replaced with an exact fillet (radius 0.02)" "a radius far smaller than the shortest adjacent edge still built a real, exact fillet"
facheck "FilletEdge: edge 10 of object 2 replaced with an exact fillet (radius 1)" "a radius at exactly half the shortest adjacent edge's length still built a valid fillet"
facheck "7 faces, 15 edges, closed solid" "the at-the-limit fillet is a genuine closed solid, not degenerate"
facheck "! FilletEdge: the offset surfaces do not meet" "a radius more than double what the geometry supports failed with a clear diagnostic, not a hang or garbage surface"
facheck "FilletEdge: edge 10 of object .* replaced with an exact fillet (radius 2)" "a huge-coordinate-scale box's otherwise-ordinary fillet now succeeds: TryExactFillet's kernel::FilletConvexEdge builds one coherent double-precision Brep instead of stitching together independently-intersected spine samples, so the later float-mesh Volume check no longer sees a gap at this scale (see adversarial_corpus_notes.md's updated note)"
facheck "Volume = 991.4 cubic" "the huge-coordinate-scale fillet's tessellated volume matches the identical exact closed-form value fillet_script.txt's own origin-scale Radius=2 box case verifies, proving no precision was lost"
facheck "ChamferEdge: edge 10 of object 5 replaced with an exact chamfer (distance1 2, distance2 4)" "ChamferEdge's Distance2 option wires straight to kernel::ChamferConvexEdge's own two-INDEPENDENT-distance construction, not the symmetric rolling-ball-derived approximate path"
facheck "Volume = 960 cubic" "a 10x10x10 box minus a 2x4 asymmetric edge chamfer has volume 1000 - 2*4*10/2 = 960 exactly"
facheck "ChamferEdge: edge 10 of object 6 replaced with an exact chamfer (distance1 2, angle 45 degrees from face 1)" "ChamferEdge's Angle option wires to kernel::ChamferConvexEdgeAngle, whose law-of-sines dispatch to the two-distance form is exercised here at exactly the symmetric 45-degree case"
facheck "Volume = 980 cubic" "at Angle=45 on a right-angle edge distance_j == distance_i exactly, so this lands on the identical volume a plain symmetric Radius=2 chamfer would: 1000 - 2*2*10/2 = 980"
facheck "ChamferEdge: edge .* of object .* replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "a Distance2 request on a cylinder's curved-adjacent-face rim edge now reaches kernel::ChamferCylinderRim's exact two-distance cone (wall 1 / cap 2) instead of failing with the planar-only diagnostic - the one curved case with an exact unequal-distance construction; the Distance/Angle diagnostic on the same rim is pinned in kernel_wiring_script.txt below"
facheck "FilletEdge: edge 10 of object 8 replaced with an exact conic fillet (rho 0.5, distance1 2, distance2 4)" "FilletEdge's Rho option combined with Distance2 wires straight to kernel::FilletConvexEdgeConic's own two-INDEPENDENT-distance form, an elliptical (not parabolic) conic cross-section"
facheck "Volume = 986.7 cubic" "a 10x10x10 box minus an asymmetric distance1=2/distance2=4 rho=0.5 conic edge fillet has volume 1000 - 2*4*sin(90deg)*10/6 = 986.7"
facheck "! FilletEdge: an exact conic .Rho. fillet needs the whole object to be planar-faced at this edge" "a Rho request on a cylinder's curved-adjacent-face rim edge fails outright instead of silently building a plain circular rolling-ball fillet that quietly ignores Rho - unlike Chamfer's symmetric-distance case, there is no approximate fallback a non-circular conic could ever be represented by"
facheck "! FilletEdge: an exact RailType=DistFromEdge fillet needs the whole object to be planar-faced at this edge" "a RailType=DistFromEdge request on a cylinder's curved-adjacent-face rim edge fails outright instead of silently building a plain radius=1 rolling-ball fillet under a mismatched distance interpretation - like Rho, the dihedral-angle-to-radius conversion has no meaning on a curved adjacent face"
facheck "! FilletEdge: an exact RailType=DistFromEdge fillet of the 2 staged edge.s. on object .* failed" "two RailType edges staged in one FilletEdge run that meet at a shared vertex (TOP-FRONT and TOP-LEFT, an m == 2 configuration whose third edge stays sharp) are rejected atomically by FilletConvexEdgesByDistanceFromEdge's own documented scope limit - the pending_rail_ staging this pass added - rather than silently applying the first pick and failing the second"
facheck "Volume = 1000 cubic" "the two-RailType-edges-meeting-at-a-vertex batch rejection leaves the box completely untouched, not a partially-filleted result"
facheck "! FilletSrf: the offset surfaces do not meet" "FilletSrf on two nearly-flat planes failed with its own clear diagnostic instead of a garbage surface"
facheck "ChamferSrf: built between object .* and .*, radius 1" "ChamferSrf Trim=No on a cylinder's own flat-top cap and curved side wall still falls through to the approximate RuledBetween path (the exact kernel::ChamferCylinderRim path always replaces the whole solid with an already-trimmed result, not the untrimmed separate surface Trim=No asks for) instead of crashing or silently misbuilding"
facheck "ChamferSrf: built between object .* and .*, radius 2" "ChamferSrf Trim=No on an otherwise-exact planar box corner also falls through to the approximate path - the exact kernel path always replaces the whole solid with an already-trimmed result, not the untrimmed separate surface Trim=No asks for"
facheck "! RemoveFillet: the picked face is not a recognized fillet, chamfer, or vertex-chamfer facet" "RemoveFillet on a plain box face declines with a clear diagnostic (kernel::RemoveBlend finds no fillet-family patch at all, kernel::RemoveChamfer's rail-pairing check fails for both of a box face's own parallel neighbour pairs, kernel::RemoveChamferVertex rejects the 4-point loop outright) instead of crashing or misidentifying an ordinary face as a blend"
facheck "Volume = 1000 cubic" "the box RemoveFillet declined to touch survives with its exact original volume"
facheck "! FilletVertex: not a supported trihedral corner" "a FilletVertex radius too large for a 2x2x2 box's own corner edges fails cleanly on both the convex and concave kernel attempts, not a crash or garbage geometry"
facheck "Volume = 8 cubic" "the box a failed FilletVertex declined to touch survives with its exact original 2x2x2 volume"
facheck "FilletSrf: built between object .* and .*, radius 1 to 2; one surface trimmed (the other could not be split)" "VariableFilletSrf on a cylinder's own flat-top cap and curved side wall falls through to the approximate BuildPlaneCylinderVariableFillet/BuildFillet cascade (kernel::FilletConvexEdgeTapered needs the WHOLE solid planar-faced, which a cylindrical face fails outright) instead of crashing or silently misbuilding; the wall's own contact curve is still a closed loop TrimBySplit correctly refuses, but the cap's own TrimWholeLoop now succeeds - BuildFilletAdaptive's genuinely more accurate (point-sampled) contact curve closes the cap's own trim loop cleanly where the pre-fix, less-accurate OffsetBy-derived curve did not, so only one side stays untrimmed now, not both; see PARITY_MAP.md's Blending .. chamfering .Rolling-ball blend surface accuracy. entry's own closed gap"
facheck "FilletSrf: built between object .* and .*, radius 1 to 2$" "VariableFilletSrf Trim=No on an otherwise-exact planar box corner also falls through to the approximate cascade - the exact kernel path always replaces the whole solid, not the untrimmed separate surface Trim=No asks for"
facheck "! FilletSrf: an exact conic (Rho) fillet needs the two faces to share an edge on one planar-faced solid with Trim=Yes (convex attempt:.*not planar" "FilletSrf Rho on a cylinder's own flat-top cap and curved side wall refuses with a clear diagnostic instead of silently building a plain round fillet that quietly ignores Rho - unlike Chamfer/VariableFillet just above, there is no approximate fallback a non-circular conic could ever be represented by"
facheck "! FilletSrf: an exact conic (Rho) fillet needs the two faces to share an edge on one planar-faced solid with Trim=Yes (the two picks are independent surfaces with no shared edge)" "FilletSrf Rho on two genuinely independent (no shared edge) extracted surfaces refuses the same way - fa.id != fb.id means kernel::FilletConvexEdgeConic/FilletConcaveEdgeConic have no shared ON_BrepEdge to identify at all, not merely a curved-face rejection"
facheck "! BlendSrf: could not build the blend" "BlendSrf Continuity=G3, picking the same face/edge twice (a genuinely degenerate, zero-length rail pairing), fails closed with a clear diagnostic instead of silently building a degenerate patch - G3 has no approximate fallback to drop to the way Continuity=Tangency/Curvature would"
facheck "BlendEdge: blend surface added between the two faces at edge 2" "BlendEdge on a cylinder's own curved-adjacent-face rim edge falls through to the pre-existing 'added as a separate surface' behaviour unchanged - the new exact trim-and-join path needs both adjacent faces planar"
facheck "3 faces, 3 edges, closed solid" "the cylinder itself survives completely untouched by the failed trim-and-join attempt"
facheck "! FilletEdge: the offset surfaces do not meet .*(the largest radius this edge's own two faces support is 5)" "a radius 10x beyond what either adjacent face supports (50, on an edge whose kernel::MaxFilletRadius is exactly 5) now reports the REAL largest radius this edge can take, not just the approximate path's own generic diagnostic - closing PARITY_MAP.md's own 'the app reports the failure rather than handling it' half of the Fillet overflow gap"
facheck "Volume = 1000 cubic" "the box a radius-50 FilletEdge declined to touch survives with its exact original volume"
facheck "Domain: 1 object(s) now have domain 0 to 24.95" "Domain pinned the ruled chamfer surface's V length to 24.9513866589378, a value where equal-step isocurve parameters overshoot the domain end by one ulp"
if echo "$FA" | grep -q "IsoCurve: parameter is outside"; then echo "FAIL a surface's isocurve display parameter overshot its own domain end by an ulp and NurbsSurface::IsoCurve threw (SceneObject.cpp DomainParameter regression - this is what killed Windows CI with 0xE06D7363)"; fail=1; else echo "ok   a surface whose equal-step isocurve parameter would overshoot its domain end by an ulp still draws (DomainParameter pins the endpoints)"; fi
# An exception a command, the frame/draw path or a display tessellation threw
# is contained and reported on stderr by the app (main.cpp / SceneObject.cpp)
# instead of terminating the process (Windows CI used to die here with a bare
# "UNHANDLED EXCEPTION: code=0xE06D7363"). It does not fail the run by itself,
# but surface the message so the real thrower is visible in the CI log.
echo "$FA" | grep -E "^dino8: (! |display tessellation)" | sed 's/^/note   fillet-adversarial: contained exception: /' || true
echo "$FA" | grep -E "^(ok|FAIL)"
if echo "$FA" | grep -q "^FAIL"; then fail=1; fi
facheck "^ok   expect_objects 0" "fillet-adversarial script cleaned up to zero objects at the end"

# Extended selection and state commands: SelDupAll, SelShortCrv, SelKeyValue, SelVolumeSphere, Dot, Camera, SetActiveViewport, licence rule (see state_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  ST="$(timeout 900 "$BIN" --smoke 120 --script "$HERE/state_script.txt" 2>&1)" || { echo "$ST"; echo "FAIL: state script exited non-zero"; exit 1; }
else
  ST="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 120 --script "$HERE/state_script.txt" 2>&1)" || { echo "$ST"; echo "FAIL: state script exited non-zero"; exit 1; }
fi
stcheck() { if echo "$ST" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$ST" "$1"; fail=1; fi; }
stcheck "SelDupAll: 2 duplicate object(s) selected" "SelDupAll found the two identical lines"
stcheck "SelShortCrv: 1 curve(s) shorter than 5 selected" "SelShortCrv picked the 2-unit line"
stcheck "Hyperlink 'https://example.org/dino8' set on 1 object(s)" "Hyperlink stored user text"
stcheck "SelKeyValue: 1 object(s) with Hyperlink=https://example.org/dino8 selected" "SelKeyValue matched the user text"
stcheck "SelVolumeSphere: radius 15, 2 object(s) selected" "SelVolumeSphere selected the objects near the origin"
stcheck "Dot 'Hello' at 5,5,0 (object 5)" "Dot created a text dot"
stcheck "Named selection 'dots' restored: 1 object(s) selected" "NamedSelections saved and restored a set"
stcheck "Camera (Perspective): location" "Camera reported the perspective camera"
stcheck "Active viewport: Top" "SetActiveViewport switched to Top"
stcheck "Camera (Top): location .*parallel projection" "Camera reported the Top (parallel) camera"
stcheck "Perspective angle 60 deg" "PerspectiveAngle set the lens"
stcheck "Dino 8 is free software: no licenses, accounts or subscriptions." "CheckOutLicense/Login print the no-licence rule"
stcheck "Selection filter edges on" "SelectionFilterEdges toggled the filter"
stcheck "Document user text Project = Dino" "SetDocumentUserText stored a key"
stcheck "Gumball: on, alignment CPlane" "GumballSettings reported the widget state"
echo "$ST" | grep -E "^(ok|FAIL)"
if echo "$ST" | grep -q "^FAIL"; then fail=1; fi
stcheck "^ok   expect_selected 5" "state script ended with every object selected"
# View tools: clipping planes + sections, layouts + details, named CPlanes, animation playback/recording (see viewtools_script.txt).
mkdir -p "$TMPW/vt"
sed "s|@TMP@|$TMPW/vt|g" "$HERE/viewtools_script.txt" > "$TMPW/viewtools_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  VT="$(timeout 900 "$BIN" --smoke 200 --script "$TMPW/viewtools_script.txt" 2>&1)" || { echo "$VT"; echo "FAIL: view-tools script exited non-zero"; exit 1; }
else
  VT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$TMPW/viewtools_script.txt" 2>&1)" || { echo "$VT"; echo "FAIL: view-tools script exited non-zero"; exit 1; }
fi
vtcheck() { if echo "$VT" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$VT" "$1"; fail=1; fi; }
vtcheck "ClippingPlane: created Clipping Plane 1 (40 x 40, normal 0,0,1, clips all viewports)" "ClippingPlane built a plane from two corners"
vtcheck "ClippingSections: 1 curve(s) from 1 plane(s)" "ClippingSections cut the sphere's equator"
vtcheck "degree 1, [0-9]* control points, non-rational, closed" "the section is a closed polyline"
vtcheck "ClearClippingSections: removed 1 section curve(s)" "ClearClippingSections removed the section"
vtcheck "DisableClippingPlane: 1 plane(s) disabled" "DisableClippingPlane"
vtcheck "EnableClippingPlane: 1 plane(s) enabled" "EnableClippingPlane"
vtcheck "ClippingPlane: created Upper (40 x 40, normal 0,0,1, clips Perspective)" "ClippingPlane honoured Name= and Viewports=Active"
vtcheck "SaveClippingSectionCPlanes: 2 named CPlane(s) saved" "SaveClippingSectionCPlanes"
vtcheck "SaveClippingSectionViews: 2 named view(s) saved" "SaveClippingSectionViews"
vtcheck "ClippingDrawings: 2 drawing curve(s) on layer 'Clipping Drawings' from 2 plane(s)" "ClippingDrawings drew section curves onto a dedicated layer"
vtcheck "UpdateClippingDrawings: 2 drawing curve(s) on layer 'Clipping Drawings' from 2 plane(s)" "UpdateClippingDrawings regenerated them"
vtcheck "EditClippingDrawings: 2 drawing curve(s) selected for editing" "EditClippingDrawings selected the drawing curves"
vtcheck "ExportClippingDrawings: wrote 2 drawing curve(s) to $TMPW/vt/drawings.3dm" "ExportClippingDrawings wrote them to a file"
vtcheck "ClippingSections: 2 curve(s) from 2 plane(s)" "ClippingSections handled two planes"
vtcheck "ExtractClippingSlices: 2 planar slice surface(s) from 2 plane(s)" "ExtractClippingSlices built trimmed planar faces, not just outline curves"
vtcheck "1 faces, 1 edges, open" "a clipping slice is a single trimmed planar face"
vtcheck "MPlane: CPlane of Perspective follows object [0-9]*, tracking its orientation (origin 58.54,1.464,2.5 x 0.7071,0.7071,0" "MPlane tracked a rotated box's own plane, not just its bounding-box centre"
vtcheck "MPlane: detached" "MPlane with nothing selected detaches (min=0 so Enter isn't needed)"
vtcheck "CPlane Perspective: World (origin 0,0,0 x 1,0,0 y 0,1,0)" "CPlane World reset after detaching MPlane"
vtcheck "OrientCameraToSrf: camera looks along the normal of object [0-9]* at 80,10,0 (picked point)" "OrientCameraToSrf used the picked point, not just the surface centre"
vtcheck "Camera (Perspective): location 80,10,-96.05, target 80,10,0" "OrientCameraToSrf's camera looks straight down at the picked point"
vtcheck "Zoom1To1Calibrate: 3.78 pixels per mm (96 dpi)" "Zoom1To1Calibrate read a dpi value from the command line"
vtcheck "Zoom1To1: Perspective shows" "Zoom1To1 read back the calibrated pixels-per-mm"
vtcheck "PerspectiveMatch: camera set to eye 30,-40,25, target 2,3,-1, lens 50 mm" "PerspectiveMatch's two-vanishing-point + orthocenter solve exactly reconstructed the ground-truth eye/target/lens (30,-40,25 / 2,3,-1 / 50mm) from points re-projected through that same camera -- not just 'ran without crashing'"
vtcheck "Camera (Perspective): location 30,-40,25, target 2,3,-1, distance 57.52" "reading the camera back after PerspectiveMatch confirms it, not just the command's own printout"
vtcheck "CPlane Perspective: elevation 7 (origin 0,0,7" "CPlane Elevation= moved the CPlane"
vtcheck "NamedCPlane: saved Deck (origin 0,0,7" "NamedCPlane Save"
vtcheck "NamedCPlane: restored Deck in Perspective (origin 0,0,7" "NamedCPlane Restore"
vtcheck "CPlanePrevious: origin 0,0,0" "CPlanePrevious stepped back through the CPlane history"
vtcheck "CPlaneNext: origin 0,0,7" "CPlaneNext stepped forward again"
vtcheck "CPlane Perspective: rotated 45 degrees (origin 0,0,7 x 0.7071,0.7071,0" "CPlane Rotate="
vtcheck "CopyCPlaneToAll: CPlane of Perspective copied to 3 viewport(s)" "CopyCPlaneToAll"
vtcheck "Layout: created Sheet1 (297 x 210 mm)" "Layout created a page"
vtcheck "Detail: added Detail 1 (130 x 100 mm, Top) to Sheet1" "Detail added a Top detail from two page corners"
vtcheck "Detail: added Iso (110 x 170 mm, Perspective) to Sheet1" "Detail honoured View= and Name="
vtcheck "SelDetail: 1 detail(s) selected" "SelDetail selected the named detail"
vtcheck "HideLayersInDetail: 1 layer(s) in 1 detail(s)" "HideLayersInDetail"
vtcheck "CopyDetailToViewport: Iso -> Perspective" "CopyDetailToViewport"
vtcheck "CopyLayout: created Sheet1 Copy with 2 detail(s)" "CopyLayout duplicated the page"
vtcheck "LayoutProperties: Sheet2 420 x 297 mm" "LayoutProperties renamed and resized the page"
vtcheck "Layouts: switched to Model" "Layouts Model switched back to model space"
vtcheck "SetTurntableAnimation: 6 frames over 360 degrees in Perspective" "SetTurntableAnimation"
vtcheck "ViewFrameNumber: frame 3 of 6" "ViewFrameNumber"
vtcheck "ViewLastFrame: frame 6 of 6" "ViewLastFrame"
vtcheck "PlayAnimation: finished 6 frames" "PlayAnimation stepped through every frame without blocking"
vtcheck "RecordAnimation: wrote 6 frames to $TMPW/vt/frames" "RecordAnimation wrote every frame"
vtcheck "SetOneDaySunAnimation: 4 frame(s); PlayAnimation/RecordAnimation will sweep the Sun (Altitude -5 to 60)" "SetOneDaySunAnimation built a sun-only animation"
vtcheck "ViewFirstFrame: frame 1 of 4" "ViewFirstFrame stepped into the one-day sun animation"
vtcheck "Azimuth=70 Altitude=-5" "the one-day animation's first frame is sunrise (low altitude, easterly azimuth)"
vtcheck "ViewLastFrame: frame 4 of 4" "ViewLastFrame stepped to the animation's last frame"
vtcheck "Azimuth=290 Altitude=-5" "the one-day animation's last frame is sunset (low altitude again, westerly azimuth)"
vtcheck "SetSeasonalSunAnimation: 4 frame(s); PlayAnimation/RecordAnimation will sweep the Sun (Altitude -10 to 65)" "SetSeasonalSunAnimation built a sun-only animation"
vtcheck "Azimuth=180 Altitude=-10" "the seasonal animation's first and last frames are both winter (fixed solar-noon azimuth, lowest altitude)"
vtcheck "SplitViewportHorizontal: added Perspective 2 (5 viewports)" "SplitViewportHorizontal added a viewport"
vtcheck "CloseViewport: closed Perspective 2 (4 left)" "CloseViewport removed it"
# ToggleFloatingViewport re-dock must restore the real ImGui dock layout it
# had right before floating - including another viewport the user (here,
# DockLayoutRearrangeSelfTest) had already dragged out of the default grid -
# not just rebuild the default grid (see cmd_viewtools.cpp's
# ToggleFloatingViewport/DockLayoutSelfTest/DockLayoutRearrangeSelfTest and
# app/Application.cpp's SnapshotDockLayoutBeforeFloating/
# RestoreDockLayoutAfterFloating).
vtcheck "DockLayoutRearrangeSelfTest: tabbed Right into Top's dock node" "DockLayoutRearrangeSelfTest tabbed Right into Top (simulates the drag a mouse can't do headlessly)"
vtcheck "ToggleFloatingViewport: Perspective is now floating" "ToggleFloatingViewport floated Perspective"
vtcheck "ToggleFloatingViewport: Perspective is docked again" "ToggleFloatingViewport re-docked Perspective"
dockid() { echo "$VT" | grep "^history: DockLayoutSelfTest: $1 dock=" | sed -n "${2}p" | grep -oE '0x[0-9A-Fa-f]+'; }
DOCK_TOP_BEFORE="$(dockid Top 1)"; DOCK_RIGHT_BEFORE="$(dockid Right 1)"; DOCK_FRONT_BEFORE="$(dockid Front 1)"
DOCK_TOP_AFTER="$(dockid Top 2)"; DOCK_RIGHT_AFTER="$(dockid Right 2)"; DOCK_FRONT_AFTER="$(dockid Front 2)"
DOCK_PERSP_AFTER="$(dockid Perspective 2)"
if [ -n "$DOCK_RIGHT_BEFORE" ] && [ -n "$DOCK_TOP_BEFORE" ] && [ "$DOCK_RIGHT_BEFORE" = "$DOCK_TOP_BEFORE" ] && [ "$DOCK_FRONT_BEFORE" != "$DOCK_TOP_BEFORE" ]; then
  echo "ok   DockLayoutRearrangeSelfTest actually tabbed Right into Top's real ImGui dock node ($DOCK_RIGHT_BEFORE, distinct from Front's $DOCK_FRONT_BEFORE)"
else
  echo "FAIL DockLayoutRearrangeSelfTest did not really tab Right into Top (Right=$DOCK_RIGHT_BEFORE Top=$DOCK_TOP_BEFORE Front=$DOCK_FRONT_BEFORE)"; fail=1
fi
if [ -n "$DOCK_TOP_AFTER" ] && [ "$DOCK_TOP_AFTER" = "$DOCK_TOP_BEFORE" ] && [ "$DOCK_RIGHT_AFTER" = "$DOCK_RIGHT_BEFORE" ] && [ "$DOCK_FRONT_AFTER" = "$DOCK_FRONT_BEFORE" ]; then
  echo "ok   ToggleFloatingViewport's re-dock restored the exact prior arrangement (Right stayed tabbed with Top at $DOCK_RIGHT_AFTER, Front unchanged at $DOCK_FRONT_AFTER) instead of resetting to the default grid"
else
  echo "FAIL ToggleFloatingViewport's re-dock did not preserve the prior arrangement (Top $DOCK_TOP_BEFORE->$DOCK_TOP_AFTER, Right $DOCK_RIGHT_BEFORE->$DOCK_RIGHT_AFTER, Front $DOCK_FRONT_BEFORE->$DOCK_FRONT_AFTER)"; fail=1
fi
if [ -n "$DOCK_PERSP_AFTER" ] && [ "$DOCK_PERSP_AFTER" != "0x00000000" ]; then
  echo "ok   Perspective is itself back in the dock tree after the float/re-dock round trip (dock=$DOCK_PERSP_AFTER)"
else
  echo "FAIL Perspective did not end up re-docked (dock='$DOCK_PERSP_AFTER')"; fail=1
fi
vtcheck "Layouts: 2 layout(s); active: Model" "layouts survived the .3dm round-trip"
vtcheck "NamedCPlane: 3 named CPlane(s)" "named CPlanes survived the .3dm round-trip"
vtcheck "SelClippingPlane: 2 clipping plane(s) selected" "clipping planes survived the .3dm round-trip"
vtcheck "^ok   expect_objects 5" "view-tools script ended with the sphere, 2 clipping slices, the MPlane box and the Plane surface"
vtcheck "gl_error=0" "view-tools script: no OpenGL errors (clip distances)"
FRAMES="$(ls "$TMPW/vt/frames"/frame_*.bmp 2>/dev/null | wc -l)"
[ "$FRAMES" -ge 3 ] && echo "ok   RecordAnimation wrote $FRAMES BMP frames" || { echo "FAIL RecordAnimation frames ($FRAMES)"; fail=1; }
[ -s "$TMPW/vt/frames/frame_0001.bmp" ] && [ "$(head -c 2 "$TMPW/vt/frames/frame_0001.bmp")" = "BM" ] && echo "ok   frame_0001.bmp is a BMP" || { echo "FAIL frame_0001.bmp"; fail=1; }
grep -q "^Upper" "$TMPW/vt/clipping.txt" && echo "ok   ExportClippingSectionInfo listed the Upper plane" || { echo "FAIL clipping.txt"; fail=1; }

# NestedClippingDrawing: a real section of a section, not just a flat
# ClippingDrawing repeated twice -- the second plane re-clips the FIRST
# plane's already-sectioned rectangle, and the result's own hand-computed
# bounding box (checked with BoundingBox on the actual nested curve, not
# just a command echo) confirms the geometry, not only that it ran (see
# nested_clipping_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  NC="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/nested_clipping_script.txt" 2>&1)" || { echo "$NC"; echo "FAIL: nested-clipping script exited non-zero"; exit 1; }
else
  NC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/nested_clipping_script.txt" 2>&1)" || { echo "$NC"; echo "FAIL: nested-clipping script exited non-zero"; exit 1; }
fi
nccheck() { if echo "$NC" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$NC" "$1"; fail=1; fi; }
nccheck "ClippingDrawings: 1 drawing curve(s) on layer 'Clipping Drawings' from 1 plane(s)" "ClippingDrawings built PlaneX's flat section of the cube"
nccheck "Bounding box min 0,-5,0 max 0,5,10" "PlaneX's flat section is the hand-computed 10 x 10 rectangle (x=0, y in [-5,5], z in [0,10])"
nccheck "NestedClippingDrawing: 1 nested drawing curve(s) clipping PlaneX's section by PlaneY (section of a section, on layer 'Clipping Drawings')" "NestedClippingDrawing re-clipped PlaneX's own section by PlaneY, not the scene"
nccheck "Bounding box min 0,0,0 max 0,0,10" "the nested drawing is the hand-computed line where PlaneX and PlaneY intersect, clipped to PlaneX's rectangle (x=0,y=0,z in [0,10]) -- a real doubly-clipped result, not a re-derivation from the cube"
nccheck "^ok   expect_objects 3" "nested-clipping script ended with exactly the cube, the flat PlaneX drawing and the nested PlaneX>PlaneY drawing"

# ImportLayout: per-detail hidden-object state (LayoutDetail::hidden_objects)
# must survive the round trip through a saved .3dm and back in via
# ImportLayout, not just the page/detail cameras - see importlayout_script.txt
# and cmd_viewtools.cpp's ImportLayout/DetailHiddenSelfTest.
mkdir -p "$TMPW/il"
sed "s|@TMP@|$TMPW/il|g" "$HERE/importlayout_script.txt" > "$TMPW/importlayout_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  IL="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/importlayout_script.txt" 2>&1)" || { echo "$IL"; echo "FAIL: ImportLayout script exited non-zero"; exit 1; }
else
  IL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/importlayout_script.txt" 2>&1)" || { echo "$IL"; echo "FAIL: ImportLayout script exited non-zero"; exit 1; }
fi
ilcheck() { if echo "$IL" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$IL" "$1"; fail=1; fi; }
ilcheck "HideInDetail: 1 object(s) in 1 detail(s)" "HideInDetail hid the tagged box in the source document"
ilcheck "ImportLayout: imported 1 layout(s) and 2 object(s) from $TMPW/il/importlayout_src.3dm" "ImportLayout pulled in the layout and both objects it references"
ilcheck "Layouts: 1 layout(s); active: Model" "the imported layout exists in the fresh document"
IL_BEFORE_COUNT="$(echo "$IL" | grep -c "^history: DetailHiddenSelfTest: Sheet1/Det1 hidden_objects=1")"
[ "$IL_BEFORE_COUNT" -ge 2 ] && echo "ok   DetailHiddenSelfTest reports exactly 1 hidden object both before Save and after ImportLayout" || { echo "FAIL DetailHiddenSelfTest hidden_objects count ($IL_BEFORE_COUNT occurrence(s) of hidden_objects=1, want >=2)"; fail=1; }
IL_HIDDEN_COUNT="$(echo "$IL" | grep -c "^history: DetailHiddenSelfTest: SrcHidden hidden$")"
IL_VISIBLE_COUNT="$(echo "$IL" | grep -c "^history: DetailHiddenSelfTest: SrcVisible visible$")"
[ "$IL_HIDDEN_COUNT" -ge 2 ] && echo "ok   SrcHidden is reported hidden in LayoutDetail::hidden_objects both before Save and after ImportLayout ($IL_HIDDEN_COUNT occurrence(s))" || { echo "FAIL SrcHidden was not consistently reported hidden ($IL_HIDDEN_COUNT occurrence(s), want >=2)"; fail=1; }
[ "$IL_VISIBLE_COUNT" -ge 2 ] && echo "ok   SrcVisible is reported visible (not swept into hidden_objects) both before Save and after ImportLayout ($IL_VISIBLE_COUNT occurrence(s))" || { echo "FAIL SrcVisible was not consistently reported visible ($IL_VISIBLE_COUNT occurrence(s), want >=2)"; fail=1; }
ilcheck "^ok   expect_objects 2" "ImportLayout script ended with exactly the 2 imported objects (no duplicated geometry)"

# PrintDisplay: the preview must show each object's real print colour
# (Document::EffectiveColor, the same colour ExportPdf/ExportSvg actually
# put on the page) instead of Viewport.cpp's near-black-on-dark-background
# legibility lift - see printdisplay_script.txt. A line coloured 5,5,5 (near
# black) on the default dark Wireframe background gets lifted to 222,225,230
# with PrintDisplay off, and must show its literal, unlifted 5,5,5 with
# PrintDisplay on.
mkdir -p "$TMPW/pd"
sed "s|@TMP@|$TMPW/pd|g" "$HERE/printdisplay_script.txt" > "$TMPW/printdisplay_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PD="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/printdisplay_script.txt" 2>&1)" || { echo "$PD"; echo "FAIL: PrintDisplay script exited non-zero"; exit 1; }
else
  PD="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/printdisplay_script.txt" 2>&1)" || { echo "$PD"; echo "FAIL: PrintDisplay script exited non-zero"; exit 1; }
fi
pdcheck() { if echo "$PD" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PD" "$1"; fail=1; fi; }
pdcheck "SetRenderColor: 1 object(s) set to 5,5,5" "SetRenderColor gave the line its own near-black colour"
pdcheck "PrintDisplay: off" "PrintDisplay off before the first screenshot"
pdcheck "PrintDisplay: on (print line widths and print colours previewed)" "PrintDisplay on reports it now also previews print colours"
pdcheck "^ok   expect_objects 1" "PrintDisplay script left exactly the one line"
python3 - "$TMPW/pd/pd_off.bmp" "$TMPW/pd/pd_on.bmp" <<'PY' && echo "ok   PrintDisplay on shows the line's literal print colour (5,5,5); PrintDisplay off still lifts it to 222,225,230 for on-screen legibility" || { echo "FAIL PrintDisplay's preview does not reflect each object's real print colour"; fail=1; }
import struct, sys

def read_bmp(path):
    d = open(path, 'rb').read()
    assert d[:2] == b'BM', (path, 'signature')
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', d[2:30])
    assert size == len(d) and hdr == 40 and planes == 1 and bpp == 24, (path, size, len(d), w, h, bpp)
    row = (w * 3 + 3) & ~3
    px = d[off:]
    assert len(px) == row * abs(h), (path, 'pixel data size')
    return px

def count(px, triple):
    return sum(1 for i in range(0, len(px) - 2, 3) if px[i:i + 3] == triple)

off_px = read_bmp(sys.argv[1])
on_px = read_bmp(sys.argv[2])
lifted_bgr = bytes((230, 225, 222))  # Color::FromBytes(222,225,230) written BGR (BMP's own byte order)
raw_gray = bytes((5, 5, 5))          # SetRenderColor 5,5,5 - a pure grey, so BGR/RGB order does not matter

assert count(off_px, lifted_bgr) > 0, 'PrintDisplay off: the near-black line was not lifted to the legibility colour'
assert count(off_px, raw_gray) == 0, 'PrintDisplay off: the literal near-black colour leaked through despite the legibility lift'
assert count(on_px, raw_gray) > 0, 'PrintDisplay on: the line does not show its own literal print colour (5,5,5)'
assert count(on_px, lifted_bgr) == 0, 'PrintDisplay on: the legibility lift colour is still present - PrintDisplay is not bypassing it'
PY

# Lua scripting: RunScript/rs.* API, "= expr" inline evaluation, rs.GetPoint
# fed by a trailing script token (see script_script.txt).
cat > "$TMPW/t.lua" <<'LUA'
-- Builds a box and a sphere, unions them, tags and files the result, then
-- reports its bounding box and volume before picking up a marker point.
rs.AddLayer("Parts")
local box = rs.AddBox({0, 0, 0}, {10, 10, 10})
local sphere = rs.AddSphere({5, 5, 12}, 4)
rs.MoveObject(sphere, {0, 0, -3})
local made = rs.BooleanUnion({box, sphere})
if not made or #made == 0 then error("BooleanUnion produced nothing") end
local widget = made[1]
rs.ObjectName(widget, "Widget")
rs.ObjectLayer(widget, "Parts")
local bb = rs.BoundingBox(widget)
print(string.format("bbox min %.0f,%.0f,%.0f", bb[1].x, bb[1].y, bb[1].z))
print(string.format("bbox max %.0f,%.0f,%.0f", bb[7].x, bb[7].y, bb[7].z))
local vol = rs.SurfaceVolume(widget)
print(string.format("widget volume %.2f", vol))
if vol < 1000 or vol > 1268 then error("volume out of expected range: " .. tostring(vol)) end
local p = rs.GetPoint("Pick a marker point")
rs.AddPoint(p.x, p.y, p.z)
print(string.format("picked point %.0f,%.0f,%.0f", p.x, p.y, p.z))
rs.UnselectAllObjects()
rs.SelectObject(widget)
print("selected by name lookup: " .. tostring(#rs.ObjectsByName("Widget")))
-- Regression for a real bug: dino8.constraints lives in the document's own
-- user-text, so a crafted/corrupted .3dm can set it to anything.
-- LoadConstraints must drop any constraint whose points/radius_objects are
-- shorter than what BuildResiduals actually indexes for its type, not
-- crash on it. Each of these three is short by exactly what its type
-- needs (Parallel needs 4 points, Radius needs 1 radius_object,
-- EqualRadius needs 2) - all three must be silently dropped.
rs.SetDocumentUserText("dino8.constraints",
  '[{"id":99,"type":"Parallel","points":[{"o":1,"i":0}]},' ..
  '{"id":100,"type":"Radius","radius_objects":[]},' ..
  '{"id":101,"type":"EqualRadius","radius_objects":[5]}]')
LUA
sed "s|@TMP@|$TMPW|g" "$HERE/script_script.txt" > "$TMPW/script_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SC="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/script_script.txt" 2>&1)" || { echo "$SC"; echo "FAIL: script script exited non-zero"; exit 1; }
else
  SC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/script_script.txt" 2>&1)" || { echo "$SC"; echo "FAIL: script script exited non-zero"; exit 1; }
fi
echo "$SC" | grep -E "^(ok|FAIL)"
if echo "$SC" | grep -q "^FAIL"; then fail=1; fi
sccheck() { if echo "$SC" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SC" "$1"; fail=1; fi; }
sccheck "history: inline curve length 5.00" "the \"= expr\" command line ran Lua inline (3-4-5 triangle)"
sccheck "history: bbox min 0,0,0" "RunScript's rs.BoundingBox reported the box's own corner"
sccheck "history: bbox max 10,10,13" "RunScript's rs.BoundingBox included the raised, unioned sphere"
sccheck "history: widget volume" "RunScript's rs.SurfaceVolume reported the unioned solid's volume"
sccheck "history: picked point 20,20,20" "rs.GetPoint was fed by the trailing script token"
sccheck "^ok   expect_objects 1" "the inline Lua expression added exactly the one line"
sccheck "^ok   expect_objects 3" "RunScript left the union, its point marker, and the earlier line"
sccheck "selected by name lookup: 1" "rs.ObjectsByName found the object rs.ObjectName renamed to Widget"
grep -q "! Script error" <<<"$SC" && { echo "FAIL script.txt printed a script error"; fail=1; } || echo "ok   no Lua script errors"
sccheck "history: Constraints (0):" "LoadConstraints dropped all 3 malformed constraints (Parallel/Radius/EqualRadius each short exactly the point/radius_object count BuildResiduals indexes) instead of an out-of-bounds vector read"
sccheck "history: ConstraintSolve: converged" "ConstraintSolve ran cleanly against the now-empty constraint list, not a crash"

# Python scripting: RunPythonScript through the embedded `dino8` module
# (see src/script/PythonEngine.cpp), when this build was compiled with a
# Python 3 development install (DINO8_HAVE_PYTHON - see CMakeLists.txt).
# Builds a box and a sphere, sets Name/Color on the box (and reads its
# Layer), selects it, deletes the sphere, and exercises dino8.RunCommand,
# Point3d/Vector3d arithmetic, and - like script_script.txt's Lua test -
# dino8.GetPoint() and dino8.GetString(), each fed by its own trailing
# script token in turn (python_script.txt's own header), now that
# PythonEngine actually suspends for them (worker thread, not a coroutine -
# see PythonEngine.h).
#
# dino8.RunCommand only *queues* a nested command line while called from
# inside another command's callback (CommandEngine::RunNested -> Execute,
# see cmd_misc.cpp/CommandEngine.cpp: callback_depth_ > 0 defers it to
# deferred_, run once the calling command finishes) - the same as Lua's
# rs.Command would if it were called from inside a running rs.* script.
# So NewLayer's effect is not visible to the rest of *this* script; it
# runs right after RunPythonScript's own command finishes instead, which
# is why the layer check below reads the pre-existing "Default" layer and
# the RunCommand check greps the run's full output rather than "history:
# layer: Parts" inline.
cat > "$TMPW/t.py" <<'PY'
import dino8

box_id = dino8.doc.Objects.AddBox(dino8.Point3d(0, 0, 0), dino8.Vector3d(10, 10, 10))
sphere_id = dino8.doc.Objects.AddSphere(dino8.Point3d(5, 5, 5), 2)

obj = dino8.doc.Objects.Find(box_id)
obj.Name = "Widget"
obj.Color = (255, 0, 0)
print("name: " + obj.Name)
print("layer: " + obj.Layer)
print("color: %d,%d,%d" % obj.Color)
print("kind: " + obj.ObjectType)

obj.Select()
print("selected count: %d" % len(dino8.doc.Objects.GetSelectedObjects()))
print("object count before delete: %d" % len(dino8.doc.Objects.AllObjects()))

deleted = dino8.doc.Objects.Delete(sphere_id)
print("deleted sphere: " + str(deleted))
print("object count after delete: %d" % len(dino8.doc.Objects.AllObjects()))

v = dino8.Vector3d(3, 4, 0)
print("vector length: %.2f" % v.Length)
p1 = dino8.Point3d(1, 2, 3)
p2 = p1 + v
print("point plus vector: %.0f,%.0f,%.0f" % (p2.X, p2.Y, p2.Z))

by_name = [o for o in dino8.doc.Objects.AllObjects() if o.Name == "Widget"]
print("found by name: %d" % len(by_name))

circle_id = dino8.doc.Objects.AddCircle(dino8.Point3d(0, 0, 0), 3)
circle = dino8.doc.Objects.Find(circle_id)
print("circle kind: " + circle.ObjectType)
print("object count with circle: %d" % len(dino8.doc.Objects.AllObjects()))
try:
    dino8.doc.Objects.AddCircle(dino8.Point3d(0, 0, 0), -1)
    print("bad circle: no error")
except RuntimeError as e:
    print("bad circle rejected: " + str(e))

cone_id = dino8.doc.Objects.AddCone(dino8.Point3d(0, 0, 0), dino8.Vector3d(0, 0, 5), 2)
cone = dino8.doc.Objects.Find(cone_id)
print("cone kind: " + cone.ObjectType)
print("object count with cone: %d" % len(dino8.doc.Objects.AllObjects()))
try:
    dino8.doc.Objects.AddCone(dino8.Point3d(0, 0, 0), dino8.Vector3d(0, 0, 5), -1)
    print("bad cone: no error")
except RuntimeError as e:
    print("bad cone rejected: " + str(e))

torus_id = dino8.doc.Objects.AddTorus(dino8.Point3d(0, 0, 0), 5, 2)
torus = dino8.doc.Objects.Find(torus_id)
print("torus kind: " + torus.ObjectType)
print("object count with torus: %d" % len(dino8.doc.Objects.AllObjects()))
try:
    dino8.doc.Objects.AddTorus(dino8.Point3d(0, 0, 0), 2, 5)
    print("bad torus: no error")
except RuntimeError as e:
    print("bad torus rejected: " + str(e))

interp_id = dino8.doc.Objects.AddInterpCurve([dino8.Point3d(0, 0, 0), dino8.Point3d(5, 5, 0), dino8.Point3d(10, 0, 0), dino8.Point3d(15, 5, 0)])
interp = dino8.doc.Objects.Find(interp_id)
print("interp kind: " + interp.ObjectType)
print("object count with interp: %d" % len(dino8.doc.Objects.AllObjects()))
too_few = dino8.doc.Objects.AddInterpCurve([dino8.Point3d(0, 0, 0)])
print("interp with one point: " + str(too_few))

arc_id = dino8.doc.Objects.AddArc3Pt(dino8.Point3d(0, 0, 0), dino8.Point3d(10, 0, 0), dino8.Point3d(5, 5, 0))
arc = dino8.doc.Objects.Find(arc_id)
print("arc kind: " + arc.ObjectType)
print("object count with arc: %d" % len(dino8.doc.Objects.AllObjects()))
bad_arc = dino8.doc.Objects.AddArc3Pt(dino8.Point3d(0, 0, 0), dino8.Point3d(10, 0, 0), dino8.Point3d(5, 0, 0))
print("collinear arc: " + str(bad_arc))

srf_id = dino8.doc.Objects.AddSrfPt([dino8.Point3d(0, 0, 0), dino8.Point3d(10, 0, 0), dino8.Point3d(10, 10, 0), dino8.Point3d(0, 10, 0)])
srf = dino8.doc.Objects.Find(srf_id)
print("srf kind: " + srf.ObjectType)
print("object count with srf: %d" % len(dino8.doc.Objects.AllObjects()))
try:
    dino8.doc.Objects.AddSrfPt([dino8.Point3d(0, 0, 0), dino8.Point3d(10, 0, 0)])
    print("bad srf: no error")
except RuntimeError as e:
    print("bad srf rejected: " + str(e))

planar_ids = dino8.doc.Objects.AddPlanarSrf([circle_id])
planar = dino8.doc.Objects.Find(planar_ids[0])
print("planar kind: " + planar.ObjectType)
print("object count with planar: %d" % len(dino8.doc.Objects.AllObjects()))
no_planar = dino8.doc.Objects.AddPlanarSrf([box_id])
print("planar from non-curve: " + str(no_planar))

points_ids = dino8.doc.Objects.AddPoints([dino8.Point3d(0, 0, 0), dino8.Point3d(1, 1, 1), dino8.Point3d(2, 2, 2)])
print("points count: %d" % len(points_ids))
point0 = dino8.doc.Objects.Find(points_ids[0])
print("point kind: " + point0.ObjectType)
print("object count with points: %d" % len(dino8.doc.Objects.AllObjects()))
empty_points = dino8.doc.Objects.AddPoints([])
print("empty points: " + str(empty_points))

extrude_line_id = dino8.doc.Objects.AddLine(dino8.Point3d(0, 0, 0), dino8.Point3d(5, 0, 0))
extrude_id = dino8.doc.Objects.ExtrudeCurveStraight(extrude_line_id, dino8.Vector3d(0, 0, 3))
extrude = dino8.doc.Objects.Find(extrude_id)
print("extrude kind: " + extrude.ObjectType)
print("object count with extrude: %d" % len(dino8.doc.Objects.AllObjects()))
extrude_solid_id = dino8.doc.Objects.ExtrudeCurveStraight(circle_id, dino8.Vector3d(0, 0, 4))
extrude_solid = dino8.doc.Objects.Find(extrude_solid_id)
print("extrude solid kind: " + extrude_solid.ObjectType)
try:
    dino8.doc.Objects.ExtrudeCurveStraight(extrude_line_id, dino8.Vector3d(0, 0, 0))
    print("bad extrude: no error")
except RuntimeError as e:
    print("bad extrude rejected: " + str(e))
try:
    dino8.doc.Objects.ExtrudeCurveStraight(box_id, dino8.Vector3d(0, 0, 1))
    print("extrude non-curve: no error")
except RuntimeError as e:
    print("extrude non-curve rejected: " + str(e))
print("object count with extrude solid: %d" % len(dino8.doc.Objects.AllObjects()))

union_a = dino8.doc.Objects.AddBox(dino8.Point3d(20, 0, 0), dino8.Vector3d(4, 4, 4))
union_b = dino8.doc.Objects.AddBox(dino8.Point3d(22, 0, 0), dino8.Vector3d(4, 4, 4))
union_ids = dino8.doc.Objects.BooleanUnion([union_a, union_b])
union_obj = dino8.doc.Objects.Find(union_ids[0])
print("union kind: " + union_obj.ObjectType)
print("union input deleted: " + str(dino8.doc.Objects.Find(union_a) is None))
print("object count with union: %d" % len(dino8.doc.Objects.AllObjects()))
no_union = dino8.doc.Objects.BooleanUnion([extrude_line_id])
print("union from non-solid: " + str(no_union))

diff_a = dino8.doc.Objects.AddBox(dino8.Point3d(30, 0, 0), dino8.Vector3d(4, 4, 4))
diff_b = dino8.doc.Objects.AddBox(dino8.Point3d(32, 0, 0), dino8.Vector3d(4, 4, 4))
diff_ids = dino8.doc.Objects.BooleanDifference([diff_a], [diff_b])
diff_obj = dino8.doc.Objects.Find(diff_ids[0])
print("difference kind: " + diff_obj.ObjectType)
print("difference input deleted: " + str(dino8.doc.Objects.Find(diff_a) is None))
print("object count with difference: %d" % len(dino8.doc.Objects.AllObjects()))
no_difference = dino8.doc.Objects.BooleanDifference([extrude_line_id], [union_ids[0]])
print("difference from non-solid: " + str(no_difference))

inter_a = dino8.doc.Objects.AddBox(dino8.Point3d(40, 0, 0), dino8.Vector3d(4, 4, 4))
inter_b = dino8.doc.Objects.AddBox(dino8.Point3d(42, 0, 0), dino8.Vector3d(4, 4, 4))
inter_ids = dino8.doc.Objects.BooleanIntersection([inter_a], [inter_b])
inter_obj = dino8.doc.Objects.Find(inter_ids[0])
print("intersection kind: " + inter_obj.ObjectType)
print("intersection input deleted: " + str(dino8.doc.Objects.Find(inter_a) is None))
print("object count with intersection: %d" % len(dino8.doc.Objects.AllObjects()))
no_intersection = dino8.doc.Objects.BooleanIntersection([extrude_line_id], [union_ids[0]])
print("intersection from non-solid: " + str(no_intersection))

move_ids = dino8.doc.Objects.MoveObject([circle_id], dino8.Vector3d(100, 0, 0))
print("move returned circle id: " + str(move_ids == [circle_id]))
print("move missing skipped: " + str(dino8.doc.Objects.MoveObject([999999], dino8.Vector3d(1, 0, 0))))
print("object count with move: %d" % len(dino8.doc.Objects.AllObjects()))

copy_ids = dino8.doc.Objects.CopyObject([circle_id])
print("copy is new id: " + str(len(copy_ids) == 1 and copy_ids[0] != circle_id))
print("copy original survives: " + str(dino8.doc.Objects.Find(circle_id) is not None))
print("object count with copy: %d" % len(dino8.doc.Objects.AllObjects()))
copy_moved_ids = dino8.doc.Objects.CopyObject([circle_id], dino8.Vector3d(200, 0, 0))
print("object count with copy moved: %d" % len(dino8.doc.Objects.AllObjects()))
print("copy missing skipped: " + str(dino8.doc.Objects.CopyObject([999999])))

rotate_line_id = dino8.doc.Objects.AddLine(dino8.Point3d(1, 0, 0), dino8.Point3d(2, 0, 0))
rotate_ids = dino8.doc.Objects.RotateObject([rotate_line_id], dino8.Point3d(0, 0, 0), 90)
print("rotate returned same id: " + str(rotate_ids == [rotate_line_id]))
print("object count with rotate: %d" % len(dino8.doc.Objects.AllObjects()))
rotate_copy_ids = dino8.doc.Objects.RotateObject([rotate_line_id], dino8.Point3d(0, 0, 0), 45, dino8.Vector3d(0, 0, 1), True)
print("rotate copy is new id: " + str(len(rotate_copy_ids) == 1 and rotate_copy_ids[0] != rotate_line_id))
print("object count with rotate copy: %d" % len(dino8.doc.Objects.AllObjects()))
print("rotate missing skipped: " + str(dino8.doc.Objects.RotateObject([999999], dino8.Point3d(0, 0, 0), 90)))

scale_box_id = dino8.doc.Objects.AddBox(dino8.Point3d(50, 0, 0), dino8.Vector3d(2, 2, 2))
scale_ids = dino8.doc.Objects.ScaleObject([scale_box_id], dino8.Point3d(50, 0, 0), dino8.Vector3d(2, 2, 2))
print("scale returned same id: " + str(scale_ids == [scale_box_id]))
print("object count with scale: %d" % len(dino8.doc.Objects.AllObjects()))
scale_copy_ids = dino8.doc.Objects.ScaleObject([scale_box_id], dino8.Point3d(50, 0, 0), dino8.Vector3d(2, 2, 2), True)
print("scale copy is new id: " + str(len(scale_copy_ids) == 1 and scale_copy_ids[0] != scale_box_id))
print("object count with scale copy: %d" % len(dino8.doc.Objects.AllObjects()))
print("scale missing skipped: " + str(dino8.doc.Objects.ScaleObject([999999], dino8.Point3d(0, 0, 0), dino8.Vector3d(2, 2, 2))))

mirror_line_id = dino8.doc.Objects.AddLine(dino8.Point3d(60, 0, 0), dino8.Point3d(61, 0, 0))
mirror_ids = dino8.doc.Objects.MirrorObject([mirror_line_id], dino8.Point3d(0, 0, 0), dino8.Point3d(0, 1, 0))
print("mirror returned same id: " + str(mirror_ids == [mirror_line_id]))
print("object count with mirror: %d" % len(dino8.doc.Objects.AllObjects()))
mirror_copy_ids = dino8.doc.Objects.MirrorObject([mirror_line_id], dino8.Point3d(0, 0, 0), dino8.Point3d(0, 1, 0), True)
print("mirror copy is new id: " + str(len(mirror_copy_ids) == 1 and mirror_copy_ids[0] != mirror_line_id))
print("object count with mirror copy: %d" % len(dino8.doc.Objects.AllObjects()))
print("mirror missing skipped: " + str(dino8.doc.Objects.MirrorObject([999999], dino8.Point3d(0, 0, 0), dino8.Point3d(0, 1, 0))))
try:
    dino8.doc.Objects.MirrorObject([mirror_line_id], dino8.Point3d(0, 0, 0), dino8.Point3d(0, 0, 1))
    print("bad mirror: no error")
except RuntimeError as e:
    print("bad mirror rejected: " + str(e))

transform_line_id = dino8.doc.Objects.AddLine(dino8.Point3d(70, 0, 0), dino8.Point3d(71, 0, 0))
print("object count with transform line: %d" % len(dino8.doc.Objects.AllObjects()))
translate_xf = [[1, 0, 0, 5], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
transform_ids = dino8.doc.Objects.TransformObject([transform_line_id], translate_xf)
print("transform returned same id: " + str(transform_ids == [transform_line_id]))
print("object count with transform: %d" % len(dino8.doc.Objects.AllObjects()))
transform_copy_ids = dino8.doc.Objects.TransformObject([transform_line_id], translate_xf, True)
print("transform copy is new id: " + str(len(transform_copy_ids) == 1 and transform_copy_ids[0] != transform_line_id))
print("object count with transform copy: %d" % len(dino8.doc.Objects.AllObjects()))
print("transform missing skipped: " + str(dino8.doc.Objects.TransformObject([999999], translate_xf)))
try:
    dino8.doc.Objects.TransformObject([transform_line_id], [[1, 0, 0], [0, 1, 0]])
    print("bad transform: no error")
except RuntimeError as e:
    print("bad transform rejected: " + str(e))

by_layer = dino8.doc.Objects.ObjectsByLayer("Default")
print("objects by layer matches all: " + str(len(by_layer) == len(dino8.doc.Objects.AllObjects())))
try:
    dino8.doc.Objects.ObjectsByLayer("NoSuchLayer")
    print("bad layer: no error")
except RuntimeError as e:
    print("bad layer rejected: " + str(e))

select_count = dino8.doc.Objects.SelectObject([mirror_line_id, circle_id])
print("select count: %d" % select_count)
print("selected after select: %d" % len(dino8.doc.Objects.GetSelectedObjects()))
unselect_count = dino8.doc.Objects.UnselectObject([mirror_line_id, circle_id])
print("unselect returned count: %d" % unselect_count)
print("selected after unselect: %d" % len(dino8.doc.Objects.GetSelectedObjects()))

dino8.doc.Objects.SelectObject([transform_line_id])
unselect_all_count = dino8.doc.Objects.UnselectAllObjects()
print("unselect all count: %d" % unselect_all_count)
print("selected after unselect all: %d" % len(dino8.doc.Objects.GetSelectedObjects()))

# Curve/surface/mesh query and layer-management bindings, added to close
# ground on PARITY_MAP.md's "Python API breadth" item (dino8.doc.Objects.
# CurveLength/CurveDomain/EvaluateCurve/CurveClosestPoint/DivideCurve/
# SurfaceArea/SurfaceVolume/IsObjectSolid/SurfaceClosestPoint/MeshVertices/
# ObjectsByName/ObjectsByType/BoundingBox and dino8.doc.Layers, all matching
# their LuaEngine.cpp rs.* counterparts, that the dino8 module also lacked
# until now). Built off in its own coordinate range (x>=100) so it can't
# overlap the geometry built above.
cq_line_id = dino8.doc.Objects.AddLine(dino8.Point3d(100, 0, 0), dino8.Point3d(103, 4, 0))
print("object count with cq line: %d" % len(dino8.doc.Objects.AllObjects()))
print("curve length: %.2f" % dino8.doc.Objects.CurveLength(cq_line_id))
dom = dino8.doc.Objects.CurveDomain(cq_line_id)
print("curve domain: %.1f,%.1f" % (dom[0], dom[1]))
end_pt = dino8.doc.Objects.EvaluateCurve(cq_line_id, dom[1])
print("evaluate curve at end: %.0f,%.0f,%.0f" % (end_pt.X, end_pt.Y, end_pt.Z))
print("curve closest point at start: %.1f" % dino8.doc.Objects.CurveClosestPoint(cq_line_id, dino8.Point3d(100, 0, 0)))
div_pts = dino8.doc.Objects.DivideCurve(cq_line_id, 4)
print("divide curve point count: %d" % len(div_pts))
print("divide curve first point: %.0f,%.0f,%.0f" % (div_pts[0].X, div_pts[0].Y, div_pts[0].Z))
print("divide curve last point: %.0f,%.0f,%.0f" % (div_pts[-1].X, div_pts[-1].Y, div_pts[-1].Z))
div_params = dino8.doc.Objects.DivideCurve(cq_line_id, 4, False, False)
print("divide curve params: " + ",".join("%.2f" % p for p in div_params))
try:
    dino8.doc.Objects.DivideCurve(cq_line_id, 0)
    print("bad divide: no error")
except RuntimeError as e:
    print("bad divide rejected: " + str(e))
div_created = dino8.doc.Objects.DivideCurve(cq_line_id, 2, True)
print("divide curve created point count: %d" % len(div_created))
print("object count with divide created points: %d" % len(dino8.doc.Objects.AllObjects()))

bbox_box_id = dino8.doc.Objects.AddBox(dino8.Point3d(200, 0, 0), dino8.Vector3d(5, 5, 5))
print("object count with bbox box: %d" % len(dino8.doc.Objects.AllObjects()))
bbox = dino8.doc.Objects.BoundingBox([bbox_box_id])
print("bounding box corner0: %.0f,%.0f,%.0f" % (bbox[0].X, bbox[0].Y, bbox[0].Z))
print("bounding box corner6: %.0f,%.0f,%.0f" % (bbox[6].X, bbox[6].Y, bbox[6].Z))
print("bounding box missing: " + str(dino8.doc.Objects.BoundingBox([999999])))
print("surface area box: %.1f" % dino8.doc.Objects.SurfaceArea(bbox_box_id))
print("surface volume box: %.1f" % dino8.doc.Objects.SurfaceVolume(bbox_box_id))
print("is object solid box: " + str(dino8.doc.Objects.IsObjectSolid(bbox_box_id)))
print("is object solid line: " + str(dino8.doc.Objects.IsObjectSolid(cq_line_id)))
print("surface volume line: " + str(dino8.doc.Objects.SurfaceVolume(cq_line_id)))

sc_sphere_id = dino8.doc.Objects.AddSphere(dino8.Point3d(300, 0, 0), 4)
print("object count with sc sphere: %d" % len(dino8.doc.Objects.AllObjects()))
closest = dino8.doc.Objects.SurfaceClosestPoint(sc_sphere_id, dino8.Point3d(300, 0, 10))
print("surface closest point: %.0f,%.0f,%.0f" % (closest.X, closest.Y, closest.Z))

mesh_id = dino8.doc.Objects.AddMesh([dino8.Point3d(400, 0, 0), dino8.Point3d(401, 0, 0), dino8.Point3d(400, 1, 0)], [[0, 1, 2]])
print("object count with mesh: %d" % len(dino8.doc.Objects.AllObjects()))
mesh_verts = dino8.doc.Objects.MeshVertices(mesh_id)
print("mesh vertices count: %d" % len(mesh_verts))
print("mesh vertex 0: %.0f,%.0f,%.0f" % (mesh_verts[0].X, mesh_verts[0].Y, mesh_verts[0].Z))

by_name_widget = dino8.doc.Objects.ObjectsByName("Widget")
print("objects by name widget: " + str(len(by_name_widget) == 1 and by_name_widget[0].Id == box_id))
print("objects by name none: " + str(dino8.doc.Objects.ObjectsByName("NoSuchNameXYZ")))
dino8.doc.Objects.UnselectAllObjects()
dino8.doc.Objects.ObjectsByName("Widget", True)
print("objects by name select side effect: " + str(obj.IsSelected))

type_before = len(dino8.doc.Objects.ObjectsByType("point"))
fresh_pt_a = dino8.doc.Objects.AddPoint(500, 0, 0)
fresh_pt_b = dino8.doc.Objects.AddPoint(501, 0, 0)
print("object count with fresh points: %d" % len(dino8.doc.Objects.AllObjects()))
type_after_ids = [o.Id for o in dino8.doc.Objects.ObjectsByType("point")]
print("objects by type point delta: %d" % (len(dino8.doc.Objects.ObjectsByType("point")) - type_before))
print("objects by type point contains fresh: " + str(fresh_pt_a in type_after_ids and fresh_pt_b in type_after_ids))
print("objects by type none equals all objects: " + str(len(dino8.doc.Objects.ObjectsByType()) == len(dino8.doc.Objects.AllObjects())))
dino8.doc.Objects.UnselectAllObjects()
dino8.doc.Objects.ObjectsByType("point", True)
print("objects by type select side effect: " + str(dino8.doc.Objects.Find(fresh_pt_a).IsSelected))

print("layers count before: %d" % dino8.doc.Layers.Count())
qc_layer_name = dino8.doc.Layers.Add("QCLayer", (0, 200, 100), True, False)
print("layers add returned name: " + qc_layer_name)
print("layers count after add: %d" % dino8.doc.Layers.Count())
print("layers names include new: " + str("QCLayer" in dino8.doc.Layers.Names()))
print("layers is layer: " + str(dino8.doc.Layers.IsLayer("QCLayer")))
print("layers is layer bogus: " + str(dino8.doc.Layers.IsLayer("NoSuchLayerXYZ")))
print("layers visible: " + str(dino8.doc.Layers.Visible("QCLayer")))
dino8.doc.Layers.SetVisible("QCLayer", False)
print("layers visible after set: " + str(dino8.doc.Layers.Visible("QCLayer")))
print("layers locked: " + str(dino8.doc.Layers.Locked("QCLayer")))
dino8.doc.Layers.SetLocked("QCLayer", True)
print("layers locked after set: " + str(dino8.doc.Layers.Locked("QCLayer")))
print("layers color: %d,%d,%d" % dino8.doc.Layers.Color("QCLayer"))
dino8.doc.Layers.SetColor("QCLayer", (10, 20, 30))
print("layers color after set: %d,%d,%d" % dino8.doc.Layers.Color("QCLayer"))
print("layers current before: " + dino8.doc.Layers.CurrentLayer)
dino8.doc.Layers.CurrentLayer = "QCLayer"
print("layers current after set: " + dino8.doc.Layers.CurrentLayer)
print("layers delete while current refused: " + str(dino8.doc.Layers.Delete("QCLayer") == False))
dino8.doc.Layers.CurrentLayer = "Default"
print("layers delete after switch: " + str(dino8.doc.Layers.Delete("QCLayer")))
print("layers count final: %d" % dino8.doc.Layers.Count())
print("layers is layer after delete: " + str(dino8.doc.Layers.IsLayer("QCLayer")))

dino8.RunCommand("NewLayer", "Parts")

print("unit system before: %d" % dino8.doc.UnitSystem)
dino8.doc.UnitSystem = "Feet"
print("unit system after set by name: %d" % dino8.doc.UnitSystem)
print("unit system name after set: " + dino8.doc.UnitSystemName)
dino8.doc.UnitSystem = 2
print("unit system after set by code: " + dino8.doc.UnitSystemName)

print("doc name: " + dino8.doc.Name)
print("doc path: " + str(dino8.doc.Path))
print("doc modified before: " + str(dino8.doc.Modified))
dino8.doc.Modified = False
print("doc modified after set: " + str(dino8.doc.Modified))
dino8.doc.Modified = True

print("object user text before set: " + str(obj.GetUserText()))
obj.SetUserText("Material", "Steel")
print("object user text value: " + str(obj.GetUserText("Material")))
print("object user text keys: " + str(obj.GetUserText()))
print("object user text missing key: " + str(obj.GetUserText("NoSuchKeyXYZ")))
obj.SetUserText("Material", None)
print("object user text after erase: " + str(obj.GetUserText("Material")))
print("object user text keys after erase: " + str(obj.GetUserText()))

print("document user text before set: " + str(dino8.doc.GetDocumentUserText()))
dino8.doc.SetDocumentUserText("Project", "Acme")
print("document user text value: " + str(dino8.doc.GetDocumentUserText("Project")))
print("document user text keys: " + str(dino8.doc.GetDocumentUserText()))
dino8.doc.SetDocumentUserText("Project", None)
print("document user text after erase: " + str(dino8.doc.GetDocumentUserText("Project")))

dino8.doc.BeginUndo("QCPointGroup")
undo_pt = dino8.doc.Objects.AddPoint(600, 0, 0)
print("object count before undo: %d" % len(dino8.doc.Objects.AllObjects()))
print("undo point present: " + str(dino8.doc.Objects.Find(undo_pt) is not None))
print("undo returned: " + str(dino8.doc.Undo()))
print("object count after undo: %d" % len(dino8.doc.Objects.AllObjects()))
print("undo point gone: " + str(dino8.doc.Objects.Find(undo_pt) is None))
print("redo returned: " + str(dino8.doc.Redo()))
print("object count after redo: %d" % len(dino8.doc.Objects.AllObjects()))
print("redo point back: " + str(dino8.doc.Objects.Find(undo_pt) is not None))
print("final undo returned: " + str(dino8.doc.Undo()))
print("object count after final undo: %d" % len(dino8.doc.Objects.AllObjects()))

print("last command name: " + dino8.LastCommandName())
print("version starts with Dino 8: " + str(dino8.Version().startswith("Dino 8 ")))
print("command history has last command: " + str(dino8.LastCommandName() in dino8.CommandHistory()))
dino8.ClearCommandHistory()
print("command history empty after clear: " + str(dino8.CommandHistory() == ""))
print("last command survives history clear: " + str(dino8.LastCommandName() == "RunPythonScript"))

# dino8.GetPoint: now a real mid-script suspend (PythonEngine runs the
# script on a worker thread - see PythonEngine.h), mirroring rs.GetPoint's
# own trailing-script-token feed (script_script.txt's "RunScript t.lua
# 20,20,20").
p = dino8.GetPoint("Pick a marker point")
print("picked point is None: " + str(p is None))
if p is not None:
    dino8.doc.Objects.AddPoint(p)
    print("picked point %.0f,%.0f,%.0f" % (p.X, p.Y, p.Z))
print("object count after GetPoint: %d" % len(dino8.doc.Objects.AllObjects()))

# dino8.GetString: mirrors rs.GetString, same worker-thread suspend as
# GetPoint above (see PythonEngine.h) - fed by the second trailing script
# token (python_script.txt's "RunPythonScript @TMP@/t.py 20,20,20 Widget2").
name = dino8.GetString("Name the marker point")
print("got string: " + str(name))

# dino8.GetReal/dino8.GetInteger: mirror rs.GetReal/rs.GetInteger, the same
# worker-thread suspend as GetPoint/GetString above (see PythonEngine.h) -
# previously entirely unported (PARITY_MAP.md's app_scripting row named
# this exact gap). Fed by the third and fourth trailing script tokens.
radius = dino8.GetReal("Pick a radius")
print("got real: " + str(radius))
count = dino8.GetInteger("Pick a count")
print("got integer: " + str(count))
print("got integer is int: " + str(isinstance(count, int)))

# dino8.GetObjects/dino8.GetObject: mirror rs.GetObjects/rs.GetObject, the
# same worker-thread suspend - also previously entirely unported. Unlike
# Point/String/Real/Integer there is no plain command-line token that means
# "pick these objects"; CommandEngine's own Want::Objects handling instead
# accepts a nested Sel* command fed as a token (here, SelAll) followed by
# Enter to hand the resulting selection to OnObjects (see
# CommandEngine.cpp's FeedText/FeedEnter Want::Objects branches) - the exact
# mechanism script_script.txt's Lua test never needed to exercise, so this
# is new coverage for that path too, not just for Python. Each call
# deliberately unselects everything right before suspending so the
# command's own "already-selected objects are accepted immediately"
# shortcut (CommandEngine::AfterCallback's preselection check) can't
# short-circuit the very SelAll/Enter tokens below meant for it.
dino8.doc.Objects.UnselectAllObjects()
objs = dino8.GetObjects("Select objects")
print("got objects count: %d" % len(objs))
print("got objects are ints: " + str(all(isinstance(o, int) for o in objs)))

dino8.doc.Objects.UnselectAllObjects()
one = dino8.GetObject("Select one object")
print("got object is int: " + str(isinstance(one, int)))
print("got object is one of objs: " + str(one in objs))

dino8.doc.Objects.UnselectAllObjects()
empty_objs = dino8.GetObjects("Select more objects (press Enter for none)")
print("got empty objects: " + str(empty_objs == []))

none_obj = dino8.GetObject("Select another object (press Enter for none)")
print("got none object: " + str(none_obj is None))
PY
sed "s|@TMP@|$TMPW|g" "$HERE/python_script.txt" > "$TMPW/python_script.txt"
# Captured with set +e, not "|| { ...; exit 1; }": python_script.txt's own
# final "@expect_objects 1" line assumes the earlier Python commands
# actually ran and created that object, so on a build without Python
# (DINO8_ENABLE_PYTHON=OFF - see CMakeLists.txt) main.cpp's own
# expect_objects handler makes the whole process exit non-zero even though
# RunPythonScript itself printed a normal, honest "not available" warning
# and did not crash. An immediate "||" here can never reach the skip check
# below it, since bash already took the "failed" branch by the time that
# check would run - exactly what broke this section on Windows once
# DINO8_ENABLE_PYTHON defaulted OFF there. Checking the exit code
# ourselves, after first checking for the expected message, keeps a
# genuine crash a hard failure while treating the expected skip as one.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  set +e; PS="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/python_script.txt" 2>&1)"; ps_ec=$?; set -e
else
  set +e; PS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/python_script.txt" 2>&1)"; ps_ec=$?; set -e
fi
# Matches every "Python unavailable" message this build prints (they don't
# all share the same word order - RunPythonScript's own says "without a
# Python 3 development install", others say "no Python 3 development
# install" - but all three name it this way; see cmd_misc.cpp).
if echo "$PS" | grep -q "Python 3 development install"; then
  echo "skip Python scripting not available in this build (compiled without Python3 Development.Embed - see CMakeLists.txt)"
elif [ "$ps_ec" -ne 0 ]; then
  echo "$PS"; echo "FAIL: python script exited non-zero"; exit 1
else
  echo "$PS" | grep -E "^(ok|FAIL)"
  if echo "$PS" | grep -q "^FAIL"; then fail=1; fi
  pscheck() { if echo "$PS" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PS" "$1"; fail=1; fi; }
  pscheck "history: name: Widget" "RunPythonScript's Dino8Object.Name getter/setter round-tripped"
  pscheck "history: layer: Default" "Dino8Object.Layer read back the box's layer"
  pscheck "Layer 'Parts' created and made current" "dino8.RunCommand(\"NewLayer\", \"Parts\") ran the real NewLayer command (deferred until RunPythonScript's own command finished, same as rs.Command would be)"
  pscheck "history: color: 255,0,0" "Dino8Object.Color setter/getter round-tripped"
  pscheck "history: kind: polysurface" "Dino8Object.ObjectType reported the box as a polysurface"
  pscheck "history: selected count: 1" "Dino8Object.Select() selected the box"
  pscheck "history: object count before delete: 2" "AllObjects saw both the box and the sphere"
  pscheck "history: deleted sphere: True" "dino8.doc.Objects.Delete removed the sphere"
  pscheck "history: object count after delete: 1" "AllObjects reflects the deletion"
  pscheck "history: vector length: 5.00" "Vector3d.Length computed a 3-4-5 triangle"
  pscheck "history: point plus vector: 4,6,3" "Point3d.__add__(Vector3d) matched RhinoCommon's operator+"
  pscheck "history: found by name: 1" "list comprehension over AllObjects() found the renamed box"
  pscheck "history: circle kind: curve" "dino8.doc.Objects.AddCircle built a curve object, matching rs.AddCircle"
  pscheck "history: object count with circle: 2" "AllObjects sees the box and the new circle"
  pscheck "history: bad circle rejected:" "AddCircle raised a Python exception for a non-positive radius instead of silently returning"
  pscheck "history: cone kind: polysurface" "dino8.doc.Objects.AddCone built a polysurface object, matching rs.AddCone"
  pscheck "history: object count with cone: 3" "AllObjects sees the box, the circle and the new cone"
  pscheck "history: bad cone rejected:" "AddCone raised a Python exception for a non-positive radius instead of silently returning"
  pscheck "history: torus kind: polysurface" "dino8.doc.Objects.AddTorus built a polysurface object, matching rs.AddTorus"
  pscheck "history: object count with torus: 4" "AllObjects sees the box, the circle, the cone and the new torus"
  pscheck "history: bad torus rejected:" "AddTorus raised a Python exception for a minor radius that isn't smaller than the major radius, instead of silently returning"
  pscheck "history: interp kind: curve" "dino8.doc.Objects.AddInterpCurve built a curve object, matching rs.AddInterpCurve"
  pscheck "history: object count with interp: 5" "AllObjects sees the box, the circle, the cone, the torus and the new interpolated curve"
  pscheck "history: interp with one point: None" "AddInterpCurve returned None for fewer than two points, matching rs.AddInterpCurve pushing nil instead of raising"
  pscheck "history: arc kind: curve" "dino8.doc.Objects.AddArc3Pt built a curve object, matching rs.AddArc3Pt"
  pscheck "history: object count with arc: 6" "AllObjects sees the box, the circle, the cone, the torus, the interpolated curve and the new arc"
  pscheck "history: collinear arc: None" "AddArc3Pt returned None for three collinear points, matching rs.AddArc3Pt pushing nil instead of raising"
  pscheck "history: srf kind: surface" "dino8.doc.Objects.AddSrfPt built a surface object, matching rs.AddSrfPt"
  pscheck "history: object count with srf: 7" "AllObjects sees the box, the circle, the cone, the torus, the interpolated curve, the arc and the new surface"
  pscheck "history: bad srf rejected:" "AddSrfPt raised a Python exception for fewer than three corner points, instead of silently returning"
  pscheck "history: planar kind: polysurface" "dino8.doc.Objects.AddPlanarSrf built a trimmed planar brep from the closed circle, matching rs.AddPlanarSrf (Brep-kind objects report as polysurface regardless of face count, same as AddBox/AddCone/AddTorus)"
  pscheck "history: object count with planar: 8" "AllObjects sees the box, the circle, the cone, the torus, the interpolated curve, the arc, the srf and the new planar surface"
  pscheck "history: planar from non-curve: None" "AddPlanarSrf returned None when none of the ids were closed planar curves, matching rs.AddPlanarSrf pushing nil instead of raising"
  pscheck "history: points count: 3" "dino8.doc.Objects.AddPoints added one point object per input point, matching rs.AddPoints"
  pscheck "history: point kind: point" "the first AddPoints id round-trips through Find as a point object"
  pscheck "history: object count with points: 11" "AllObjects sees the box, the circle, the cone, the torus, the interpolated curve, the arc, the srf, the planar surface and the three new points"
  pscheck "history: empty points: \[\]" "AddPoints returned an empty list (never None) for an empty input, matching rs.AddPoints always pushing a table"
  pscheck "history: extrude kind: surface" "dino8.doc.Objects.ExtrudeCurveStraight extruded an open line into a surface, matching rs.ExtrudeCurveStraight"
  pscheck "history: object count with extrude: 13" "AllObjects gained the new line and its extruded surface"
  pscheck "history: extrude solid kind: polysurface" "ExtrudeCurveStraight on the closed planar circle built a capped solid, matching rs.ExtrudeCurveStraight's ExtrudeCrv rule"
  pscheck "history: bad extrude rejected:" "ExtrudeCurveStraight raised a Python exception for a zero-length direction instead of silently returning"
  pscheck "history: extrude non-curve rejected:" "ExtrudeCurveStraight raised a Python exception for a non-curve object instead of silently returning"
  pscheck "history: object count with extrude solid: 14" "AllObjects gained the capped solid from the circle extrusion"
  pscheck "history: union kind: mesh" "dino8.doc.Objects.BooleanUnion combined two overlapping boxes into one mesh solid, matching rs.BooleanUnion"
  pscheck "history: union input deleted: True" "BooleanUnion deleted its input solids by default, matching rs.BooleanUnion(ids, delete=true)"
  pscheck "history: object count with union: 15" "AllObjects lost the two input boxes and gained the one union mesh"
  pscheck "history: union from non-solid: None" "BooleanUnion returned None when the only id given was a curve, not a closed solid, matching rs.BooleanUnion pushing nil instead of raising"
  pscheck "history: difference kind: mesh" "dino8.doc.Objects.BooleanDifference subtracted one box from another into one mesh solid, matching rs.BooleanDifference"
  pscheck "history: difference input deleted: True" "BooleanDifference deleted its input solids by default, matching rs.BooleanDifference(ids, subtractIds, delete=true)"
  pscheck "history: object count with difference: 16" "AllObjects lost the two difference input boxes and gained the one difference mesh"
  pscheck "history: difference from non-solid: None" "BooleanDifference returned None when the first set's only id was a curve, not a closed solid, matching rs.BooleanDifference pushing nil instead of raising"
  pscheck "history: intersection kind: mesh" "dino8.doc.Objects.BooleanIntersection combined two overlapping boxes' common volume into one mesh solid, matching rs.BooleanIntersection"
  pscheck "history: intersection input deleted: True" "BooleanIntersection deleted its input solids by default, matching rs.BooleanIntersection(ids, otherIds, delete=true)"
  pscheck "history: object count with intersection: 17" "AllObjects lost the two intersection input boxes and gained the one intersection mesh"
  pscheck "history: intersection from non-solid: None" "BooleanIntersection returned None when the first set's only id was a curve, not a closed solid, matching rs.BooleanIntersection pushing nil instead of raising"
  pscheck "history: move returned circle id: True" "dino8.doc.Objects.MoveObject translated the circle in place and returned its own id back, matching rs.MoveObject"
  pscheck "history: move missing skipped: \[\]" "MoveObject returned an empty list for an id that no longer exists, matching LuaEngine.cpp's TransformIds skip-missing loop instead of raising"
  pscheck "history: object count with move: 17" "MoveObject translates objects in place, so AllObjects is unchanged by it"
  pscheck "history: copy is new id: True" "dino8.doc.Objects.CopyObject returned a single fresh id distinct from the source, matching rs.CopyObject"
  pscheck "history: copy original survives: True" "CopyObject left the source object in place, matching rs.CopyObject copying rather than moving"
  pscheck "history: object count with copy: 18" "AllObjects gained the untranslated copy of the circle"
  pscheck "history: object count with copy moved: 19" "AllObjects gained the second, translated copy of the circle"
  pscheck "history: copy missing skipped: \[\]" "CopyObject returned an empty list for an id that no longer exists, matching LuaEngine.cpp's TransformIds skip-missing loop instead of raising"
  pscheck "history: rotate returned same id: True" "dino8.doc.Objects.RotateObject rotated the line in place and returned its own id back, matching rs.RotateObject(id, center, angleDeg, axis, copy=false)"
  pscheck "history: object count with rotate: 20" "RotateObject without copy=True transforms in place, so AllObjects only gained the new line"
  pscheck "history: rotate copy is new id: True" "RotateObject with copy=True left the line in place and added a rotated duplicate under a fresh id, matching rs.RotateObject(id, center, angleDeg, axis, copy=true)"
  pscheck "history: object count with rotate copy: 21" "AllObjects gained the rotated copy of the line"
  pscheck "history: rotate missing skipped: \[\]" "RotateObject returned an empty list for an id that no longer exists, matching LuaEngine.cpp's TransformIds skip-missing loop instead of raising"
  pscheck "history: scale returned same id: True" "dino8.doc.Objects.ScaleObject scaled the box in place and returned its own id back, matching rs.ScaleObject(id, origin, scale, copy=false)"
  pscheck "history: object count with scale: 22" "ScaleObject without copy=True transforms in place, so AllObjects only gained the new box"
  pscheck "history: scale copy is new id: True" "ScaleObject with copy=True left the box in place and added a scaled duplicate under a fresh id, matching rs.ScaleObject(id, origin, scale, copy=true)"
  pscheck "history: object count with scale copy: 23" "AllObjects gained the scaled copy of the box"
  pscheck "history: scale missing skipped: \[\]" "ScaleObject returned an empty list for an id that no longer exists, matching LuaEngine.cpp's TransformIds skip-missing loop instead of raising"
  pscheck "history: mirror returned same id: True" "dino8.doc.Objects.MirrorObject mirrored the line in place and returned its own id back, matching rs.MirrorObject(id, start, end, copy=false)"
  pscheck "history: object count with mirror: 24" "MirrorObject without copy=True transforms in place, so AllObjects only gained the new line"
  pscheck "history: mirror copy is new id: True" "MirrorObject with copy=True left the line in place and added a mirrored duplicate under a fresh id, matching rs.MirrorObject(id, start, end, copy=true)"
  pscheck "history: object count with mirror copy: 25" "AllObjects gained the mirrored copy of the line"
  pscheck "history: mirror missing skipped: \[\]" "MirrorObject returned an empty list for an id that no longer exists, matching LuaEngine.cpp's TransformIds skip-missing loop instead of raising"
  pscheck "history: bad mirror rejected:" "MirrorObject raised a Python exception for a vertical mirror line instead of silently returning, matching rs.MirrorObject raising a Lua error"
  pscheck "history: object count with transform line: 26" "AllObjects gained the new transform line"
  pscheck "history: transform returned same id: True" "dino8.doc.Objects.TransformObject applied the 4x4 transform in place and returned its own id back, matching rs.TransformObject(id, xform, copy=false)"
  pscheck "history: object count with transform: 26" "TransformObject without copy=True transforms in place, so AllObjects is unchanged by it"
  pscheck "history: transform copy is new id: True" "TransformObject with copy=True left the line in place and added a transformed duplicate under a fresh id, matching rs.TransformObject(id, xform, copy=true)"
  pscheck "history: object count with transform copy: 27" "AllObjects gained the transformed copy of the line"
  pscheck "history: transform missing skipped: \[\]" "TransformObject returned an empty list for an id that no longer exists, matching LuaEngine.cpp's TransformIds skip-missing loop instead of raising"
  pscheck "history: bad transform rejected:" "TransformObject raised a Python exception for a malformed (non-4x4) transform instead of silently returning, matching rs.TransformObject's ToXform validation"
  pscheck "history: objects by layer matches all: True" "dino8.doc.Objects.ObjectsByLayer(\"Default\") found every object built so far, matching rs.ObjectsByLayer (everything is still on the Default layer - NewLayer's effect is deferred, see the comment above this script)"
  pscheck "history: bad layer rejected:" "ObjectsByLayer raised a Python exception for a layer name that doesn't exist, matching rs.ObjectsByLayer's NeedLayer"
  pscheck "history: select count: 2" "dino8.doc.Objects.SelectObject selected both requested objects and returned that count, matching rs.SelectObject"
  pscheck "history: selected after select: 3" "GetSelectedObjects sees the already-selected box plus the two objects SelectObject just selected"
  pscheck "history: unselect returned count: 2" "dino8.doc.Objects.UnselectObject returned the number of ids given, matching rs.UnselectObject"
  pscheck "history: selected after unselect: 1" "UnselectObject deselected both objects, leaving only the box selected"
  pscheck "history: unselect all count: 2" "dino8.doc.Objects.UnselectAllObjects returned how many objects were selected beforehand (the box plus the transform line just selected for this check), matching rs.UnselectAllObjects"
  pscheck "history: selected after unselect all: 0" "UnselectAllObjects deselected everything"
  pscheck "history: object count with cq line: 28" "AllObjects gained the new curve-query line"
  pscheck "history: curve length: 5.00" "dino8.doc.Objects.CurveLength measured a 3-4-5 triangle line, matching rs.CurveLength"
  pscheck "history: curve domain: 0.0,1.0" "dino8.doc.Objects.CurveDomain reported the normalized 0..1 domain, matching rs.CurveDomain"
  pscheck "history: evaluate curve at end: 103,4,0" "dino8.doc.Objects.EvaluateCurve at the domain's own end parameter returned the line's own end point, matching rs.EvaluateCurve"
  pscheck "history: curve closest point at start: 0.0" "dino8.doc.Objects.CurveClosestPoint found parameter 0 for the line's own start point, matching rs.CurveClosestPoint"
  pscheck "history: divide curve point count: 5" "dino8.doc.Objects.DivideCurve(id, 4) returned 5 points (4 segments), matching rs.DivideCurve"
  pscheck "history: divide curve first point: 100,0,0" "DivideCurve's first point is the curve's own start"
  pscheck "history: divide curve last point: 103,4,0" "DivideCurve's last point is the curve's own end"
  pscheck "history: divide curve params: 0.00,0.25,0.50,0.75,1.00" "DivideCurve(id, 4, False, False) returned the 5 raw, evenly-spaced parameters instead of points"
  pscheck "history: bad divide rejected:" "DivideCurve raised a Python exception for segments < 1 instead of silently returning, matching rs.DivideCurve's luaL_error"
  pscheck "history: divide curve created point count: 3" "DivideCurve(id, 2, create=True) returned 3 points (2 segments)"
  pscheck "history: object count with divide created points: 31" "DivideCurve's create=True also added one point object per returned point"
  pscheck "history: object count with bbox box: 32" "AllObjects gained the new bounding-box test box"
  pscheck "history: bounding box corner0: 200,0,0" "dino8.doc.Objects.BoundingBox's first corner is the box's own min corner, matching rs.BoundingBox's corner order"
  pscheck "history: bounding box corner6: 205,5,5" "BoundingBox's seventh corner is the box's own max corner"
  pscheck "history: bounding box missing: None" "BoundingBox returned None for an id that doesn't exist, matching rs.BoundingBox pushing nil instead of raising"
  pscheck "history: surface area box: 150.0" "dino8.doc.Objects.SurfaceArea computed a 5x5x5 box's own surface area (6 faces), matching rs.SurfaceArea"
  pscheck "history: surface volume box: 125.0" "dino8.doc.Objects.SurfaceVolume computed a 5x5x5 box's own volume, matching rs.SurfaceVolume"
  pscheck "history: is object solid box: True" "dino8.doc.Objects.IsObjectSolid reported the closed box as solid, matching rs.IsObjectSolid"
  pscheck "history: is object solid line: False" "IsObjectSolid reported the open line as not solid"
  pscheck "history: surface volume line: None" "SurfaceVolume returned None for a non-solid line, matching rs.SurfaceVolume pushing nil instead of raising"
  pscheck "history: object count with sc sphere: 33" "AllObjects gained the new surface-closest-point test sphere"
  pscheck "history: surface closest point: 300,0,4" "dino8.doc.Objects.SurfaceClosestPoint found the sphere surface point closest to a point straight above its center, matching rs.SurfaceClosestPoint"
  pscheck "history: object count with mesh: 34" "AllObjects gained the new AddMesh triangle"
  pscheck "history: mesh vertices count: 3" "dino8.doc.Objects.MeshVertices returned all 3 vertices of the triangle, matching rs.MeshVertices"
  pscheck "history: mesh vertex 0: 400,0,0" "MeshVertices' first vertex matches the mesh's own first input vertex"
  pscheck "history: objects by name widget: True" "dino8.doc.Objects.ObjectsByName(\"Widget\") found exactly the earlier-renamed box, matching rs.ObjectsByName"
  pscheck "history: objects by name none: \[\]" "ObjectsByName returned an empty list for a name nothing has, matching rs.ObjectsByName always pushing a table"
  pscheck "history: objects by name select side effect: True" "ObjectsByName(name, select=True) selected the matching object, matching rs.ObjectsByName's optional select argument"
  pscheck "history: object count with fresh points: 36" "AllObjects gained the two fresh ObjectsByType test points"
  pscheck "history: objects by type point delta: 2" "dino8.doc.Objects.ObjectsByType(\"point\") grew by exactly 2 after adding exactly 2 point objects, matching rs.ObjectsByType"
  pscheck "history: objects by type point contains fresh: True" "ObjectsByType(\"point\") included both freshly added points"
  pscheck "history: objects by type none equals all objects: True" "ObjectsByType() with no type argument matched every object in the document, matching rs.ObjectsByType's mask-0-means-everything rule"
  pscheck "history: objects by type select side effect: True" "ObjectsByType(type, select=True) selected the matching objects, matching rs.ObjectsByType's optional select argument"
  pscheck "history: layers count before: 1" "dino8.doc.Layers.Count started at 1 (just the Default layer), matching rs.LayerCount"
  pscheck "history: layers add returned name: QCLayer" "dino8.doc.Layers.Add returned the new layer's own name, matching rs.AddLayer"
  pscheck "history: layers count after add: 2" "Layers.Count grew by one after Add"
  pscheck "history: layers names include new: True" "dino8.doc.Layers.Names lists the new layer by its full path, matching rs.LayerNames"
  pscheck "history: layers is layer: True" "dino8.doc.Layers.IsLayer found the new layer, matching rs.IsLayer"
  pscheck "history: layers is layer bogus: False" "IsLayer returned False for a name that isn't a layer"
  pscheck "history: layers visible: True" "Layers.Add's visible=True argument took effect, matching rs.AddLayer"
  pscheck "history: layers visible after set: False" "dino8.doc.Layers.SetVisible/Visible round-tripped, matching rs.LayerVisible's get/set pair"
  pscheck "history: layers locked: False" "a freshly added layer starts unlocked"
  pscheck "history: layers locked after set: True" "dino8.doc.Layers.SetLocked/Locked round-tripped, matching rs.LayerLocked's get/set pair"
  pscheck "history: layers color: 0,200,100" "Layers.Add's color=(0,200,100) argument took effect"
  pscheck "history: layers color after set: 10,20,30" "dino8.doc.Layers.SetColor/Color round-tripped, matching rs.LayerColor's get/set pair"
  pscheck "history: layers current before: Default" "dino8.doc.Layers.CurrentLayer read Default as the document's starting current layer, matching rs.CurrentLayer"
  pscheck "history: layers current after set: QCLayer" "assigning dino8.doc.Layers.CurrentLayer changed the document's current layer, matching rs.CurrentLayer's setter form"
  pscheck "history: layers delete while current refused: True" "dino8.doc.Layers.Delete returned False for the document's own current layer instead of raising, matching Document::RemoveLayer's refusal and rs.DeleteLayer"
  pscheck "history: layers delete after switch: True" "Delete succeeded once the layer was no longer current"
  pscheck "history: layers count final: 1" "Layers.Count is back to 1 after the delete"
  pscheck "history: layers is layer after delete: False" "IsLayer no longer finds the deleted layer"
  pscheck "history: unit system before: 2" "dino8.doc.UnitSystem read back the default document unit system (2, Millimeters), matching rs.UnitSystem's getter form and Document::Settings().unit_system's default"
  pscheck "history: unit system after set by name: 9" "assigning dino8.doc.UnitSystem = \"Feet\" resolved the name to Rhino's own unit code (9), matching rs.UnitSystem's setter-by-name form and UnitCode's table in LuaEngine.cpp"
  pscheck "history: unit system name after set: Feet" "dino8.doc.UnitSystemName read back the word form after the by-name set, matching rs.UnitSystemName"
  pscheck "history: unit system after set by code: Millimeters" "assigning dino8.doc.UnitSystem = 2 (an int) resolved through the same code table, matching rs.UnitSystem's setter-by-code form"
  pscheck "history: doc name: Untitled" "dino8.doc.Name reported \"Untitled\" for a document with no path yet, matching rs.DocumentName"
  pscheck "history: doc path: None" "dino8.doc.Path is None for an unsaved document, matching rs.DocumentPath pushing nil instead of an empty string"
  pscheck "history: doc modified before: True" "dino8.doc.Modified reflects the many edits this script already made, matching rs.DocumentModified's getter form"
  pscheck "history: doc modified after set: False" "assigning dino8.doc.Modified = False round-tripped, matching rs.DocumentModified's setter form"
  pscheck "history: object user text before set: \[\]" "Dino8Object.GetUserText() with no key returns no keys before any are set, matching rs.GetUserText's no-key form"
  pscheck "history: object user text value: Steel" "Dino8Object.SetUserText/GetUserText round-tripped a per-object attribute value, matching rs.SetUserText/rs.GetUserText - previously entirely unported to Python"
  pscheck "history: object user text keys: \['Material'\]" "GetUserText() with no key lists the one key just set"
  pscheck "history: object user text missing key: None" "GetUserText of an unset key returns None, matching rs.GetUserText pushing nil"
  pscheck "history: object user text after erase: None" "SetUserText(key, None) erased the value, matching rs.SetUserText's \"no value removes\" behavior"
  pscheck "history: object user text keys after erase: \[\]" "the erased key no longer appears in GetUserText()'s key list"
  pscheck "history: document user text before set: \[\]" "Dino8Doc.GetDocumentUserText() with no key returns no keys before any are set, matching rs.GetDocumentUserText's no-key form"
  pscheck "history: document user text value: Acme" "Dino8Doc.SetDocumentUserText/GetDocumentUserText round-tripped a document-level attribute value, matching rs.SetDocumentUserText/rs.GetDocumentUserText - also previously entirely unported to Python"
  pscheck "history: document user text keys: \['Project'\]" "GetDocumentUserText() with no key lists the one key just set"
  pscheck "history: document user text after erase: None" "SetDocumentUserText(key, None) erased the value, matching rs.SetDocumentUserText's \"no value removes\" behavior"
  pscheck "history: object count before undo: 37" "dino8.doc.Objects.AddPoint after dino8.doc.BeginUndo(\"QCPointGroup\") added the one new point, matching rs.BeginUndo/rs.AddPoint"
  pscheck "history: undo point present: True" "the freshly added point resolves through Find before any undo"
  pscheck "history: undo returned: True" "dino8.doc.Undo() reported success, matching rs.Undo() - previously entirely unported to Python per the PARITY_MAP note on undo/document-state functions"
  pscheck "history: object count after undo: 36" "Undo() removed exactly the point BeginUndo's group added"
  pscheck "history: undo point gone: True" "the undone point no longer resolves through Find"
  pscheck "history: redo returned: True" "dino8.doc.Redo() reported success, matching rs.Redo() - also previously entirely unported to Python"
  pscheck "history: object count after redo: 37" "Redo() restored exactly the point Undo() had removed"
  pscheck "history: redo point back: True" "the redone point resolves through Find again"
  pscheck "history: final undo returned: True" "a second dino8.doc.Undo() call cleanly reverted the redo, leaving the document's object count where the rest of this script expects it"
  pscheck "history: object count after final undo: 36" "the undo/redo round trip nets to zero extra objects, so the final @expect_objects count below is unaffected"
  pscheck "history: last command name: RunPythonScript" "dino8.LastCommandName() reported RunPythonScript itself, matching rs.LastCommandName - CommandEngine::RunNested saves/restores last_command_ around a nested dino8.RunCommand call the same way rs.Command does, so the earlier NewLayer/AddLayer/etc. nested calls never clobber it"
  pscheck "history: version starts with Dino 8: True" "dino8.Version() reports a Dino 8 version string, matching rs.Version() - previously entirely unported to Python"
  pscheck "history: command history has last command: True" "dino8.CommandHistory() includes the line-1 \"Command: RunPythonScript ...\" entry LastCommandName just named, matching rs.CommandHistory()"
  pscheck "history: command history empty after clear: True" "dino8.ClearCommandHistory() actually cleared it, matching rs.ClearCommandHistory()"
  pscheck "history: last command survives history clear: True" "clearing the history deque leaves last_command_ itself untouched, matching rs.ClearCommandHistory() only ever clearing rs.CommandHistory()'s own log"
  pscheck "picked point is None: False" "dino8.GetPoint() was fed by the trailing script token (python_script.txt's \"RunPythonScript @TMP@/t.py 20,20,20 Widget2\"), returning a real Point3d, not None"
  pscheck "picked point 20,20,20" "the resumed script read back the exact point the command line fed it"
  pscheck "history: object count after GetPoint: 37" "AddPoint(p) added the one new object the suspend-and-resume round trip was supposed to produce"
  pscheck "history: got string: Widget2" "dino8.GetString() suspended a second time (same worker-thread mechanism as GetPoint) and was fed by the second trailing script token, proving the suspend/resume round trip works for a second, different prompt type right after the first, not just once"
  pscheck "history: got real: 7.5" "dino8.GetReal() suspended a third time and was fed by the third trailing script token, matching rs.GetReal - previously entirely unported to Python per the PARITY_MAP note on Python API breadth"
  pscheck "history: got integer: 3" "dino8.GetInteger() suspended a fourth time and was fed by the fourth trailing script token, matching rs.GetInteger - previously entirely unported to Python"
  pscheck "history: got integer is int: True" "GetInteger() returned a real Python int (rounded from the resumed double at the PyGetInteger binding, not left as a float), matching rs.GetInteger pushing a Lua integer"
  pscheck "history: got objects count: 37" "dino8.GetObjects() suspended a fifth time and was fed by the \"SelAll\"/\"Enter\" trailing script tokens (SelAll via CommandEngine's own nested-Sel-command-as-a-token path for Want::Objects, Enter handing the resulting full selection to OnObjects), returning every one of the 37 objects that existed at that point - matching rs.GetObjects, previously entirely unported to Python"
  pscheck "history: got objects are ints: True" "GetObjects() returned plain object ids (PyObjId per id), matching every other dino8.doc.Objects.Add-style/rs.GetObjects id-returning call rather than wrapping them as Dino8Object"
  pscheck "history: got object is int: True" "dino8.GetObject() suspended a sixth time, fed by its own \"SelAll\"/\"Enter\" pair, and returned a single plain id (not a list), matching rs.GetObject - previously entirely unported to Python"
  pscheck "history: got object is one of objs: True" "GetObject()'s single id is the front of the exact same selection GetObjects() just read, confirming both calls share the identical CommandEngine::OnObjects resume path"
  pscheck "history: got empty objects: True" "a further dino8.GetObjects() call fed only \"Enter\" with nothing selected resumed with an empty list, not None - matching LuaEngine's rs.GetObjects always pushing a (possibly empty) table rather than nil"
  pscheck "history: got none object: True" "dino8.GetObject() fed only \"Enter\" with nothing selected resumed with None - matching rs.GetObject pushing nil for the single-object case, the opposite of GetObjects' own empty-list convention just above"
  pscheck "^ok   expect_objects 37" "RunPythonScript left the box, the circle, the cone, the torus, the interpolated curve, the arc, the srf, the planar surface, three points, the extruded surface, the extruded solid, the union mesh, the difference mesh, the intersection mesh, the two circle copies, the rotate line and its rotated copy, the scale box and its scaled copy, the mirror line and its mirrored copy, the transform line and its transformed copy, the curve-query line, its 3 create=True divide points, the bounding-box test box, the surface-closest-point sphere, the AddMesh triangle, the two fresh ObjectsByType test points, and the dino8.GetPoint() marker point (the sphere, the two union input boxes, the two difference input boxes and the two intersection input boxes were removed from inside the script, and the undo/redo group's own point was undone again at the end)"
  grep -q "! Python error" <<<"$PS" && { echo "FAIL python_script.txt printed a Python error"; fail=1; } || echo "ok   no Python script errors"
fi

# EditPythonScript / Script Editor "Run" dispatch (see cmd_misc.cpp's
# EditPythonScript registration and ui/Panels.cpp's RunScriptEditor): opens
# a .py file in the Script Editor panel exactly like EditPythonScript does,
# then triggers the panel's actual Run-button code path via the test-only
# ScriptEditorRun command (cmd_misc.cpp - not in commands.json, not on any
# menu, exists purely so this can be exercised headlessly the same way
# DockLayoutRearrangeSelfTest/HBarDragSelfTest exercise other mouse-only UI
# elsewhere in this suite). Deliberately NOT calling RunPythonScript here -
# that would prove the Python engine works (already covered above) but say
# nothing about whether the panel's own Run button routes to it.
cat > "$TMPW/editor_test.py" <<'PY'
import dino8
pid = dino8.doc.Objects.AddPoint(7, 8, 9)
print("script editor ran python: " + str(pid is not None))
PY
cat > "$TMPW/scripteditor_run.txt" <<EOF
EditPythonScript $TMPW/editor_test.py
ScriptEditorRun
@expect_objects 1
EOF
# Same reasoning as python_script.txt above: scripteditor_run.txt's own
# final "@expect_objects 1" also depends on Python actually having run, so
# the exit code is only checked after the skip message is ruled out.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  set +e; SER="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/scripteditor_run.txt" 2>&1)"; ser_ec=$?; set -e
else
  set +e; SER="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/scripteditor_run.txt" 2>&1)"; ser_ec=$?; set -e
fi
if echo "$SER" | grep -q "Python 3 development install"; then
  echo "skip Script Editor Run->Python test not available in this build (compiled without Python3 Development.Embed)"
elif [ "$ser_ec" -ne 0 ]; then
  echo "$SER"; echo "FAIL: Script Editor Run test exited non-zero"; exit 1
else
  echo "$SER" | grep -E "^(ok|FAIL)"
  if echo "$SER" | grep -q "^FAIL"; then fail=1; fi
  sercheck() { if echo "$SER" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SER" "$1"; fail=1; fi; }
  sercheck "history: script editor ran python: True" "the Script Editor panel's Run button (ScriptEditorRun - the exact RunScriptEditor() code path DrawScriptEditor's button calls) dispatched the loaded .py file to PythonEngine, not Lua"
  sercheck "^ok   expect_objects 1" "the point dino8.doc.Objects.AddPoint created from inside the Script Editor's Python run is the only object in the document"
  grep -q "! Script error" <<<"$SER" && { echo "FAIL scripteditor_run.txt printed a Lua script error (the .py file was mis-routed to Lua by the Run button)"; fail=1; } || echo "ok   Script Editor Run did not mis-route the .py file to Lua"
  grep -q "! Python error" <<<"$SER" && { echo "FAIL scripteditor_run.txt printed a Python error"; fail=1; } || echo "ok   no Python errors from the Script Editor Run test"
fi

# Dino Flow + plug-ins: node editor, the HelloDino sample plug-in (command +
# Dino Flow node), and GrasshopperPlayer headless solve/bake (see flow_script.txt).
# The .dflow is copied to $TMPW first so the second run below can edit that
# copy in place (the source tree's copy stays untouched).
cp "$HERE/flow_graph.dflow" "$TMPW/flow_graph.dflow"
sed -e "s|@FLOWFILE@|$TMPW/flow_graph.dflow|g" -e "s|@FLOWSAVE@|$TMPW/flow_saved.3dm|g" "$HERE/flow_script.txt" > "$TMPW/flow_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FL="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/flow_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: flow script exited non-zero"; exit 1; }
else
  FL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/flow_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: flow script exited non-zero"; exit 1; }
fi
flcheck() { if echo "$FL" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FL" "$1"; fail=1; fi; }
flcheck "Dino Flow: opened the node editor" "Grasshopper opened the Dino Flow panel"
flcheck "GrasshopperPluginList: 4 plug-in(s) found" "the plug-in loader found all four sample plug-ins"
flcheck "HelloDino 1.0.0 - 1 command(s), 1 node(s)" "HelloDino loaded its command and Dino Flow node"
flcheck "MeshTools 1.0.0 - 2 command(s), 3 node(s)" "MeshTools loaded its commands (TerrainMesh, TestBadMeshIndex) and 3 Dino Flow nodes (Terrain Height, Terrain Mesh, Plugin Mesh Info)"
flcheck "TestBadMeshIndex: add_mesh correctly rejected an out-of-range face index" "the plugin ABI's add_mesh rejects a face referencing a vertex past the array end, instead of an out-of-bounds read"
flcheck "CurveTools 1.0.0 - 1 command(s), 3 node(s)" "CurveTools loaded its command and 3 Dino Flow nodes (Helix Point, Spiral Curve, Plugin Curve Length)"
flcheck "AnalysisTools 1.0.0 - 1 command(s), 1 node(s)" "AnalysisTools loaded its command and Dino Flow node"
flcheck "HelloDino: hello from the sample plug-in!" "the HelloDino command ran"
flcheck "GrasshopperPlayer: solved 4 node(s)" "GrasshopperPlayer solved the sample graph"
flcheck "gl_error=0" "flow script ran without OpenGL errors"
echo "$FL" | grep -E "^(ok|FAIL)"
if echo "$FL" | grep -q "^FAIL"; then fail=1; fi
flcheck "^ok   expect_objects 2" "GrasshopperPlayer baked the Line into the document"
flcheck "Total length = 30.41 " "the first bake's line has the slider=30 length"

# Associativity, across a real close/reopen: edit the same .dflow file on
# disk (slider 30 -> 55), then a *separate* process reopens the saved
# document and runs GrasshopperUpdateBakes against that same path - it
# should replace the previously-baked FlowLine object in place (same object
# count, new length) rather than add a second one next to it (see
# flow_update_script.txt).
sed -i 's/"slider_value":30/"slider_value":55/' "$TMPW/flow_graph.dflow"
sed -e "s|@FLOWFILE@|$TMPW/flow_graph.dflow|g" -e "s|@FLOWSAVE@|$TMPW/flow_saved.3dm|g" "$HERE/flow_update_script.txt" > "$TMPW/flow_update_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FL2="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/flow_update_script.txt" 2>&1)" || { echo "$FL2"; echo "FAIL: flow update script exited non-zero"; exit 1; }
else
  FL2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/flow_update_script.txt" 2>&1)" || { echo "$FL2"; echo "FAIL: flow update script exited non-zero"; exit 1; }
fi
fl2check() { if echo "$FL2" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FL2" "$1"; fail=1; fi; }
echo "$FL2" | grep -E "^(ok|FAIL)"
if echo "$FL2" | grep -q "^FAIL"; then fail=1; fi
fl2check "gl_error=0" "flow update script ran without OpenGL errors"
FL2_EXPECT2_COUNT=$(echo "$FL2" | grep -c "^ok   expect_objects 2 (got 2)")
if [ "$FL2_EXPECT2_COUNT" = "2" ]; then echo "ok   GrasshopperUpdateBakes kept the object count at 2 both before and after the re-bake (replaced in place, no duplicate)"; else echo "FAIL GrasshopperUpdateBakes kept the object count at 2 both before and after the re-bake (replaced in place, no duplicate)"; fail=1; fi
fl2check "Total length = 30.41 " "the reopened document still has the original slider=30 line"
fl2check "GrasshopperUpdateBakes: replaced 1 object(s) from a previous bake of .* with 1 freshly-solved object(s)" "GrasshopperUpdateBakes found and replaced (not duplicated) the previously-baked line"
fl2check "Total length = 55.23 " "the re-baked line picked up the slider=55 edit made to the .dflow file on disk - associative, not frozen"

# Dino Flow data trees: Range -> Graft Tree -> Flatten Tree -> List Item ->
# Construct Point -> Bake (see flow_tree_script.txt / flow_tree_graph.dflow).
# AttachGHSData/GetUserText surface each node's Tree::Summary() so the
# branch structure Graft/Flatten produce is directly checkable as text.
sed "s|@TREEFILE@|$HEREW/flow_tree_graph.dflow|g" "$HERE/flow_tree_script.txt" > "$TMPW/flow_tree_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FT="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/flow_tree_script.txt" 2>&1)" || { echo "$FT"; echo "FAIL: flow tree script exited non-zero"; exit 1; }
else
  FT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/flow_tree_script.txt" 2>&1)" || { echo "$FT"; echo "FAIL: flow tree script exited non-zero"; exit 1; }
fi
ftcheck() { if echo "$FT" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FT" "$1"; fail=1; fi; }
ftcheck "^ok   expect_objects 1" "the tree graph baked exactly one point"
ftcheck "Range=5 items" "Range produced a 5-item, single-branch list"
ftcheck "Graft Tree=5 items in 5 branches" "Graft Tree wrapped each item in its own branch"
ftcheck "Flatten Tree=5 items;" "Flatten Tree collapsed the 5 grafted branches back into one"
ftcheck "List Item=1 item" "List Item picked a single value out of the flattened list"
ftcheck "  4,0,0" "List Item(index 2) of Range(0,10,5) read back as 4 via the baked point's coordinates"

# Dino Flow evolutionary solver: Gene Pool -> (x-3)^2 fitness -> Evolutionary
# Solver, a known-optimum problem (minimum 0 at x=3) checked two ways: the
# GrasshopperPlayer summary line, and the baked (best-x, best-fitness) point
# (see flow_solver_script.txt / flow_solver_graph.dflow).
sed "s|@SOLVERFILE@|$HEREW/flow_solver_graph.dflow|g" "$HERE/flow_solver_script.txt" > "$TMPW/flow_solver_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FS="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/flow_solver_script.txt" 2>&1)" || { echo "$FS"; echo "FAIL: flow solver script exited non-zero"; exit 1; }
else
  FS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/flow_solver_script.txt" 2>&1)" || { echo "$FS"; echo "FAIL: flow solver script exited non-zero"; exit 1; }
fi
fscheck() { if echo "$FS" | grep -qE "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FS" "$1"; fail=1; fi; }
fscheck "^ok   expect_objects 1" "the solver graph baked exactly one point"
fscheck "Evolutionary Solver \(#4\) best fitness 0 after 60 generation\(s\)" "the solver ran all 60 generations and converged to fitness 0 for (x-3)^2 with this fixed seed"
fscheck "  3,0,0" "the baked point (best gene, best fitness) is exactly (3, 0, 0) - the true optimum of (x-3)^2"

# Dino Flow evolutionary solver Population clamp: same graph, but Population
# is a literal 2000000000 straight from the .dflow's JSON, the same
# untrusted-file-value hazard RunSolverNode's gene_count already guards
# against - std::vector<Individual> pop(population) allocated straight from
# that number before the fix, forcing a multi-GB/crashing allocation just
# from opening this file (see flow_solver_dos_script.txt /
# flow_solver_dos_graph.dflow). After the fix, Population is clamped the same
# way gene_count already was, so this still solves and bakes normally in
# bounded time instead of crashing or hanging.
sed "s|@SOLVERDOSFILE@|$HEREW/flow_solver_dos_graph.dflow|g" "$HERE/flow_solver_dos_script.txt" > "$TMPW/flow_solver_dos_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FD="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/flow_solver_dos_script.txt" 2>&1)" || { echo "$FD"; echo "FAIL: flow solver Population-clamp script exited non-zero (crashed or hung until the job's own timeout)"; exit 1; }
else
  FD="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/flow_solver_dos_script.txt" 2>&1)" || { echo "$FD"; echo "FAIL: flow solver Population-clamp script exited non-zero (crashed or hung until the job's own timeout)"; exit 1; }
fi
fdcheck() { if echo "$FD" | grep -qE "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FD" "$1"; fail=1; fi; }
fdcheck "^ok   expect_objects 1" "a Population of 2000000000 still baked exactly one point instead of crashing/hanging"
fdcheck "Evolutionary Solver \(#4\) best fitness .* after 60 generation\(s\)" "the solver still ran all 60 generations to completion with Population clamped down to a sane size"

# Dino Flow list/array node Count clamp: Range, Series, Random, Divide
# Curve, Linear Array and Polar Array all size a loop and/or output vector
# straight from an untrusted-file Count-ish input - the same hazard as
# RunSolverNode's Population above, just never closed off for these six
# (see flow_array_dos_script.txt / flow_array_dos_graph.dflow, which also
# covers EvalContext::Int()'s own clamp-before-llround fix via Range's Steps
# = 1e300). After the fix, each bakes a point whose X coordinate is the
# node's own clamped list length instead of crashing or hanging.
sed "s|@ARRAYDOSFILE@|$HEREW/flow_array_dos_graph.dflow|g" "$HERE/flow_array_dos_script.txt" > "$TMPW/flow_array_dos_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FA="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/flow_array_dos_script.txt" 2>&1)" || { echo "$FA"; echo "FAIL: flow array Count-clamp script exited non-zero (crashed or hung until the job's own timeout)"; exit 1; }
else
  FA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/flow_array_dos_script.txt" 2>&1)" || { echo "$FA"; echo "FAIL: flow array Count-clamp script exited non-zero (crashed or hung until the job's own timeout)"; exit 1; }
fi
facheck() { if echo "$FA" | grep -qE "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FA" "$1"; fail=1; fi; }
facheck "^ok   expect_objects 6" "all six Count-clamp nodes baked a point instead of crashing/hanging"
FA_100000=$(echo "$FA" | grep -c "  100000,0,0" || true)
if [ "$FA_100000" = "3" ]; then echo "ok   Range (Steps=1e300) and Series/Random (Count=2000000000) each clamped down to exactly 100000 items"; else echo "FAIL Range/Series/Random Count clamp"; near "$FA" "100000,0,0"; fail=1; fi
facheck "  10001,0,0" "Divide Curve (Count=2000000000) clamped n to 10000, so DivideByCount's n+1 points come out to 10001"
FA_10000=$(echo "$FA" | grep -c "  10000,0,0" || true)
if [ "$FA_10000" = "2" ]; then echo "ok   Linear Array and Polar Array (Count=2000000000) each clamped down to exactly 10000 copies"; else echo "FAIL Linear/Polar Array Count clamp"; near "$FA" "10000,0,0"; fail=1; fi

# Dino Flow plug-in geometry values: Spiral Curve (a plug-in node output of
# kind CURVE) wired directly into Plugin Curve Length (a plug-in node INPUT
# of kind CURVE) - proving the plugin ABI's opaque geometry handles round-
# trip plugin-to-plugin, not just plugin-to-document (see
# flow_plugin_geom_script.txt / flow_plugin_geom_graph.dflow).
sed "s|@GEOMFILE@|$HEREW/flow_plugin_geom_graph.dflow|g" "$HERE/flow_plugin_geom_script.txt" > "$TMPW/flow_plugin_geom_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FG="$(timeout 900 "$BIN" --smoke 100 --script "$TMPW/flow_plugin_geom_script.txt" 2>&1)" || { echo "$FG"; echo "FAIL: flow plugin geom script exited non-zero"; exit 1; }
else
  FG="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$TMPW/flow_plugin_geom_script.txt" 2>&1)" || { echo "$FG"; echo "FAIL: flow plugin geom script exited non-zero"; exit 1; }
fi
fgcheck() { if echo "$FG" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FG" "$1"; fail=1; fi; }
fgcheck "^ok   expect_objects 1" "the plugin geometry graph baked exactly one point"
fgcheck "GrasshopperPlayer: solved 4 node(s)" "GrasshopperPlayer solved Spiral Curve -> Plugin Curve Length -> Construct Point -> Bake"
fgcheck "  10,0,0" "Plugin Curve Length correctly computed 10 for a radius=0 turns=1 pitch=10 helix (a straight segment), round-tripped through two plug-in nodes and baked as the point's X"
fgcheck "gl_error=0" "flow plugin geometry script ran without OpenGL errors"

# Object editing: Join/Explode/Rebuild/ChangeDegree/Offset/Extend/Flip/Dir/MakePeriodic/
# Weight/InsertKnot/PointsOn/SetObjectName/Group/Hide/Lock/clipboard/Undo (see edit_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  ED="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/edit_script.txt" 2>&1)" || { echo "$ED"; echo "FAIL: edit script exited non-zero"; exit 1; }
else
  ED="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/edit_script.txt" 2>&1)" || { echo "$ED"; echo "FAIL: edit script exited non-zero"; exit 1; }
fi
echo "$ED" | grep -E "^(ok|FAIL)"
if echo "$ED" | grep -q "^FAIL"; then fail=1; fi
echo "$ED" | grep -q "^smoke:" || { echo "$ED"; echo "FAIL: edit script produced no smoke line"; fail=1; }
# Dir's own printed origin/direction is exactly the geometry ComputeDirArrow()
# (doc/SceneObject.h/.cpp) hands the viewport's direction-arrow glyph, so a
# plain Flip (FlipObject() - the same function a glyph click calls) must
# invert it precisely, for both a curve and a surface - the headlessly-
# verifiable half of Dir's real-glyph fix (see AUDIT.md's dated note).
edcheck() { if echo "$ED" | grep -Eq "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$ED" "$1"; fail=1; fi; }
edcheck "Radius at picked point = 3" "Offset now delegates to the kernel's own NurbsCurve::OffsetInPlane() - a circle offset inward by 2 lands on an EXACT radius-3 concentric circle (the curve's own fitted-plane overload's real ON_Arc construction), not the old hand-rolled code's own less-general special case"
edcheck "Bounding box min 47,-3,0 max 53,3,0" "that same offset circle's bounding box independently confirms the exact radius-3 result"
edcheck "Bounding box min -0.4061,-2.649,-0.7442 max 12.24,12.66,10" "Offset no longer refuses a genuinely non-planar (non-coplanar 4-point interpolated) curve outright - it falls back to the kernel's active-CPlane-normal overload instead, closing the other half of this gap"
edcheck "Total length = 48 Millimeters" "Offset's implicit Sharp corner on a closed square offset outward by 1 matches the exact mitered-square closed-form perimeter 4*(10+2*1)=48"
edcheck "Total length = 46.28 Millimeters" "Offset Corner=Round on the identical square matches the exact rounded-square closed-form perimeter 4*10+2*pi*1=46.28... - the Corner option genuinely reaches the kernel's own CurveOffsetCornerStyle::Round, not just parsed and ignored"
edcheck "Total length = 45.66 Millimeters" "Offset Corner=Chamfer on the identical square matches the exact chamfered-square closed-form perimeter 4*10+4*sqrt(2)=45.66..."
edcheck "Total length = 46.38 Millimeters" "Offset Corner=Smooth on the identical square is distinct from Sharp/Round/Chamfer alike and strictly longer than Chamfer's own chord perimeter, matching the kernel's own G2-blend closed-square test"
edcheck "Curve [0-9]+: start 0,0,0 tangent 1,0,0" "Dir printed a fresh line's real start point and unit tangent"
edcheck "Curve [0-9]+: start 10,0,0 tangent -1,0,0" "a plain Flip inverted that same curve's Dir-reported start/tangent exactly"
edcheck "Surface [0-9]+: centre 5,5,0 normal 0,0,-1" "Dir printed a fresh planar surface's real domain-centre point and unit normal"
edcheck "Surface [0-9]+: centre 5,5,0 normal -?0,0,1" "a plain Flip inverted that same surface's Dir-reported normal exactly, leaving its centre point unchanged (Reverse(0) reparameterises, it does not move the surface)"
# SetObjectName regression: used to number from 1, so the first of a
# multi-object selection was wrongly suffixed "(1)" instead of keeping the
# bare name (the class's own doc comment and printed message both promise
# "(2), (3), ..."). List must show the first named object bare.
edcheck "name 'MyName'$" "SetObjectName kept the first object's name bare, not suffixed '(1)'"
edcheck "name 'MyName \\(2\\)'" "SetObjectName numbered the second object '(2)', not '(1)'"
# Rebuild point-count clamp regression: "Point count" used to flow straight
# from the typed number into an n x n control-point grid with no upper
# bound (the Surface branch is O(n^2) points, then an O(n^2)-CV
# NurbsSurface::FromControlGrid), so 5000000 would have demanded a
# 25-trillion-point grid instead of baking instantly. After the fix the
# count is clamped to 200 before it drives any allocation.
edcheck "degree 3 x 3, CVs 200 x 200" "Rebuild clamped an absurd 5000000 point count down to a sane 200 x 200 control-point grid instead of hanging/OOMing on the n x n allocation"
# ChangeDegree now also calls the kernel's real NurbsCurve::ReduceDegree()
# for a lower target, not just silently no-op-ing the way it always used to
# (the elevate branch's own `target > Degree()` guard never covered
# lowering at all) - a line elevated to degree 3 (4 CVs) must genuinely
# drop back to degree 1 (2 CVs) when asked, not stay stuck at 3.
edcheck "degree 3, 4 control points, non-rational, open" "ChangeDegree elevated the line to degree 3 (4 control points)"
edcheck "ChangeDegree: 1 object\(s\) changed to degree 1 \(1 degree-reduced\)" "ChangeDegree's own reduce path actually ran (ReduceDegree, not a silent no-op)"
edcheck "degree 1, 2 control points, non-rational, open" "ChangeDegree genuinely reduced the line back to degree 1 (2 control points), not left at degree 3"

# Same "never lowers" gap, now closed for SURFACES too (NurbsSurface::
# ReduceDegree, surface_edit.cpp) - a flat Plane (degree 1x1, 2x2 CVs)
# elevated to degree 3x3 (4x4 CVs) must genuinely drop back to degree
# 1x1 (2x2 CVs) when asked, in BOTH directions, not stay stuck at 3x3.
edcheck "degree 3 x 3, CVs 4 x 4" "ChangeDegree elevated the flat Plane to degree 3 x 3 (4 x 4 control points)"
edcheck "ChangeDegree: 1 object\(s\) changed to degree 1 \(2 degree-reduced\)" "ChangeDegree's own surface reduce path actually ran in both U and V (ReduceDegree, not a silent no-op)"
edcheck "degree 1 x 1, CVs 2 x 2" "ChangeDegree genuinely reduced the flat Plane back to degree 1 x 1 (2 x 2 control points), not left at degree 3 x 3"
if echo "$ED" | grep -q "name 'MyName (1)'"; then echo "FAIL SetObjectName still off-by-one: an object was suffixed '(1)'"; fail=1; else echo "ok   no object was suffixed 'MyName (1)'"; fi

# Real NURBS algorithm QC: ExtractPipedCurve/MakePeriodic Smooth=No/RefitTrim
# (see nurbs_algo_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  NA="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/nurbs_algo_script.txt" 2>&1)" || { echo "$NA"; echo "FAIL: nurbs algo script exited non-zero"; exit 1; }
else
  NA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/nurbs_algo_script.txt" 2>&1)" || { echo "$NA"; echo "FAIL: nurbs algo script exited non-zero"; exit 1; }
fi
echo "$NA" | grep -E "^(ok|FAIL)"
if echo "$NA" | grep -q "^FAIL"; then fail=1; fi
echo "$NA" | grep -q "^smoke:" || { echo "$NA"; echo "FAIL: nurbs algo script produced no smoke line"; fail=1; }
nacheck() { if echo "$NA" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$NA" "$1"; fail=1; fi; }
nacheck "ExtractPipedCurve: extracted 1 rail curve(s)" "ExtractPipedCurve pulled the rail curve back out of the Pipe surface, even after the original curve was deleted"
nacheck "MakePeriodic: 1 object(s) made periodic (Smooth=No)" "MakePeriodic Smooth=No ran the real exact-shape-preserving re-knot"
# MakePeriodic on a Surface: NurbsSurface::MakePeriodicExact (kernel-only
# until now) wired in for the first time - PARITY_MAP.md's own "Make
# periodic (surface)" gap. A Sweep1 surface along a closed (circle)
# profile is closed-but-not-yet-periodic in U (degree 2, CVs 9x2, the
# same clamped-duplicate-seam-CV convention a closed curve's own clamped
# form uses) and never-closeable in V (the straight rail's own open
# direction, degree 1) - MakePeriodicExact(0) must genuinely re-knot U
# to periodic (CVs 9x2 -> 10x2) and report success even though V's own
# Failed (it was never a periodicity candidate to begin with) does not
# count against it.
nacheck "MakePeriodic: 1 object(s) made periodic (Smooth=Yes)" "MakePeriodic on a Surface succeeds even though only its U direction is closed - a genuinely open V direction's own Failed doesn't count against it"
nacheck "CVs 10 x 2" "MakePeriodic genuinely re-knotted the swept surface's U direction to periodic (9 control points -> 10, not a no-op)"
nacheck "RefitTrim: 2 trim curve(s) could not be refit to strictly fewer control points" "RefitTrim ran its real constrained least-squares fit end to end and correctly, honestly refused a genuinely infeasible case (a cylinder cap's domain leaves no margin for the fitted control polygon's own real overshoot) rather than violating the tolerance or the surface domain"
# RebuildUV: previously a bare alias of MakeUniformUV; now its own command
# (PARITY_MAP.md's own disclosed "Rebuild/Refit" gap) that genuinely
# touches only the ONE direction (U or V) it was asked for, per
# data/commands.json's own documented real semantics.
nacheck "RebuildUV: 1 surface(s) rebuilt to 8 point(s) in U" "RebuildUV rebuilt a degree-1 2x2 Plane in U only, to 8 points"
nacheck "degree 3 x 1, CVs 8 x 2" "RebuildUV Direction=U left V's own point count/degree (1, 2) completely untouched while rebuilding U to degree 3, 8 CVs"
nacheck "RebuildUV: 1 surface(s) rebuilt to 12 point(s) in V" "RebuildUV rebuilt the same surface in V only, to 12 points"
nacheck "degree 3 x 3, CVs 8 x 12" "RebuildUV Direction=V left U's own just-rebuilt 8 points/degree 3 untouched in turn, proving each call only ever touches the ONE direction it was asked for"

# Layers: NewLayer/SetLayer/ChangeLayer/ChangeToCurrentLayer/MatchLayer/SetLayerToObject/
# OneLayerOn/OneLayerOff/AllLayersOn/LayerOn/LayerOff/LayerLock/LayerUnlock/Purge (see layer_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  LY="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/layer_script.txt" 2>&1)" || { echo "$LY"; echo "FAIL: layer script exited non-zero"; exit 1; }
else
  LY="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/layer_script.txt" 2>&1)" || { echo "$LY"; echo "FAIL: layer script exited non-zero"; exit 1; }
fi
echo "$LY" | grep -E "^(ok|FAIL)"
if echo "$LY" | grep -q "^FAIL"; then fail=1; fi
echo "$LY" | grep -q "^smoke:" || { echo "$LY"; echo "FAIL: layer script produced no smoke line"; fail=1; }

# Layer State Manager (LayerState Save/Restore/List, Document::LayerStates -
# see layerstate_script.txt): a state saved with one layer hidden actually
# changes selectability when restored (SelAll count), and - the bug this
# increment fixes - the saved state is a real Document member persisted to
# the .3dm, not a process-wide static: it must survive New+Open and still
# restore correctly afterward.
sed "s|@TMP@|$TMPW|g" "$HERE/layerstate_script.txt" > "$TMPW/layerstate_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  LS="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/layerstate_script.txt" 2>&1)" || { echo "$LS"; echo "FAIL: layerstate script exited non-zero"; exit 1; }
else
  LS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/layerstate_script.txt" 2>&1)" || { echo "$LS"; echo "FAIL: layerstate script exited non-zero"; exit 1; }
fi
echo "$LS" | grep -E "^(ok|FAIL)"
if echo "$LS" | grep -q "^FAIL"; then fail=1; fi
lscheck() { if echo "$LS" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$LS" "$1"; fail=1; fi; }
lscheck "Layer state 'HiddenWalls' saved (3 layer(s))" "LayerState Save captured all 3 layers' visibility"
lscheck "Layer state 'HiddenWalls' restored" "LayerState Restore ran"
lscheck "1 layer state(s)" "exactly one layer state survived Save/New/Open"
lscheck "  HiddenWalls: 3 layer(s)" "the reloaded layer state kept its name and layer count"

# Purge: sweeps every named-item table (layers, blocks, materials,
# linetypes, annotation styles, empty groups), not just layers - see
# cmd_layer.cpp and purge_script.txt. Each category is made unused
# deliberately, so the single Purge run should report exactly one of each.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PU="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/purge_script.txt" 2>&1)" || { echo "$PU"; echo "FAIL: purge script exited non-zero"; exit 1; }
else
  PU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/purge_script.txt" 2>&1)" || { echo "$PU"; echo "FAIL: purge script exited non-zero"; exit 1; }
fi
echo "$PU" | grep -E "^(ok|FAIL)"
if echo "$PU" | grep -q "^FAIL"; then fail=1; fi
echo "$PU" | grep -q "^smoke:" || { echo "$PU"; echo "FAIL: purge script produced no smoke line"; fail=1; }
pucheck() { if echo "$PU" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PU" "$1"; fail=1; fi; }
pucheck "Purge: removed 1 layer, 1 block, 1 material, 7 linetypes, 1 annotation style and 1 empty group" \
        "Purge swept layers/blocks/materials/linetypes/annotation styles/empty groups in one pass, not just layers (7 linetypes: the 6 unused-by-default built-ins - Continuous is protected - plus the test's own PurgeUnusedLinetype)"

# Selection: every Sel* command in cmd_select.cpp and cmd_select2.cpp (see select_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SL="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/select_script.txt" 2>&1)" || { echo "$SL"; echo "FAIL: select script exited non-zero"; exit 1; }
else
  SL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/select_script.txt" 2>&1)" || { echo "$SL"; echo "FAIL: select script exited non-zero"; exit 1; }
fi
echo "$SL" | grep -E "^(ok|FAIL)"
if echo "$SL" | grep -q "^FAIL"; then fail=1; fi
echo "$SL" | grep -q "^smoke:" || { echo "$SL"; echo "FAIL: select script produced no smoke line"; fail=1; }
slcheck() { if echo "$SL" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SL" "$1"; fail=1; fi; }
# UndoSelected (per-object-scoped undo): object A (tagged undosel-a) was
# moved to 205,200,0, then unrelated object B (tagged undosel-b) was moved
# to 300,220,0 afterward - so A's own move entry is NOT the top of the
# whole-document undo stack (B's is), exercising the non-top splice path.
# UndoSelected on A alone must revert only A - not B, and not the whole
# document the way a plain Undo would (which would undo B's move instead,
# since it's the most recent edit overall).
slcheck "Location: 200, 200, 0" "UndoSelected on A reverted A's own move back to its pre-move location (200,200,0), not left at 205,200,0, even though A's entry was buried under B's later, unrelated one"
slcheck "Location: 300, 220, 0" "B's later, unrelated move stayed intact after UndoSelected targeted A only - proving this is not the same as a plain Undo (which would have undone B's move, the most recent edit overall)"
slcheck "Location: 300, 200, 0" "B's move is genuinely still on the undo stack after UndoSelected spliced A's entry out from underneath it: an ordinary Undo() right afterward undoes B's move next (back to 300,200,0)"
slcheck "The most recent change to the selection ('Move') was followed by a later edit ('Move') to the same object, so it can't be safely undone on its own without also affecting that later edit. Use Undo repeatedly instead." \
  "UndoSelected honestly refuses (rather than guessing) when isolating a match would require splitting a later, still-live edit to an object the match's own batch-move also touched"
slcheck "Location: 405, 200, 0" "the refused UndoSelected left object C exactly where the batch move put it (405,200,0), not reverted, since it could not be safely isolated"
slcheck "SelU: 2 sub-object(s) added," "SelU's NearestControlPoint ignored a deselected-but-still-PointsOn curve's closer control point and correctly picked the currently-selected surface's control point instead (a stale-selection cross-object pick would have reported 1 sub-object added, on the curve's single point, not 2)"

# Provenance-based selection: SelChildren/SelParents/SelExtrusion now walk a
# real parent/child side table (doc/Document.h's ProvenanceInfo) instead of
# the old group-symmetric fallback / "every polysurface" guess - see
# provenance_script.txt's header comment for exactly what it builds.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PV="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/provenance_script.txt" 2>&1)" || { echo "$PV"; echo "FAIL: provenance script exited non-zero"; exit 1; }
else
  PV="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/provenance_script.txt" 2>&1)" || { echo "$PV"; echo "FAIL: provenance script exited non-zero"; exit 1; }
fi
echo "$PV" | grep -E "^(ok|FAIL)"
if echo "$PV" | grep -q "^FAIL"; then fail=1; fi
echo "$PV" | grep -q "^smoke:" || { echo "$PV"; echo "FAIL: provenance script produced no smoke line"; fail=1; }
pvcheck() { if echo "$PV" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PV" "$1"; fail=1; fi; }
pvcheck "Block 'Widget' defined with 2 object(s)" "Block replaced the source curves with a 2-object instance"
pvcheck "history: Object 5 (curve) layer Default" "SelChildren on instance #2's anchor (5) added exactly its own member (6), not another instance's objects"
pvcheck "history: Object 6 (curve) layer Default" "  (List after SelChildren shows member 6 selected alongside anchor 5)"
pvcheck "SelParents: no tracked parent found for the current selection (or the parent object was deleted)" \
        "SelParents reports (not crashes) when nothing is tracked - both for an anchor object and for an extrusion whose source curve was deleted"
pvcheck "SelChildren: no tracked children found for the current selection" "SelChildren reports rather than matching everything when a leaf object has no children"
pvcheck "history: Object 11 (polysurface) layer Default" "SelExtrusion found the real ExtrudeCrv result (11), not the decoy Box (9) - a genuine improvement over the old any-polysurface Partial behaviour"
pvcheck "history: Object 10 (curve) layer Default" "SelParents on the extrusion found its real source curve (10) while it still existed"

# Transforms: exact coordinates after Move/Copy/Rotate/Scale*/Mirror/Array*/Orient*/
# ProjectToCPlane/SetPt/Nudge, in Top/Front/Right (see transform_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  TR="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/transform_script.txt" 2>&1)" || { echo "$TR"; echo "FAIL: transform script exited non-zero"; exit 1; }
else
  TR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/transform_script.txt" 2>&1)" || { echo "$TR"; echo "FAIL: transform script exited non-zero"; exit 1; }
fi
echo "$TR" | grep -E "^(ok|FAIL)"
if echo "$TR" | grep -q "^FAIL"; then fail=1; fi
echo "$TR" | grep -q "^smoke:" || { echo "$TR"; echo "FAIL: transform script produced no smoke line"; fail=1; }

# Booleans: BooleanUnion/BooleanIntersection, Boolean2Objects (Result
# cycling), BooleanSplit/MeshSplit/MeshBooleanSplit, WireCut, MeshSmooth
# (see boolean_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BO="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/boolean_script.txt" 2>&1)" || { echo "$BO"; echo "FAIL: boolean script exited non-zero"; exit 1; }
else
  BO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/boolean_script.txt" 2>&1)" || { echo "$BO"; echo "FAIL: boolean script exited non-zero"; exit 1; }
fi
bocheck() { if echo "$BO" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BO" "$1"; fail=1; fi; }
# SubD booleans: BooleanUnion/BooleanDifference/BooleanIntersection now
# return a genuine SubD via kernel::SubD::BooleanToSubD when every operand
# is a SubD (PARITY_MAP.md's own "SubD booleans" item, previously missing
# outright). Narrowed further: a MIXED selection (at least one true SubD
# alongside a Brep/Mesh) now ALSO returns a real SubD, promoting the
# non-SubD operand's own existing tessellation via SubD::FromControlMesh
# instead of collapsing everything to a Mesh - gated so an all-Brep
# selection still takes the exact B-rep path and an all-Mesh selection
# still comes back as a plain Mesh, both unaffected.
bocheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), 760 face(s), 32 crease edge(s) (32 on the cut seam, 0 along operand creases, 0 sharp-angle)" "BooleanUnion on two overlapping SubD boxes returns a real SubD whose operands were refined to their LIMIT surfaces (was a 19-face cage-level result) with the cut seam creased (32 seam crease edges)"
bocheck "BooleanDifference: SubD boolean (operands refined to their limit surfaces, seam creased), 436 face(s), 32 crease edge(s) (32 on the cut seam" "BooleanDifference on two SubD boxes returns a real SubD with a creased cut (was 12 faces, no creases)"
bocheck "BooleanIntersection: SubD boolean (operands refined to their limit surfaces, seam creased), 112 face(s), 32 crease edge(s) (32 on the cut seam" "BooleanIntersection on two SubD boxes returns a real SubD with a creased cut (was 6 faces, no creases)"
bocheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), 330 face(s), 45 crease edge(s) (32 on the cut seam, 0 along operand creases, 13 sharp-angle)" "BooleanUnion on a mixed SubD + Brep selection returns a real SubD: the promoted Brep's box edges (13 sharp-angle crease edges) stay sharp and the cut seam is creased"
bocheck "BooleanUnion: exact B-rep boolean (no tessellation), 26 face(s)" "BooleanUnion on an all-Brep selection is unaffected by the mixed-type change - still the exact B-rep path, never downgraded to a SubD"
bocheck "BooleanUnion: 36 faces, volume 14" "BooleanUnion on an all-Mesh selection is unaffected by the mixed-type change - still a plain Mesh, never surprise-upgraded to a SubD"
echo "$BO" | grep -E "^(ok|FAIL)"
if echo "$BO" | grep -q "^FAIL"; then fail=1; fi
echo "$BO" | grep -q "^smoke:" || { echo "$BO"; echo "FAIL: boolean script produced no smoke line"; fail=1; }

# Imprint/MutualImprint: kernel::ImprintFaces()/MutualImprintFaces()'s first
# app commands (see imprint_script.txt) - PARITY_MAP.md's "kernel: Boolean
# operations" category's "Face-face imprint" bullet.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  IM="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/imprint_script.txt" 2>&1)" || { echo "$IM"; echo "FAIL: imprint script exited non-zero"; exit 1; }
else
  IM="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/imprint_script.txt" 2>&1)" || { echo "$IM"; echo "FAIL: imprint script exited non-zero"; exit 1; }
fi
echo "$IM" | grep -E "^(ok|FAIL)"
if echo "$IM" | grep -q "^FAIL"; then fail=1; fi
echo "$IM" | grep -q "^smoke:" || { echo "$IM"; echo "FAIL: imprint script produced no smoke line"; fail=1; }

# SplitBySheet/TrimSheetBySolid: kernel::SplitBySheet()/TrimSheetBySolid()'s
# first app commands (see splitbysheet_trimsheet_script.txt) - PARITY_MAP.md's
# "kernel: Boolean operations" category's "Sheet/solid trim" bullet.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SH="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/splitbysheet_trimsheet_script.txt" 2>&1)" || { echo "$SH"; echo "FAIL: splitbysheet/trimsheet script exited non-zero"; exit 1; }
else
  SH="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/splitbysheet_trimsheet_script.txt" 2>&1)" || { echo "$SH"; echo "FAIL: splitbysheet/trimsheet script exited non-zero"; exit 1; }
fi
echo "$SH" | grep -E "^(ok|FAIL)"
if echo "$SH" | grep -q "^FAIL"; then fail=1; fi
echo "$SH" | grep -q "^smoke:" || { echo "$SH"; echo "FAIL: splitbysheet/trimsheet script produced no smoke line"; fail=1; }

# SplitByObject regression: a non-intersecting cutter must not be consumed
# (see splitbyobject_regression.txt) - SplitByObject used to delete every
# selected cutting object unconditionally, even when nothing was actually
# split, silently destroying the user's cutting geometry.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SBO="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/splitbyobject_regression.txt" 2>&1)" || { echo "$SBO"; echo "FAIL: splitbyobject-regression script exited non-zero"; exit 1; }
else
  SBO="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/splitbyobject_regression.txt" 2>&1)" || { echo "$SBO"; echo "FAIL: splitbyobject-regression script exited non-zero"; exit 1; }
fi
echo "$SBO" | grep -E "^(ok|FAIL)"
if echo "$SBO" | grep -q "^FAIL"; then fail=1; fi
echo "$SBO" | grep -q "^smoke:" || { echo "$SBO"; echo "FAIL: splitbyobject-regression script produced no smoke line"; fail=1; }

# SplitByObject exact B-rep path: when target and cutter are both plain
# closed solid Breps that genuinely cross, SplitByObject must now take the
# new kernel::SplitBrepByManySolids path (real B-rep pieces, no
# tessellation) rather than silently falling back to the mesh pipeline -
# and, as of round 41, a single open-sheet cutter must take the
# kernel::SplitBySheet path instead (see
# splitbyobject_exact_brep_script.txt) - PARITY_MAP.md's "kernel:
# Boolean operations" category's "Keep/split options" bullet.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SBX="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/splitbyobject_exact_brep_script.txt" 2>&1)" || { echo "$SBX"; echo "FAIL: splitbyobject-exact-brep script exited non-zero"; exit 1; }
else
  SBX="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/splitbyobject_exact_brep_script.txt" 2>&1)" || { echo "$SBX"; echo "FAIL: splitbyobject-exact-brep script exited non-zero"; exit 1; }
fi
echo "$SBX" | grep -E "^(ok|FAIL)"
if echo "$SBX" | grep -q "^FAIL"; then fail=1; fi
echo "$SBX" | grep -q "^smoke:" || { echo "$SBX"; echo "FAIL: splitbyobject-exact-brep script produced no smoke line"; fail=1; }
echo "$SBX" | grep -q "exact B-rep, no tessellation" || { echo "$SBX"; echo "FAIL: splitbyobject-exact-brep script did not take the exact solid-by-solid B-rep path"; fail=1; }
echo "$SBX" | grep -q "exact B-rep via sheet cutter, no tessellation" || { echo "$SBX"; echo "FAIL: splitbyobject-exact-brep script did not take the exact sheet-cutter B-rep path"; fail=1; }

# Adversarial booleans: near-tangent/barely-overlapping/coincident solids,
# an extreme-aspect-ratio sliver, a huge-coordinate-scale pair, a 10-deep
# chained-difference feature, and non-manifold input (see
# boolean_adversarial_script.txt and adversarial_corpus_notes.md).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BA="$(timeout 900 "$BIN" --smoke 300 --script "$HERE/boolean_adversarial_script.txt" 2>&1)" || { echo "$BA"; echo "FAIL: boolean-adversarial script exited non-zero"; exit 1; }
else
  BA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 300 --script "$HERE/boolean_adversarial_script.txt" 2>&1)" || { echo "$BA"; echo "FAIL: boolean-adversarial script exited non-zero"; exit 1; }
fi
bacheck() { if echo "$BA" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BA" "$1"; fail=1; fi; }
# These boxes are all plain closed solid Breps, so 92ecdda's TryExactBrepBoolean
# (cmd_boolean.cpp) now takes the exact B-rep-preserving path ahead of the
# mesh path for every case below, printing "exact B-rep boolean (no
# tessellation), N face(s)" instead of the mesh path's own "N faces, volume
# V" - not a regression in the boolean result itself (verified directly:
# every case here still succeeds with a real, non-empty, correctly-valued
# result), just a stale message-format expectation from before that commit
# landed. Where the script also runs an explicit Volume command afterward,
# that separate "Volume = V cubic Millimeters" history line is checked too,
# preserving this corpus's original point of proving the volume didn't
# silently collapse or drift.
bacheck "BooleanUnion: exact B-rep boolean (no tessellation), 14 face(s)" "near-tangent boxes (1e-6 overlap) unioned into one solid"
bacheck "BooleanIntersection: exact B-rep boolean (no tessellation), 6 face(s)" "barely-overlapping boxes (1e-4 overlap) still intersected into a real, non-empty sliver"
bacheck "BooleanUnion: exact B-rep boolean (no tessellation), 6 face(s)" "coincident duplicate boxes unioned without collapsing or crashing"
bacheck "Volume = 1000 cubic Millimeters" "coincident duplicate boxes' union kept the exact original volume"
bacheck "BooleanIntersection: exact B-rep boolean (no tessellation), 6 face(s)" "coincident duplicate boxes intersected without collapsing or crashing"
bacheck "Volume = 1000 cubic Millimeters" "coincident duplicate boxes' intersection reproduced the exact original volume"
bacheck "BooleanDifference: exact B-rep boolean (no tessellation), 14 face(s)" "a 1000x1000x0.001 sliver survived a corner-clipping difference as a real, exact (not tessellated) result"
bacheck "BooleanUnion: exact B-rep boolean (no tessellation), 26 face(s)" "two boxes at 1e6-unit coordinates still unioned to a real result, no precision collapse"
bacheck "Volume = 1.4e+04 cubic Millimeters" "the huge-scale union's volume matched the expected 8000+8000-2000 exactly, no precision collapse"
bacheck "BooleanDifference: exact B-rep boolean (no tessellation), 194 face(s)" "10 chained BooleanDifference cuts on one solid stayed valid through the final cut"
bacheck "Volume = 8800 cubic Millimeters" "the chained-difference result's volume matched the expected 10000 - 10x120 exactly"
if echo "$BA" | grep -q "! No object with id"; then echo "FAIL boolean-adversarial script's own SelID bookkeeping was wrong (references a missing id)"; fail=1; else echo "ok   boolean-adversarial script's SelID bookkeeping matched every object the app actually created"; fi
echo "$BA" | grep -E "^(ok|FAIL)"
if echo "$BA" | grep -q "^FAIL"; then fail=1; fi
bacheck "^ok   expect_objects 0" "boolean-adversarial script cleaned up to zero objects at the end"

# Compound-operand exact booleans: a compound (multi-lump) Brep operand -
# the actual output of an earlier Boolean2Objects Result=SymmetricDifference
# call, not just an artificial fixture - reaches BooleanCombinePlanar's own
# compound-accepting Difference through the app, not just the kernel's own
# unit tests (see boolean_mixed_and_compound_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BM="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/boolean_mixed_and_compound_script.txt" 2>&1)" || { echo "$BM"; echo "FAIL: boolean-mixed-and-compound script exited non-zero"; exit 1; }
else
  BM="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/boolean_mixed_and_compound_script.txt" 2>&1)" || { echo "$BM"; echo "FAIL: boolean-mixed-and-compound script exited non-zero"; exit 1; }
fi
bmcheck() { if echo "$BM" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BM" "$1"; fail=1; fi; }
bmcheck "BooleanDifference: exact B-rep boolean (no tessellation)" "a compound (two-lump) Brep operand, built by a real Boolean2Objects Result=SymmetricDifference call, took the exact path through the app, not the mesh fallback"
bmcheck "Volume = 1750 cubic" "the compound difference is correct (only the touched lump lost its overlap, the untouched lump kept its full volume)"
if echo "$BM" | grep -q "! No object with id"; then echo "FAIL boolean-mixed-and-compound script's own SelID bookkeeping was wrong (references a missing id)"; fail=1; else echo "ok   boolean-mixed-and-compound script's SelID bookkeeping matched every object the app actually created"; fi
echo "$BM" | grep -E "^(ok|FAIL)"
if echo "$BM" | grep -q "^FAIL"; then fail=1; fi
bmcheck "^ok   expect_objects 0" "boolean-mixed-and-compound script cleaned up to zero objects at the end"

# General-engine (curved-face) exact booleans: BooleanCombineGeneral/
# BooleanCombineGeneralNAry had no app entry point at all - a solid with
# any curved face always fell straight through to the mesh path, even
# though the Planar engine above was already wired - PARITY_MAP.md's
# "kernel: Boolean operations" category's "B-rep-preserving booleans
# reachable from the application" bullet (see
# boolean_general_engine_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BG="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/boolean_general_engine_script.txt" 2>&1)" || { echo "$BG"; echo "FAIL: boolean-general-engine script exited non-zero"; exit 1; }
else
  BG="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/boolean_general_engine_script.txt" 2>&1)" || { echo "$BG"; echo "FAIL: boolean-general-engine script exited non-zero"; exit 1; }
fi
bgecheck() { if echo "$BG" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BG" "$1"; fail=1; fi; }
# Updated honestly: this used to assert that the General engine's 10-face result was accepted. Measured, that
# result was an OPEN shell ("10 faces, 236 edges, open", Volume = 0, "Object 3 is not closed") - the General
# engine does not return a closed solid for a box pierced by a cylinder. RunBoolean now accepts a General-engine
# result only when it is a closed solid, so the union and difference fall through to the mesh path, whose volumes
# are the true ones (box 1000 +/- the cylinder's 10-long, r=2 part, pi*4*10 = 125.66: union 1125, difference 874.9).
bgecheck ", sewn into a closed solid (tolerance 0.02449), volume 1125 (mesh cross-check 1125)" "a box unioned with a piercing, record-less cylinder: the General engine's result is sewn into a closed solid and accepted only because its volume agrees with the mesh boolean (1000 + 125.7); an open shell would now be refused by RunBoolean's closed-solid gate"
bgecheck ", sewn into a closed solid (tolerance 0.01855), volume 874.8 (mesh cross-check 874.9)" "the same box minus the piercing cylinder likewise: closed, volume 1000 - 125.7"
bgecheck "BooleanIntersection: exact B-rep boolean (no tessellation, general engine), 3 face(s)" "the box intersected with the piercing cylinder also took the General-engine exact path"
if echo "$BG" | grep -q "! No object with id"; then echo "FAIL boolean-general-engine script's own SelID bookkeeping was wrong (references a missing id)"; fail=1; else echo "ok   boolean-general-engine script's SelID bookkeeping matched every object the app actually created"; fi
echo "$BG" | grep -E "^(ok|FAIL)"
if echo "$BG" | grep -q "^FAIL"; then fail=1; fi
bgecheck "^ok   expect_objects 0" "boolean-general-engine script cleaned up to zero objects at the end"

# Adversarial curve self-intersection: a closed bowtie polyline fed into
# PlanarSrf (must be rejected) and a solid-capping Extrude (must degrade to
# an open surface), an open self-crossing polyline confirming IntersectSelf
# still finds real crossings after the shared CurveSelfIntersects refactor,
# and a simple closed curve confirming no false positive on ordinary
# geometry (see curve_adversarial_script.txt and adversarial_corpus_notes.md).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  CA="$(timeout 900 "$BIN" --smoke 300 --script "$HERE/curve_adversarial_script.txt" 2>&1)" || { echo "$CA"; echo "FAIL: curve-adversarial script exited non-zero"; exit 1; }
else
  CA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 300 --script "$HERE/curve_adversarial_script.txt" 2>&1)" || { echo "$CA"; echo "FAIL: curve-adversarial script exited non-zero"; exit 1; }
fi
cacheck() { if echo "$CA" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$CA" "$1"; fail=1; fi; }
cacheck "! PlanarSrf: 1 curve(s) cross themselves" "PlanarSrf rejected a closed bowtie polyline instead of silently building a self-crossing trim loop"
cacheck "! Extrude: the selected curve crosses itself - building an open surface instead of a solid cap" "Extrude Solid=Yes degraded a bowtie curve to an open surface instead of claiming a solid it cannot honestly build"
cacheck "  intersection at 5,5,0" "IntersectSelf still finds a real self-crossing after the shared CurveSelfIntersects refactor"
echo "$CA" | grep -E "^(ok|FAIL)"
if echo "$CA" | grep -q "^FAIL"; then fail=1; fi
cacheck "Created 1 planar surface(s)" "a simple (non-self-intersecting) closed curve still built a normal planar surface - no false positive from the self-intersection check"
CA_CROSS_COUNT=$(echo "$CA" | grep -c "cross themselves\|crosses itself")
if [ "$CA_CROSS_COUNT" = "2" ]; then echo "ok   exactly the two bowtie cases were flagged as self-intersecting, nothing else"; else echo "FAIL exactly the two bowtie cases were flagged as self-intersecting, nothing else (got $CA_CROSS_COUNT)"; fail=1; fi
cacheck "gl_error=0" "curve-adversarial script ran without OpenGL errors"

# Analysis: Distance/Length/Area/Volume/AreaCentroid/VolumeCentroid/What/List/BoundingBox/
# Dir/Check/SelBadObjects/Angle/Radius/Diameter/Curvature/CurvatureGraph/Zebra/EMap/
# CurvatureAnalysis/DraftAngleAnalysis/ShowEdges/CrvDeviation/PointDeviation/Audit/SystemInfo
# (see analyze_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  AN="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/analyze_script.txt" 2>&1)" || { echo "$AN"; echo "FAIL: analyze script exited non-zero"; exit 1; }
else
  AN="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/analyze_script.txt" 2>&1)" || { echo "$AN"; echo "FAIL: analyze script exited non-zero"; exit 1; }
fi
echo "$AN" | grep -E "^(ok|FAIL)"
if echo "$AN" | grep -q "^FAIL"; then fail=1; fi
echo "$AN" | grep -q "^smoke:" || { echo "$AN"; echo "FAIL: analyze script produced no smoke line"; fail=1; }
azcheck() { if echo "$AN" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$AN" "$1"; fail=1; fi; }
azcheck "Deviation: min 1 max 1" "CrvDeviation now delegates to the kernel's own NurbsCurve::DeviationTo() - two parallel lines 1 unit apart converge to exactly that constant separation, not the old fixed-100-sample approximation"

# Audit on a genuinely invalid object (not just a self-intersecting-but-valid
# bowtie curve, see curve_adversarial_script.txt for that different case):
# MakeInvalidCurve builds one deterministic IsValid()==false NURBS curve, and
# Check/Audit/SelBadObjects must all report it with a specific reason, not
# just a bare count (see audit_invalid_script.txt and cmd_analyze.cpp).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  AI="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/audit_invalid_script.txt" 2>&1)" || { echo "$AI"; echo "FAIL: audit-invalid script exited non-zero"; exit 1; }
else
  AI="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/audit_invalid_script.txt" 2>&1)" || { echo "$AI"; echo "FAIL: audit-invalid script exited non-zero"; exit 1; }
fi
echo "$AI" | grep -E "^(ok|FAIL)"
if echo "$AI" | grep -q "^FAIL"; then fail=1; fi
echo "$AI" | grep -q "^smoke:" || { echo "$AI"; echo "FAIL: audit-invalid script produced no smoke line"; fail=1; }
aicheck() { if echo "$AI" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$AI" "$1"; fail=1; fi; }
aicheck "Object [0-9]*: valid" "Check reported the plain line as valid"
aicheck "Object [0-9]*: INVALID - .*knot" "Check reported the deliberately invalid curve INVALID with a specific (knot-vector) reason, not just a bare count"
aicheck "Audit: 2 objects, 1 invalid" "Audit's summary counted exactly the one invalid object (out of the 2 in the doc - the valid Line and the deliberately invalid curve)"
aicheck "1 bad object(s) selected" "SelBadObjects selected exactly the invalid curve"
aicheck "Audit: 0 objects, 0 invalid" "Audit correctly reports 0 invalid once the bad object is deleted"

# Views: standard views, Zoom variants, display modes, NamedView Save/Restore, 4View/3View/
# MaxViewport, CPlane commands, viewport cycling (see view_script.txt).
mkdir -p "$TMPW/view"
sed "s|@TMP@|$TMPW/view|g" "$HERE/view_script.txt" > "$TMPW/view_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  VW="$(timeout 900 "$BIN" --smoke 150 --script "$TMPW/view_script.txt" 2>&1)" || { echo "$VW"; echo "FAIL: view script exited non-zero"; exit 1; }
else
  VW="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$TMPW/view_script.txt" 2>&1)" || { echo "$VW"; echo "FAIL: view script exited non-zero"; exit 1; }
fi
echo "$VW" | grep -E "^(ok|FAIL)"
if echo "$VW" | grep -q "^FAIL"; then fail=1; fi
echo "$VW" | grep -q "^smoke:" || { echo "$VW"; echo "FAIL: view script produced no smoke line"; fail=1; }
[ -s "$TMPW/view/view.bmp" ] && echo "ok   ViewCaptureToFile wrote view.bmp" || { echo "FAIL ViewCaptureToFile"; fail=1; }
[ -s "$TMPW/view/screen.bmp" ] && echo "ok   ScreenCaptureToFile wrote screen.bmp" || { echo "FAIL ScreenCaptureToFile"; fail=1; }

# A genuine, 100%-reproducible Windows-only hang (RHINO8_KILLER_AUDIT.md row
# L) has been seen starting exactly here on every Windows CI run since it was
# first noticed: the $BIN launch below produces zero output - not even the
# unbuffered startup breadcrumbs main.cpp now prints before glfwInit() - until
# the job's own timeout kills it. It is not caused by anything in
# state_script2.txt itself (never reached). A 3-second pause here (testing an
# OS-resource-contention-between-back-to-back-launches hypothesis) was tried
# and made no difference (commit e59759b) - see row L for what that rules out
# and what's still open.

# Extended state/window/misc: the remaining cmd_state.cpp and cmd_misc.cpp
# commands not already exercised elsewhere (see state_script2.txt).
mkdir -p "$TMPW/state2"
sed "s|@TMP@|$TMPW/state2|g" "$HERE/state_script2.txt" > "$TMPW/state_script2.txt"
# Piped through `tee` rather than plain `S2="$(...)"` command substitution:
# a command substitution only gets echoed to the CI log once the child
# process EXITS, so on row L's Windows-only hang here, that older capture
# style could never have distinguished "hung before printing anything" from
# "hung after printing, but nothing was echoed to the log yet" - it would
# show zero output either way. `tee` streams whatever the child does write
# (including main.cpp's pre-glfwInit() breadcrumbs) to the CI log live, as
# it happens, so a future recurrence can actually confirm or rule out where
# the hang sits instead of leaving it ambiguous. See row L.
STATE2_LOG="$TMPW/state2_live.log"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  if "$BIN" --smoke 200 --script "$TMPW/state_script2.txt" 2>&1 | tee "$STATE2_LOG"; then :; else
    echo "FAIL: state2 script exited non-zero"; exit 1
  fi
else
  if timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$TMPW/state_script2.txt" 2>&1 | tee "$STATE2_LOG"; then :; else
    echo "FAIL: state2 script exited non-zero"; exit 1
  fi
fi
S2="$(cat "$STATE2_LOG")"
echo "$S2" | grep -E "^(ok|FAIL)"
if echo "$S2" | grep -q "^FAIL"; then fail=1; fi
echo "$S2" | grep -q "^smoke:" || { echo "$S2"; echo "FAIL: state2 script produced no smoke line"; fail=1; }
s2check() { if echo "$S2" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$S2" "$1"; fail=1; fi; }
# SetObjectDisplayMode Ghosted/X-Ray (PARITY_MAP.md's "Per-object display
# mode override" item, upgraded this pass from Wireframe/Shaded-only to
# also cover these two alpha-based modes) - real per-object overrides, not
# just accepted-and-ignored text.
s2check "SetObjectDisplayMode: 1 object(s) now always shown Ghosted (35% opaque)" "SetObjectDisplayMode Ghosted is a genuine per-object override, not silently treated as UseViewport"
s2check "SetObjectDisplayMode: 1 object(s) now always shown X-Ray (18% opaque)" "SetObjectDisplayMode X-Ray is a genuine per-object override, not silently treated as UseViewport"
# SetObjectDisplayMode Monochrome (PARITY_MAP.md's "Per-object display mode
# override" item, extended this pass from Wireframe/Shaded/Ghosted/X-Ray to
# also cover this fifth mode) - a real per-object override, not just
# accepted-and-ignored text.
s2check "SetObjectDisplayMode: 1 object(s) now always shown Monochrome (flat grey, fully opaque)" "SetObjectDisplayMode Monochrome is a genuine per-object override, not silently treated as UseViewport"
s2check "WhatsNew: opened the What's New window" "WhatsNew opens its own real changelog window, not the About box"
# Regression guard for the "changelog.md never shipped" bug: WhatsNew's
# confirmation print above only means the *window* opened - Panels.cpp's
# Changelog()/DrawWhatsNewWindow() silently falls back to "The changelog
# (data/changelog.md) could not be found next to this build." inside that
# window when data/changelog.md isn't next to the exe, and nothing printed
# to stdout/history would tell us that happened (ImGui window contents
# aren't scriptable headlessly). So check the one thing that actually
# determines which of those two states the user sees: that CMakeLists.txt's
# DINO8_DATA_FILES copy step really did put a real, non-trivial
# changelog.md next to $BIN (see commit 7ebfdc3 - DINO8_DATA_FILES used to
# list only commands.json/hatchpatterns.pat).
CHANGELOG_NEXT_TO_BIN="$(dirname "$BIN")/data/changelog.md"
if [ -s "$CHANGELOG_NEXT_TO_BIN" ] && [ "$(wc -c < "$CHANGELOG_NEXT_TO_BIN")" -gt 200 ] && grep -q "^## " "$CHANGELOG_NEXT_TO_BIN"; then
  echo "ok   data/changelog.md was actually installed next to the binary (WhatsNew would show real content, not the missing-file fallback)"
else
  echo "FAIL data/changelog.md missing/empty next to \$BIN - WhatsNew would silently show its 'could not be found' fallback"
  fail=1
fi
s2check "Echo on" "Echo toggled on"
s2check "Echo off" "Echo toggled off"
s2check "Redraw on" "SetRedrawOn"
s2check "Redraw off" "SetRedrawOff"
s2check "ResetMessageBoxes: all 'do not show again' choices cleared" "ResetMessageBoxes"
s2check "Fullscreen on" "Fullscreen on"
s2check "Fullscreen off" "Fullscreen off"
s2check "Window maximized" "Maximize"
s2check "Window restored" "Restore"
s2check "SplitViewportVertical: added .* viewports" "SplitViewportVertical (cmd_viewtools's real implementation)"
s2check "BringViewportToTop: " "BringViewportToTop (cmd_viewtools's real implementation)"
s2check "SetMaximizedViewport: Perspective" "SetMaximizedViewport (cmd_viewtools's real implementation)"
s2check "ViewportTabs: hidden" "ViewportTabs (cmd_viewtools's real implementation)"
s2check "Zoom1To1Calibrate: .* pixels per mm" "Zoom1To1Calibrate (cmd_viewtools's real implementation)"
s2check "SetZoomExtentsBorder: border factor 1.2" "SetZoomExtentsBorder (cmd_viewtools's real implementation)"
s2check "Ortho angle = 45 deg" "OrthoAngle"
s2check "Grid snap size = 2.5" "SnapSize"
s2check "Grid snap on, size = 5" "SetSnap"
s2check "DragMode = World" "DragMode World (also covers the removed Dragmode duplicate)"
s2check "Drag strength = 50%" "DragStrength"
s2check "Drag copy on" "DragCopy"
s2check "Options exported to " "OptionsExport"
s2check "Options imported from " "OptionsImport"
s2check "Working folder: " "SetWorkingFolder"
s2check "Autosave: " "Autosave"
s2check "Model base point 1,2,3" "ModelBasepoint"
s2check "Earth anchor point 4,5,6" "EarthAnchorPoint"
s2check "PointCloud: 3 point(s)" "PointCloud builds a genuine ObjectKind::PointCloud object (a real ON_PointCloud-backed point set) from the selected Point objects, not a group of separate Point objects"
s2check 'point cloud "PointCloud"' "What reports the new object's own kind as a point cloud, not a group"
s2check "Points: 3" "the point cloud reports its real point count"
s2check "Colors: no" "no per-point colors were set on this cloud"
s2check "Normals: no" "no per-point normals were set on this cloud"
s2check "Bounding box: (0, 0, 0) to (1, 1, 0)" "the point cloud's own bounding box, computed straight from its points"
s2check "Bounding box: (10, 0, 0) to (11, 1, 0)" "Move actually moved the point cloud's own points (not a group's member points) - the bounding box shifted by exactly 10,0,0, and this same bounding box also reappeared unchanged after the Save/Open .3dm round trip that preceded the Move, confirming the points survive the file format intact"
s2check "InfinitePlane: 10000 x 10000 plane" "InfinitePlane"
s2check "BringToFront: 4 object(s)" "BringToFront (DrawOrder family) - 4, not 5, since PointCloud now consumes its 2 source Point objects into 1 real object instead of leaving them grouped"
s2check "Bounce: polyline with 1 bounce(s)" "Bounce (cmd_solidtools's real ray-bounce, no longer shadowed)"
s2check "GumballAlignment = World" "GumballAlignment"
s2check "GumballScaleMode = Uniform" "GumballScaleMode"
s2check "Gumball auto reset off" "GumballAutoReset"
s2check "Gumball dynamic relocate on" "GumballDynamicRelocate"
s2check "Gumball origin 5,5,5" "GumballRelocate"
s2check "Gumball reset" "GumballReset"
s2check "ViewCaptureToClipboard: [0-9]*x[0-9]* image copied to the system clipboard (image/png)" "ViewCaptureToClipboard copied a real image to the OS clipboard"
s2check "ScreenCaptureToClipboard: [0-9]*x[0-9]* image copied to the system clipboard (image/png)" "ScreenCaptureToClipboard copied a real image to the OS clipboard"
s2check "Alias qq -> Box" "Alias"
s2check "Alias qq -> Line" "Alias qq re-set to Line before the persistence round trip"
s2check "Alias qq -> Circle" "Alias qq re-set to Circle in memory, about to be overwritten by OptionsImport"
# Alias persistence round trip (state_script2.txt): qq was Line when
# OptionsExport wrote alias_roundtrip.json, then overwritten to Circle
# in-memory, then OptionsImport must restore Line from the file - proving
# CommandEngine's alias table is actually read back, not just written.
# The list print (Alias with no argument, AliasCommand::OnEnter) has no
# "Alias " prefix, unlike the Alias-command's own set confirmation above
# (each app-printed line is echoed as "history: <line>" by main.cpp's
# script harness), so anchoring right after that prefix is what tells the
# two apart.
if echo "$S2" | grep -qE "^history: qq -> Line$"; then echo "ok   OptionsImport restored the alias table (qq back to Line, not the in-memory Circle)"; else echo "FAIL OptionsImport did not restore aliases"; near "$S2" "qq -> "; fail=1; fi
if echo "$S2" | grep -qE "^history: qq -> Circle$"; then echo "FAIL OptionsImport left the pre-import in-memory alias (Circle) in place instead of restoring the saved one"; fail=1; else echo "ok   qq is not stuck on the pre-import in-memory value"; fi
# Same OptionsExport call also persists the Command system's Macro Editor
# buffer (AppState::macro_text, Settings.cpp) - checked directly in the
# written file since headless smoke scripts have no console command to
# read the ImGui-only macro buffer back out.
ALIAS_JSON="$TMPW/state2/alias_roundtrip.json"
if [ -f "$ALIAS_JSON" ] && grep -qF '"macro_text": "! _Box 0,0,0 10,10,10\n_ZoomExtents\n"' "$ALIAS_JSON"; then
  echo "ok   OptionsExport persists the Macro Editor's buffer (macro_text)"
else
  echo "FAIL OptionsExport did not persist macro_text as expected"; fail=1
fi
if [ -f "$ALIAS_JSON" ] && grep -qF '"qq": "Line"' "$ALIAS_JSON"; then
  echo "ok   OptionsExport persists the alias table (aliases.qq)"
else
  echo "FAIL OptionsExport did not persist the alias table"; fail=1
fi
# User-assignable keyboard shortcuts (Options > Shortcuts, AppState-adjacent
# Application::user_shortcuts): no console command sets these (matching real
# Rhino, where keyboard customization is dialog-only too), so this checks
# the export/import machinery's shape directly - the default empty table
# round-trips as a valid, present JSON array, the same "key exists and
# parses" bar macro_text's own check above uses for another UI-only field.
if [ -f "$ALIAS_JSON" ] && grep -qF '"shortcuts": []' "$ALIAS_JSON"; then
  echo "ok   OptionsExport persists the (empty-by-default) user keyboard shortcut table"
else
  echo "FAIL OptionsExport did not persist the shortcuts key as expected"; fail=1
fi
if echo "$S2" | grep -qF "2+3*4 = 14"; then echo "ok   Calc"; else echo "FAIL Calc"; fail=1; fi
s2check "Left sidebar" "ToggleLeftSidebar"
s2check "Pause: continuing" "Pause"
s2check "MultiPause: continuing" "MultiPause"
s2check "GetIssueState: ok - no issues reported" "GetIssueState"
s2check "Minimize: skipped in headless mode" "Minimize (headless-safe)"
s2check "Swapped views of " "SwapView"
s2check "Single viewport layout" "OneView"
s2check "Ortho on (angle 90 deg)" "SetOrtho"
s2check "Ortho snap to CPlane Z on" "OrthoSnapToCPlaneZ"
s2check "Snap to locked objects off" "SnapToLocked"
s2check "Snap to occluded objects off" "SnapToOccluded"
s2check "Snap to meshes off" "SnapToMeshes"
s2check "Snap to mesh objects off" "SnapToMeshObject"
s2check "Snap to SubD objects off" "SnapToSubDObject"
s2check "Osnap panel hidden" "ShowOsnap"
s2check "Remember copy options on" "RememberCopyOptions"
s2check "DollyZoom: lens 85 mm" "DollyZoom"
s2check "Right sidebar (Layers, Properties) hidden" "ToggleRightSidebar"
s2check "Toolbar shown" "ShowToolbar"
s2check "Toolbar lock on" "ToolbarLock"
s2check "Recent commands:" "PopupPopular"
s2check "Menus: File, Edit, View, Curve" "Menus"
s2check "Reset: snaps, panels, toolbar and preferences restored" "Reset"
s2check "FileExplorer: " "FileExplorer"
s2check "OpenURL: https://example.org/open" "OpenURL"
s2check "WebBrowser: https://example.org/browser" "WebBrowser"
s2check "Gumball: on, alignment CPlane, scale Uniform" "GumballSettings"
s2check "Named position 'Pos1' saved (1 object" "NamedPosition Save captured the box"
s2check "Bounding box: (160, 0, 0) to (170, 10, 10)" "the box actually moved before NamedPosition Restore"
s2check "Named position 'Pos1' restored: 1 of 1 object" "NamedPosition Restore reported success"
s2check "Bounding box: (60, 0, 0) to (70, 10, 10)" "NamedPosition Restore put the box back exactly"
s2check "Named position 'Pos1' deleted" "NamedPosition Delete"
s2check "[0-9]* snapshot(s)" "Snapshots (cmd_session.cpp's real implementation, no longer shadowed)"
# HistoryPurge/HistoryUpdate are real now (cmd_history.cpp's HistoryRecord
# mechanism, replacing the old dead cmd_state.cpp stubs that always claimed
# no history was recorded); the document is empty at this point in the
# script (SelAll/Delete ran earlier), so both correctly report 0 objects -
# see history_purge_script.txt below for the real-history, non-zero case.
s2check "HistoryPurge: 0 object(s) had their recorded construction history removed (nothing to purge)" "HistoryPurge reports 0 with no recorded history in the (now empty) document"
s2check "HistoryUpdate: 0 object(s) re-evaluated from their source curve(s)' current geometry" "HistoryUpdate (Rhino's alternate name for UpdateHistory) reports 0 the same way"
s2check "[0-9]* attached reference model" "Worksession (cmd_session.cpp's real implementation, no longer shadowed)"
s2check "LimitReferenceModel: 0 object(s) removed from 'nonexistent.3dm'" "LimitReferenceModel (cmd_session.cpp's real implementation, no longer shadowed)"
s2check "ContentFilter: 'Wood' (Materials and Textures panels; ContentFilter Clear to remove)" "ContentFilter set a name filter"
s2check "ContentFilter: off (showing every entry)" "ContentFilter Clear removed it"
s2check "Dino 8 is free software. No licence keys" "Licenses"
s2check "Dino 8 does not phone home" "CheckForUpdates"
s2check "Support: open an issue at " "TechSupport"
s2check "History recording: .* object(s) with live construction history" "History (real toggle+report, cmd_history.cpp's own implementation, no longer a stub)"
s2check "History recording: .* (type On or Off to change)" "RecordHistory (shares History's own toggle)"
s2check "Text: [0-9]* curve(s) from " "Text (annotate's real text-curve command, no longer shadowed)"
s2check "Dino Flow: opened the node editor" "Grasshopper"
s2check "PackageManager: opened the package manager" "PackageManager"
s2check "PluginManager: opened the plug-in manager" "PluginManager"

# Dig* digitizer family (DigBeep/DigCamera/DigClick/DigLine/DigSection/
# DigSketch/Digitize): DigConnect Protocol=Simulated needs no hardware -
# state_script2.txt feeds it points as plain "x,y,z" tokens, proving these
# commands' real read/calibrate/build pipeline end-to-end, not just that
# DigConnect itself is real.
s2check "Digitizer: connected, protocol Simulated, not calibrated" "DigConnect Protocol=Simulated connects with no hardware"
s2check "Digitize: digitized 1,2,3" "Digitize reads a simulated point and reports its exact coordinates"
s2check "Digitize: digitized 4,5,6" "Digitize reads a second simulated point"
s2check "DigLine: line digitized" "DigLine builds a real 2-point line from two simulated points"
s2check "Bounding box min 10,0,0 max 20,0,0" "DigLine's own curve spans exactly its two digitized endpoints"
s2check "DigCamera: camera set from two digitized points" "DigCamera consumes two simulated points (eye, target)"
s2check "location 100,0,0, target 0,0,0" "DigCamera actually moved the active viewport's camera eye/target"
s2check "DigSection: 3 point(s) digitized into a curve" "DigSection builds a polyline from a simulated point sequence"
s2check "Bounding box min 0,0,0 max 10,10,0" "DigSection's polyline spans exactly its 3 digitized points"
s2check "DigSketch: 3 point(s) digitized into a curve" "DigSketch (same pipeline as DigSection) builds its own polyline"
s2check "Bounding box min 0,0,0 max 5,5,0" "DigSketch's polyline spans exactly its 3 digitized points"
s2check "DigDisconnect: disconnected" "DigDisconnect"
s2check "$(printf '\a')" "DigBeep rings a real terminal bell (raw \\a byte) once digitizing is on - not suppressed under --smoke"

# Files: New/Open/Revert/Save/SaveAs/SaveSmall/IncrementalSave/SaveAsTemplate/
# Import/Export/ExportSelected/ExportWithOrigin/Notes/DocumentProperties/Units/
# Audit3dmFile (see file_script.txt).
mkdir -p "$TMPW/file"
sed "s|@TMP@|$TMPW/file|g" "$HERE/file_script.txt" > "$TMPW/file_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FL="$(timeout 900 "$BIN" --smoke 150 --script "$TMPW/file_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: file script exited non-zero"; exit 1; }
else
  FL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$TMPW/file_script.txt" 2>&1)" || { echo "$FL"; echo "FAIL: file script exited non-zero"; exit 1; }
fi
echo "$FL" | grep -E "^(ok|FAIL)"
if echo "$FL" | grep -q "^FAIL"; then fail=1; fi
echo "$FL" | grep -q "^smoke:" || { echo "$FL"; echo "FAIL: file script produced no smoke line"; fail=1; }
flcheck() { if echo "$FL" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$FL" "$1"; fail=1; fi; }
flcheck "Saved $TMPW/file/file1.3dm" "Save wrote file1.3dm"
flcheck "Opened $TMPW/file/file1.3dm (3 objects)" "Open re-read file1.3dm"
flcheck "Saved $TMPW/file/file2.3dm" "SaveAs wrote file2.3dm"
flcheck "Opened $TMPW/file/file2.3dm (3 objects)" "Open re-read file2.3dm"
flcheck "Imported $TMPW/file/file1.3dm" "Import brought file1.3dm's objects in"
# Real geometric-fidelity proof, not just object counts: List (run once
# right before the first Save, once right after the matching Open) prints
# each object's exact fingerprint - a degree/CV count for curves, face/edge
# count for breps, face/edge/vertex/crease count for SubDs. Asserting each
# line appears *exactly* twice (grep -c over the whole captured script
# output, since grep -q would already be satisfied by the pre-save
# occurrence alone) proves the .3dm round trip didn't silently drop or
# corrupt control points, faces, or SubD topology - Box (brep), Sphere
# (brep - confirmed via the real List output, not assumed), and SubDBox
# (the first SubD object any .3dm round-trip test in this suite covers).
FL_BOX_COUNT=$(echo "$FL" | grep -c "^history:   6 faces, 12 edges, closed solid$")
[ "$FL_BOX_COUNT" = "2" ] && echo "ok   Box's exact 6 faces/12 edges fingerprint survived the .3dm round trip (List ran twice, both matched)" || { echo "FAIL Box's exact fingerprint did not appear exactly twice (got $FL_BOX_COUNT) - the .3dm round trip silently changed the brep"; fail=1; }
FL_SPHERE_COUNT=$(echo "$FL" | grep -c "^history:   1 faces, 1 edges, closed solid$")
[ "$FL_SPHERE_COUNT" = "2" ] && echo "ok   Sphere's exact 1 face/1 edge fingerprint survived the .3dm round trip" || { echo "FAIL Sphere's exact fingerprint did not appear exactly twice (got $FL_SPHERE_COUNT) - the .3dm round trip silently changed the brep"; fail=1; }
FL_SUBD_COUNT=$(echo "$FL" | grep -c "^history:   6 faces, 12 edges, 8 vertices, 0 creases$")
[ "$FL_SUBD_COUNT" = "2" ] && echo "ok   SubDBox's exact 6 faces/12 edges/8 vertices/0 creases fingerprint survived the .3dm round trip" || { echo "FAIL SubDBox's exact fingerprint did not appear exactly twice (got $FL_SUBD_COUNT) - the .3dm round trip silently changed the SubD topology"; fail=1; }
flcheck "Exported $TMPW/file/export1.obj" "Export wrote export1.obj"
test -s "$TMPW/file/file1.3dm" && echo "ok   file1.3dm exists" || { echo "FAIL file1.3dm missing"; fail=1; }
test -s "$TMPW/file/file2.3dm" && echo "ok   file2.3dm exists" || { echo "FAIL file2.3dm missing"; fail=1; }
test -s "$TMPW/file/file2_1.3dm" && echo "ok   IncrementalSave wrote file2_1.3dm" || { echo "FAIL file2_1.3dm missing"; fail=1; }
test -s "$TMPW/file/file2_1_2.3dm" && echo "ok   IncrementalSave wrote file2_1_2.3dm" || { echo "FAIL file2_1_2.3dm missing"; fail=1; }
test -s "$TMPW/file/export1.obj" && echo "ok   export1.obj exists" || { echo "FAIL export1.obj missing"; fail=1; }
flcheck "Exported $TMPW/file/exportorigin.obj (origin at 5,5,0)" "ExportWithOrigin re-based to the picked point"
test -s "$TMPW/file/exportorigin.obj" && echo "ok   exportorigin.obj exists" || { echo "FAIL exportorigin.obj missing"; fail=1; }
