# ---------------------------------------------------------------------------
# History / associative re-execution, round 4 (H4R_): ExtrudeSrfAlongCrv, ExtrudeSrfTapered,
# ExtrudeSrfToPoint, Contour, Section and OffsetMultiple record construction history
# (tests/h4r_ext_script.txt), and construction history survives Save / New / Open for a
# chain of every kind that has its own smoke script (tests/h4r_persist_script.txt).
# Part 1: with History On each result is recorded with the object it was swept or cut
# from; moving or scaling the source, or EditHistory on the numbers, rebuilds it with no
# UpdateHistory. Every rebuilt number is compared with the SAME operation performed fresh
# (History Off) on the edited source. Contour/Section record one result per piece and
# refuse (keeping the old curve) when the edited source meets the plane in a different
# number of pieces; a tessellated sphere's section chain can split at some planes (the
# fresh Contour command does too), so the sphere case only asserts that the sources were
# noticed and the four curves are still there.
# Part 2: one chain of each of 14 kinds (Sweep1 with two sections, non-planar Patch,
# FilletSrf, PlanarSrf -> ExtrudeSrf, Pipe, Loft, Revolve, Extrude, BooleanUnion, Offset,
# ExtrudeCrvTapered, NetworkSrf, OffsetSrf, ExtrudeCrvToPoint) is built, saved, the document
# is replaced by New and then Open, and only the SOURCES of each chain are moved +2 in Y:
# the result's bounding box must be its saved one shifted by (0,2,0). Revolve is the one
# kind whose axis is an independent pick that does not move with the profile (and
# ExtrudeCrvToPoint keeps its absolute apex), so Revolve is compared with a fresh revolve
# of the moved profile instead.
# Tolerances: tessellation-derived values (volume, length) are compared with ranges, as the
# Windows CI tessellates slightly differently.
# ---------------------------------------------------------------------------
H4R_DIR="$TMPW/h4r"
mkdir -p "$H4R_DIR"
h4r_run() {  # h4r_run <script name without _script.txt>: one app launch, output on stdout
  sed "s|@TMP@|$H4R_DIR|g" "$HERE/h4r_$1_script.txt" > "$H4R_DIR/h4r_$1_script.txt"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$H4R_DIR/h4r_$1_script.txt" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$H4R_DIR/h4r_$1_script.txt" 2>&1
  fi
}
h4r_len() { { grep -oE 'Total length = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Total length = //'; }
h4r_sl() { h2r_ok "$(h2r_closev "$(h4r_len "$1" "$2")" "$3" "$4")" "$5 (measured $(h4r_len "$1" "$2"), expected $3 +/- $4)"; }
# two measurements of the same kind agree: h4r_eqbb OUT i j tol label / h4r_eqlen OUT i j tol label / h4r_eqvol OUT i j tol label
h4r_eqbb() { h2r_ok "$(h2r_closebb "$(h2r_bb "$1" "$2")" "$(h2r_bb "$1" "$3")" "$4")" "$5 (rebuilt $(h2r_bb "$1" "$2") vs fresh $(h2r_bb "$1" "$3"))"; }
h4r_eqlen() { h2r_ok "$(h2r_closev "$(h4r_len "$1" "$2")" "$(h4r_len "$1" "$3")" "$4")" "$5 (rebuilt $(h4r_len "$1" "$2") vs fresh $(h4r_len "$1" "$3"))"; }
h4r_eqvol() { h2r_ok "$(h2r_closev "$(h2r_vol "$1" "$2")" "$(h2r_vol "$1" "$3")" "$4")" "$5 (rebuilt $(h2r_vol "$1" "$2") vs fresh $(h2r_vol "$1" "$3"))"; }
# bounding box i equals bounding box j shifted by (0,2,0)
h4r_shift2() {
  local a b; a="$(h2r_bb "$1" "$2")"; b="$(h2r_bb "$1" "$3")"
  h2r_ok "$(awk -v a="$a" -v b="$b" -v t="$4" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){ e=x[i]+((i==2||i==5)?2:0)-y[i]; if(e<0)e=-e; if(e>t){print 0; exit} } print 1 }')" "$5 (saved $a, after the sources moved +2 Y $b)"
}

# --- part 1: ExtrudeSrf* family, Contour, Section, OffsetMultiple
H4R_E="$(h4r_run ext)" || { echo "$H4R_E"; echo "FAIL: h4r ext script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_E" || { echo "$H4R_E"; echo "FAIL: h4r ext script produced no smoke line"; fail=1; }
h2r_has "$H4R_E" "object 9: ExtrudeSrfAlongCrv <- 1,2" "H4R_ext: ExtrudeSrfAlongCrv records the surface and the path curve"
h2r_has "$H4R_E" "object 10: ExtrudeSrfTapered <- 3  [distance=5, draft=5]" "H4R_ext: ExtrudeSrfTapered records the surface, the distance and the draft"
h2r_has "$H4R_E" "object 11: ExtrudeSrfToPoint <- 4  [apexx=45, apexy=5, apexz=10]" "H4R_ext: ExtrudeSrfToPoint records the surface and the apex"
h2r_has "$H4R_E" "object 12: Contour <- 5" "H4R_ext: every Contour piece records the contoured object"
h2r_has "$H4R_E" "object 15: Contour <- 5" "H4R_ext: ...all four pieces"
h2r_has "$H4R_E" "object 16: Section <- 6" "H4R_ext: Section records the sectioned object"
h2r_has "$H4R_E" "object 17: OffsetMultiple <- 7  [distance=2]" "H4R_ext: OffsetMultiple records the curve and the distance (one record per offset)"
h2r_count "$H4R_E" "14 object(s) with live construction history" 2 "H4R_ext: 14 recorded results before the edits and again after Open; the History Off controls added none"
# initial results
h2r_sb "$H4R_E" 1 "0,0,0,10,10,5" 0.05 "H4R_ext: ExtrudeSrfAlongCrv of a 10x10 plane along a 5 line (before)"
h2r_sh "$H4R_E" 1 500 1 "H4R_ext: ...volume 10*10*5 (before)"
h2r_sb "$H4R_E" 2 "20,0,0,30,10,5" 0.05 "H4R_ext: ExtrudeSrfTapered distance 5 draft 5 (before)"
h2r_sh "$H4R_E" 2 469.7 1.5 "H4R_ext: ...volume of the 5 degree taper (before)"
h2r_sb "$H4R_E" 3 "40,0,0,50,10,10" 0.05 "H4R_ext: ExtrudeSrfToPoint apex 10 above (before)"
h2r_sh "$H4R_E" 3 333.3 1 "H4R_ext: ...pyramid volume 100*10/3 (before)"
h4r_sl "$H4R_E" 1 159.9 1 "H4R_ext: Contour of a 10^3 box, 4 planes: total loop length 4*40 (before)"
h2r_sb "$H4R_E" 4 "60,0,1.25,70,10,8.75" 0.05 "H4R_ext: ...planes at z 1.25 .. 8.75 (before)"
h4r_sl "$H4R_E" 2 40 0.3 "H4R_ext: Section through the box at y=5: one 10x10 loop (before)"
h2r_sb "$H4R_E" 5 "80,5,0,90,5,10" 0.05 "H4R_ext: ...section bounding box (before)"
h4r_sl "$H4R_E" 3 20.88 0.6 "H4R_ext: OffsetMultiple 2 offsets x 2 of a curve (before)"
h2r_sb "$H4R_E" 6 "97.78,1.664,0,108.8,6.2,0" 0.15 "H4R_ext: ...offsets bounding box (before)"
# after the edits
h2r_sb "$H4R_E" 8 "3,0,0,13,10,10" 0.05 "H4R_ext: plane moved +3 X and path scaled 2x: the extrusion followed (x 3..13, height 10)"
h2r_sh "$H4R_E" 4 1000 2 "H4R_ext: ...volume 10*10*10"
h2r_has "$H4R_E" "History: source object(s) 1 changed - 1 dependent(s) re-evaluated (9)" "H4R_ext: moving the surface re-evaluates the extrusion automatically"
h2r_has "$H4R_E" "History: source object(s) 2 changed - 1 dependent(s) re-evaluated (9)" "H4R_ext: scaling the path re-evaluates it too"
h2r_has "$H4R_E" "EditHistory: object 10 (ExtrudeSrfTapered): distance 5 -> 8." "H4R_ext: EditHistory changes the taper distance"
h2r_has "$H4R_E" "EditHistory: object 10 (ExtrudeSrfTapered): draft 5 -> 10." "H4R_ext: ...and the draft"
h2r_sb "$H4R_E" 9 "20,4,0,30,14,8" 0.05 "H4R_ext: taper after plane moved +4 Y, distance 8, draft 10"
h2r_sh "$H4R_E" 5 651 3 "H4R_ext: ...volume"
h2r_has "$H4R_E" "EditHistory: object 11 (ExtrudeSrfToPoint): apexz 10 -> 20." "H4R_ext: EditHistory moves the apex"
h2r_sb "$H4R_E" 10 "40,2,0,50,12,20" 0.05 "H4R_ext: cone after plane moved +2 Y and apex raised to z 20"
h2r_sh "$H4R_E" 6 666.7 2 "H4R_ext: ...volume 100*20/3"
h2r_has "$H4R_E" "History: source object(s) 5 changed - 4 dependent(s) re-evaluated (12,13,14,15)" "H4R_ext: moving the contoured box re-evaluates all four contour curves"
h2r_sb "$H4R_E" 11 "65,3,1.25,75,13,8.75" 0.05 "H4R_ext: contours followed the box moved (+5,+3,+1) and stayed on their fixed planes"
h4r_sl "$H4R_E" 5 159.9 1 "H4R_ext: ...total length"
h2r_has "$H4R_E" "History: source object(s) 6 changed - 1 dependent(s) re-evaluated (16)" "H4R_ext: scaling the sectioned box re-evaluates the section"
h4r_sl "$H4R_E" 6 79.94 0.6 "H4R_ext: section of the box scaled 2x: one 20x20 loop"
h2r_sb "$H4R_E" 12 "80,5,0,100,5,20" 0.05 "H4R_ext: ...section bounding box"
h2r_has "$H4R_E" "History: source object(s) 7 changed - 2 dependent(s) re-evaluated (17,18)" "H4R_ext: scaling the curve re-evaluates both offsets"
h4r_sl "$H4R_E" 7 42.09 0.7 "H4R_ext: offsets of the curve scaled 2x"
h2r_sb "$H4R_E" 13 "97.78,1.664,0,118.8,9.2,0" 0.2 "H4R_ext: ...offsets bounding box"
h2r_has "$H4R_E" "History: source object(s) 8 changed" "H4R_ext: moving the contoured sphere is noticed"
h4r_sl "$H4R_E" 8 101.9 6 "H4R_ext: the sphere's four contour curves are all still there (pieces whose count changed kept as they were)"
# controls: the same operations fresh on the edited sources
h4r_eqbb "$H4R_E" 8 15 0.05 "H4R_ext control: fresh ExtrudeSrfAlongCrv bounding box"
h4r_eqvol "$H4R_E" 4 7 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 9 16 0.05 "H4R_ext control: fresh ExtrudeSrfTapered (distance 8, draft 10) bounding box"
h4r_eqvol "$H4R_E" 5 8 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 10 17 0.05 "H4R_ext control: fresh ExtrudeSrfToPoint (apex z 20) bounding box"
h4r_eqvol "$H4R_E" 6 9 0.5 "H4R_ext control: ...volume"
h4r_eqbb "$H4R_E" 11 18 0.05 "H4R_ext control: fresh Contour of the moved box bounding box"
h4r_eqlen "$H4R_E" 5 9 0.3 "H4R_ext control: ...total length"
h4r_eqbb "$H4R_E" 12 19 0.05 "H4R_ext control: fresh Section of the scaled box bounding box"
h4r_eqlen "$H4R_E" 6 10 0.3 "H4R_ext control: ...length"
h4r_eqbb "$H4R_E" 13 20 0.1 "H4R_ext control: fresh OffsetMultiple of the scaled curve bounding box"
h4r_eqlen "$H4R_E" 7 11 0.3 "H4R_ext control: ...total length"
# negative control: the contour planes no longer meet the box
h2r_has "$H4R_E" "History: source object(s) 5 changed - 0 dependent(s) re-evaluated, 4 kept as they were" "H4R_ext: the box moved +20 Z leaves every contour plane: no rebuild, all four kept"
h2r_has "$H4R_E" "the edited source now meets the plane in 0 piece(s), it gave 1 when this result was made; kept as it was" "H4R_ext: ...with the reason"
h4r_eqbb "$H4R_E" 21 11 0.05 "H4R_ext: the kept contours did not move"
h4r_eqlen "$H4R_E" 12 5 0.01 "H4R_ext: ...nor change length"
h4r_eqbb "$H4R_E" 22 11 0.05 "H4R_ext: the box moved back: the contours are rebuilt again, equal to before"
# Save, New, Open
h2r_has "$H4R_E" "object 10: ExtrudeSrfTapered <- 3  [distance=8, draft=10]" "H4R_ext: after Save/New/Open the taper record (with the EditHistory'd numbers) is read back from the .3dm"
h2r_has "$H4R_E" "object 11: ExtrudeSrfToPoint <- 4  [apexx=45, apexy=5, apexz=20]" "H4R_ext: ...the apex record"
h2r_sb "$H4R_E" 23 "3,5,0,13,15,10" 0.05 "H4R_ext: reopened, plane moved +5 Y: the extrusion followed"
h2r_sh "$H4R_E" 10 1000 2 "H4R_ext: ...volume"
h2r_sb "$H4R_E" 24 "65,4,1.25,75,14,8.75" 0.05 "H4R_ext: reopened, box moved +1 Y: the contours followed"
h4r_sl "$H4R_E" 14 159.9 1 "H4R_ext: ...total length"
h4r_eqbb "$H4R_E" 25 6 0.1 "H4R_ext: reopened, curve scaled back to its first size: the offsets are the first ones again"
h4r_eqlen "$H4R_E" 15 3 0.1 "H4R_ext: ...length"
h4r_eqbb "$H4R_E" 26 5 0.05 "H4R_ext: reopened, box scaled back: the section is the first one again"
h4r_eqlen "$H4R_E" 16 2 0.1 "H4R_ext: ...length"
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_E" && echo 1 || echo 0)" "H4R_ext: ran without OpenGL errors"

# --- part 2: history survives Save / New / Open for 14 construction kinds
H4R_P="$(h4r_run persist)" || { echo "$H4R_P"; echo "FAIL: h4r persist script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$H4R_P" || { echo "$H4R_P"; echo "FAIL: h4r persist script produced no smoke line"; fail=1; }
h2r_count "$H4R_P" "16 object(s) with live construction history" 2 "H4R_persist: 16 recorded results before Save and again after New + Open"
for rec in "object 4: Sweep1 <- 1,2,3" "object 14: Patch <- 5,6,7,8,9,10,11,12,13" "object 17: FilletSrf <- 15,16" "object 20: ExtrudeSrf <- 19" "object 22: Pipe <- 21" "object 26: Loft <- 23,24,25" "object 28: Revolve <- 27" "object 35: BooleanUnion <- 33,34" "object 37: Offset <- 36" "object 39: ExtrudeCrvTapered <- 38" "object 42: NetworkSrf2 <- 40,41" "object 44: OffsetSrf <- 43" "object 46: ExtrudeCrvToPoint <- 45"; do
  h2r_count "$H4R_P" "$rec" 2 "H4R_persist: record '$rec' listed before Save and again after Open"
done
h2r_count "$H4R_P" "dependent(s) re-evaluated" 14 "H4R_persist: after Open each of the 14 chains' source edits re-evaluated its dependents"
h2r_countre "$H4R_P" "kept as they were:" 0 "H4R_persist: no rebuild was refused"
H4R_NAMES=(Sweep1 Patch FilletSrf "PlanarSrf+ExtrudeSrf" Pipe Loft Revolve Extrude BooleanUnion Offset ExtrudeCrvTapered NetworkSrf OffsetSrf ExtrudeCrvToPoint)
for k in $(seq 1 14); do
  nm="${H4R_NAMES[$((k - 1))]}"
  if [ "$k" = "7" ]; then
    h4r_eqbb "$H4R_P" 21 29 0.05 "H4R_persist: $nm: after Open the profile moved +2 Y: the revolve about the fixed axis equals a fresh revolve of the moved profile"
    h2r_ok "$(awk -v a="$(h2r_bb "$H4R_P" 7)" -v b="$(h2r_bb "$H4R_P" 21)" 'BEGIN{ n=split(a,x,","); split(b,y,","); for(i=1;i<=n;i++){ d=x[i]-y[i]; if(d<0)d=-d; if(d>0.1){print 1; exit} } print 0 }')" "H4R_persist: $nm: ...and it did change from the saved result (the rebuild ran)"
  else
    h4r_shift2 "$H4R_P" "$k" "$((14 + k))" 0.05 "H4R_persist: $nm: after Open the sources moved +2 Y: the rebuilt result is the saved one shifted (0,2,0)"
  fi
done
h2r_ok "$(grep -qE 'gl_error=0' <<<"$H4R_P" && echo 1 || echo 0)" "H4R_persist: ran without OpenGL errors"

