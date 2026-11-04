
# ---------------------------------------------------------------------------
# H3R_: construction history, part 3 - Sweep1/Sweep2 with SEVERAL cross-sections, the non-planar fitted Patch and
# FilletSrf/ChamferSrf (Trim=No) now record {sources, options} and rebuild when a source is edited (automatic
# propagation, no UpdateHistory), including a source edited through its CONTROL POINTS (HBar + HBarDragSelfTest: the
# TransformSubObjects call sequence a gizmo/control-point drag makes). Every rebuild is compared with the SAME
# construction built fresh (History Off) from the same, already moved, sources; every refusal keeps the old result.
# Scripts: h3r_{sweep1,sweep2,patch,fillet}_script.txt (their headers list the numbered measurements).
# ---------------------------------------------------------------------------
H3R_DIR="$TMPW/h3r"
mkdir -p "$H3R_DIR"
h3r_run() {  # h3r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H3R_DIR|g" "$HERE/h3r_$1_script.txt" > "$H3R_DIR/h3r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H3R_DIR/h3r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H3R_DIR/h3r_$1_script.txt" 2>&1
  fi
}
h3r_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
h3r_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
h3r_ar() { { grep -oE 'Area = [0-9.e+-]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Area = //'; }
h3r_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
h3r_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
# bounding box n of output $1 equals the expected "x0,y0,z0,x1,y1,z1" within $4 (a tolerance range: the Windows CI tessellates slightly differently)
h3r_sb() { h3r_ok "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(h3r_bb "$1" "$2"), expected $3 +/- $4)"; }
# bounding box n equals bounding box m of the same output (a rebuilt result against the same construction built fresh)
h3r_eq() { h3r_ok "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$(h3r_bb "$1" "$3")" "$4")" "$5 (#$2 $(h3r_bb "$1" "$2") vs #$3 $(h3r_bb "$1" "$3"))"; }
# bounding box n differs from bounding box m by more than $4 in at least one coordinate (the edit really changed the result)
h3r_ne() { h3r_ok "$([ "$(h3r_closebb "$(h3r_bb "$1" "$2")" "$(h3r_bb "$1" "$3")" "$4")" = 1 ] && echo 0 || echo 1)" "$5 (#$2 $(h3r_bb "$1" "$2") vs #$3 $(h3r_bb "$1" "$3"))"; }
h3r_sa() { h3r_ok "$(h3r_closev "$(h3r_ar "$1" "$2")" "$3" "$4")" "$5 (measured $(h3r_ar "$1" "$2"), expected $3 +/- $4)"; }
h3r_eqa() { h3r_ok "$(h3r_closev "$(h3r_ar "$1" "$2")" "$(h3r_ar "$1" "$3")" "$4")" "$5 (area #$2 $(h3r_ar "$1" "$2") vs #$3 $(h3r_ar "$1" "$3"))"; }
h3r_nea() { h3r_ok "$([ "$(h3r_closev "$(h3r_ar "$1" "$2")" "$(h3r_ar "$1" "$3")" "$4")" = 1 ] && echo 0 || echo 1)" "$5 (area #$2 $(h3r_ar "$1" "$2") vs #$3 $(h3r_ar "$1" "$3"))"; }
h3r_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
h3r_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- Sweep1 with two cross-sections (h3r_sweep1_script.txt)
# Bounding boxes: 1 fresh wall 2 section 2 moved +1 Y 3 section 1 moved -1 Y 4 moved again then Undo (= 3) 5 moved again 6 rail control points moved
#   7 fresh sweep from the same moved sources (= 6) 8 reopened, section 1 moved +1 X 9 fresh (= 8) 10 refused (= 8) 11 History Off control (= 1)
# Areas: 1 fresh 2 section 2 moved 3 section 1 moved twice 4 control points moved 5 fresh (= 4) 6 reopened 7 fresh (= 6) 8 refused (= 6) 9 History Off control (= 1)
H3R_S1="$(h3r_run sweep1)" || { echo "$H3R_S1"; echo "FAIL: h3r sweep1 script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_S1" || { echo "$H3R_S1"; echo "FAIL: h3r sweep1 script produced no smoke line"; fail=1; }
h3r_has "$H3R_S1" "Sweep1: exact kernel multi-section sweep (2 sections, 32 rail stations)" "H3R_sweep1: the two-section sweep is the exact kernel one"
h3r_count "$H3R_S1" "object 4: Sweep1 <- 1,2,3" 3 "H3R_sweep1: the record lists the rail and BOTH sections (live, and read back from the .3dm after New + Open)"
h3r_sb "$H3R_S1" 1 "-1.75,-1.48,0,1.5,1.48,10" 0.15 "H3R_sweep1: curved rail, circles r=1 (z=0) and r=1.5 (z=10)"
h3r_has "$H3R_S1" "History: source object(s) 3 changed - 1 dependent(s) re-evaluated (4)" "H3R_sweep1: moving section 2 rebuilds the wall automatically (no UpdateHistory)"
h3r_sb "$H3R_S1" 2 "-1.75,-0.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 2 moved +1 Y: the wall's Y range grew to follow it"
h3r_ne "$H3R_S1" 2 1 0.3 "H3R_sweep1 control: the wall really changed (not the old bounding box)"
h3r_sb "$H3R_S1" 3 "-1.75,-1.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 1 moved -1 Y: the wall followed"
h3r_eq "$H3R_S1" 4 3 0.02 "H3R_sweep1: Undo takes the section move and the rebuilt wall back together (same undo step)"
h3r_sb "$H3R_S1" 5 "-1.75,-2.99,0,1.5,2.48,10" 0.15 "H3R_sweep1: section 1 moved -1 Y again: the wall followed"
h3r_has "$H3R_S1" "HBarDragSelfTest: moved anchor control point 1 by 1.5,0,0" "H3R_sweep1: the rail's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_S1" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (4)" "H3R_sweep1: editing the rail's CONTROL POINTS rebuilt the wall with no UpdateHistory"
h3r_ne "$H3R_S1" 6 5 0.3 "H3R_sweep1 control: the control-point edit really changed the wall"
h3r_eq "$H3R_S1" 7 6 0.02 "H3R_sweep1: the wall rebuilt after the control-point edit equals the same sweep built fresh from the edited rail and sections"
h3r_eqa "$H3R_S1" 5 4 0.8 "H3R_sweep1: ...and has the same area"
h3r_sa "$H3R_S1" 1 75.1 1.5 "H3R_sweep1: wall area"
h3r_nea "$H3R_S1" 4 3 0.3 "H3R_sweep1 control: the control-point edit changed the area"
h3r_eq "$H3R_S1" 9 8 0.02 "H3R_sweep1: after Save/New/Open the record is back and moving a section rebuilds the wall (equals a fresh sweep)"
h3r_eqa "$H3R_S1" 7 6 0.8 "H3R_sweep1: ...with the same area"
h3r_ne "$H3R_S1" 8 7 0.1 "H3R_sweep1 control: the reopened wall changed when its section moved"
h3r_has "$H3R_S1" "kept as they were: object 4 - dino8::kernel::Brep::Sweep1Sections: the rail never crosses the plane of section 2" "H3R_sweep1 refuse: a section the rail no longer crosses is reported with the kernel's reason and the wall kept"
h3r_eq "$H3R_S1" 10 8 0.02 "H3R_sweep1 refuse: the old wall keeps its shape"
h3r_eq "$H3R_S1" 11 1 0.02 "H3R_sweep1 History Off control: moving a section leaves a wall built with History Off alone"
h3r_has "$H3R_S1" "History recording: off. 0 object(s) with live construction history" "H3R_sweep1 History Off control: nothing was recorded"

# --- Sweep2 with two cross-sections (h3r_sweep2_script.txt)
# Bounding boxes: 1 fresh wall 2 section 2 moved +1 Y 3 section 1 moved -1 Y 4 moved again then Undo (= 3) 5 rail 2 control points moved 6 fresh (= 5)
#   7 reopened, section 2 moved +1 Y 8 fresh (= 7) 9 refused: two sections at one station (= 7) 10 History Off control (= 1)
# Areas: 1 fresh 2 section 2 moved 3 control points moved 4 fresh (= 3) 5 reopened 6 fresh (= 5) 7 refused (= 5) 8 History Off control (= 1)
H3R_S2="$(h3r_run sweep2)" || { echo "$H3R_S2"; echo "FAIL: h3r sweep2 script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_S2" || { echo "$H3R_S2"; echo "FAIL: h3r sweep2 script produced no smoke line"; fail=1; }
h3r_has "$H3R_S2" "Sweep2: exact kernel multi-section sweep (2 sections, 32 rail stations)" "H3R_sweep2: the two-section sweep is the exact kernel one"
h3r_count "$H3R_S2" "object 5: Sweep2 <- 1,2,3,4" 3 "H3R_sweep2: the record lists both rails and BOTH sections (live, and read back from the .3dm after New + Open)"
h3r_sb "$H3R_S2" 1 "0,0,0,5.53,2,10" 0.15 "H3R_sweep2: straight rail and curved rail, arcs at z=0 and z=10"
h3r_has "$H3R_S2" "History: source object(s) 4 changed - 1 dependent(s) re-evaluated (5)" "H3R_sweep2: moving section 2 rebuilds the wall automatically (no UpdateHistory)"
h3r_sb "$H3R_S2" 2 "0,0,0,5.53,3,10" 0.15 "H3R_sweep2: section 2 moved +1 Y: the wall's Y range grew"
h3r_sb "$H3R_S2" 3 "0,-1,0,5.53,3,10" 0.15 "H3R_sweep2: section 1 moved -1 Y: the wall followed"
h3r_eq "$H3R_S2" 4 3 0.02 "H3R_sweep2: Undo takes the section move and the rebuilt wall back together (same undo step)"
h3r_has "$H3R_S2" "HBarDragSelfTest: moved anchor control point 1 by 1,0,0" "H3R_sweep2: rail 2's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_S2" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (5)" "H3R_sweep2: editing rail 2's CONTROL POINTS rebuilt the wall with no UpdateHistory"
h3r_ne "$H3R_S2" 5 4 0.3 "H3R_sweep2 control: the control-point edit really changed the wall"
h3r_eq "$H3R_S2" 6 5 0.02 "H3R_sweep2: the wall rebuilt after the control-point edit equals the same sweep built fresh from the edited rails and sections"
h3r_eqa "$H3R_S2" 4 3 0.8 "H3R_sweep2: ...and has the same area"
h3r_sa "$H3R_S2" 1 60.7 1.5 "H3R_sweep2: wall area"
h3r_eq "$H3R_S2" 8 7 0.02 "H3R_sweep2: after Save/New/Open the record is back and moving a section rebuilds the wall (equals a fresh sweep)"
h3r_eqa "$H3R_S2" 6 5 0.8 "H3R_sweep2: ...with the same area"
h3r_has "$H3R_S2" "kept as they were: object 5 - dino8::kernel::Brep::Sweep2Sections: two sections sit at the same station of the rails" "H3R_sweep2 refuse: two sections at one station are reported with the kernel's reason and the wall kept"
h3r_eq "$H3R_S2" 9 7 0.02 "H3R_sweep2 refuse: the old wall keeps its shape"
h3r_eq "$H3R_S2" 10 1 0.02 "H3R_sweep2 History Off control: moving a section leaves a wall built with History Off alone"
h3r_has "$H3R_S2" "History recording: off. 0 object(s) with live construction history" "H3R_sweep2 History Off control: nothing was recorded"

# --- Non-planar Patch (h3r_patch_script.txt)
# Bounding boxes: 1 patch through 9 points 2 centre point moved +2 Z 3 fresh (= 2) 4 all points flattened: refused (= 2) 5 a point deleted: refused (= 2)
#   6 saddle curve, trimmed face 7 two control points of the curve moved 8 fresh patch from the moved curve (= 7)
# Areas: 1 patch 2 moved (= 3 fresh) 4 saddle 5 moved (= 6 fresh)
H3R_P="$(h3r_run patch)" || { echo "$H3R_P"; echo "FAIL: h3r patch script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_P" || { echo "$H3R_P"; echo "FAIL: h3r patch script produced no smoke line"; fail=1; }
h3r_has "$H3R_P" "object 10: Patch <- 1,2,3,4,5,6,7,8,9" "H3R_patch: the fitted patch records all nine points it was fitted to"
h3r_has "$H3R_P" "object 2: Patch <- 1" "H3R_patch: the trimmed saddle patch records its curve"
h3r_sb "$H3R_P" 1 "-2,-2,-1,2,2,1" 0.1 "H3R_patch: patch through nine points"
h3r_sa "$H3R_P" 1 17.27 0.3 "H3R_patch: its area (closed form 17.27)"
h3r_has "$H3R_P" "History: source object(s) 5 changed - 1 dependent(s) re-evaluated (10)" "H3R_patch: moving a point re-runs the fit automatically (no UpdateHistory)"
h3r_sb "$H3R_P" 2 "-2,-2,-1,2,2,1.94" 0.15 "H3R_patch: centre point moved +2 Z: the patch followed (3x3 net now)"
h3r_ne "$H3R_P" 2 1 0.3 "H3R_patch control: the patch really changed"
h3r_eq "$H3R_P" 3 2 0.02 "H3R_patch: equals the patch fitted fresh through the moved points"
h3r_eqa "$H3R_P" 2 3 0.3 "H3R_patch: ...with the same area"
h3r_has "$H3R_P" "the sources are now flat (within 0.001 of their best-fit plane), so the fitted patch no longer applies" "H3R_patch refuse: flattened data are reported and the patch kept"
h3r_eq "$H3R_P" 4 2 0.02 "H3R_patch refuse: the patch keeps its shape"
h3r_has "$H3R_P" "object 10 - source object 9 no longer exists" "H3R_patch refuse: a deleted point is reported and the patch kept"
h3r_eq "$H3R_P" 5 2 0.02 "H3R_patch refuse: the patch keeps its shape"
h3r_sa "$H3R_P" 4 84.9 1.5 "H3R_patch: saddle trimmed face area (the flat disc is 78.5)"
h3r_has "$H3R_P" "HBarDragSelfTest: moved anchor control point 3 by 0,0,0.4" "H3R_patch: the saddle curve's control point is moved by the control-point drag call sequence"
h3r_has "$H3R_P" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (2)" "H3R_patch: editing the curve's CONTROL POINTS re-fitted and re-trimmed the face with no UpdateHistory"
h3r_ne "$H3R_P" 7 6 0.3 "H3R_patch control: the control-point edit really changed the face"
h3r_eq "$H3R_P" 8 7 0.02 "H3R_patch: the rebuilt face equals the patch fitted fresh through the edited curve"
h3r_eqa "$H3R_P" 5 6 0.5 "H3R_patch: ...with the same area"

# --- FilletSrf / ChamferSrf, Trim=No (h3r_fillet_script.txt)
# Bounding boxes: 1 fillet r1 2 wall moved +3 X 3 fresh (= 2) 4 EditHistory radius=2 5 fresh r2 (= 4) 6 reopened, wall +2 X 7 fresh (= 6) 8 refused (= 6)
#   9 ChamferSrf 10 wall moved +2 X 11 fresh chamfer (= 10)
# Areas: 1 fillet 2 moved 3 fresh 4 r2 5 fresh r2 6 reopened 7 fresh 8 chamfer 9 moved 10 fresh chamfer  (quarter circle r: pi/2 r x 10; chamfer: sqrt(2) r x 10)
H3R_F="$(h3r_run fillet)" || { echo "$H3R_F"; echo "FAIL: h3r fillet script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H3R_F" || { echo "$H3R_F"; echo "FAIL: h3r fillet script produced no smoke line"; fail=1; }
h3r_has "$H3R_F" "object 3: FilletSrf <- 1,2  [radius=1, endradius=1]" "H3R_fillet: the fillet records both surfaces and its radii (neither is consumed)"
h3r_sb "$H3R_F" 1 "0,0,0,1,10,1" 0.05 "H3R_fillet: radius-1 fillet between a floor and a wall"
h3r_sa "$H3R_F" 1 15.71 0.1 "H3R_fillet: its area (quarter circle pi/2 x 10 = 15.71)"
h3r_has "$H3R_F" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (3)" "H3R_fillet: moving the wall rebuilds the fillet automatically (no UpdateHistory)"
h3r_sb "$H3R_F" 2 "3,0,0,4,10,1" 0.05 "H3R_fillet: wall moved +3 X: the fillet followed"
h3r_eq "$H3R_F" 3 2 0.02 "H3R_fillet: equals the fillet built fresh between the moved surfaces"
h3r_has "$H3R_F" "EditHistory: object 3 (FilletSrf): radius 1 -> 2." "H3R_fillet: EditHistory changes the radius"
h3r_sb "$H3R_F" 4 "3,0,0,5,10,2" 0.05 "H3R_fillet: radius-2 rebuild"
h3r_sa "$H3R_F" 4 31.42 0.2 "H3R_fillet: its area (pi x 10 = 31.42)"
h3r_eq "$H3R_F" 5 4 0.02 "H3R_fillet: equals the radius-2 fillet built fresh"
h3r_has "$H3R_F" "object 3: FilletSrf <- 1,2  [radius=2, endradius=2]" "H3R_fillet: record (with the edited radius) read back from the .3dm after New + Open"
h3r_sb "$H3R_F" 6 "5,0,0,7,10,2" 0.05 "H3R_fillet: reopened, wall moved +2 X more: the fillet followed"
h3r_eq "$H3R_F" 7 6 0.02 "H3R_fillet: equals the fillet built fresh"
h3r_has "$H3R_F" "kept as they were: object 3 - source object 1 no longer exists" "H3R_fillet refuse: a deleted source is reported and the fillet kept"
h3r_eq "$H3R_F" 8 6 0.02 "H3R_fillet refuse: the old fillet keeps its shape"
h3r_has "$H3R_F" "ChamferSrf: built between object 1 and 2, radius 1" "H3R_chamfer: ChamferSrf Trim=No builds the ruled chamfer"
h3r_sa "$H3R_F" 8 14.14 0.1 "H3R_chamfer: its area (sqrt(2) x 10 = 14.14)"
h3r_sb "$H3R_F" 10 "2,0,0,3,10,1" 0.05 "H3R_chamfer: wall moved +2 X: the chamfer followed"
h3r_eq "$H3R_F" 11 10 0.02 "H3R_chamfer: equals the chamfer built fresh between the moved surfaces"
h3r_has "$H3R_F" "FilletSrf: no history recorded - Trim=Yes cuts the two source surfaces" "H3R_fillet negative control: Trim=Yes is not recorded, and says why"
h3r_count "$H3R_F" "object 3: FilletSrf <- " 4 "H3R_fillet negative control: Trim=Yes added no record (the History after it lists none)"

