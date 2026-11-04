
# ---------------------------------------------------------------------------
# SPS_: Sweep1 per-axis (non-uniform) scale - the ScaleX / ScaleY options (sps_scale_script.txt, sps_history_script.txt).
# "ScaleX=a,b" scales the section along its X axis (world X seen in the section plane at the rail start) by a at the rail
# start and b at the rail end, linear in the rail's arc length; ScaleY likewise along the perpendicular. Single section:
# the kernel's Brep::Sweep1 (scale_x_schedule / scale_y_schedule); several sections: Brep::Sweep1Sections with the same.
# Everything is MEASURED from the app's own output and compared with a closed form: ClosestPt distances of points ON the
# scaled ellipses (and of the swapped-axes point, which must be far), BoundingBox, the kernel's exact volume of the capped
# solid (elliptic frustum 10 pi 13/12, elliptic cylinder, torus 2 pi^2 R r^2 sx sy), and the rebuilt-by-History wall against
# the same sweep built fresh. Negative controls: a plain Sweep1 (no option) is the unchanged cylinder; zero, negative and
# non-numeric scales, a ramp on a closed rail and a section away from the rail start are refused with their reason and
# build NOTHING (never a silently unscaled sweep). Output checks use here-strings (no echo | grep).
# ---------------------------------------------------------------------------
sps_ok() { echo "ok   $1"; }
sps_bad() { echo "FAIL $1"; fail=1; }
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SPS_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/sps_scale_script.txt" 2>&1)" || { echo "$SPS_OUT" | tail -40; echo "FAIL SPS_run: scale script exited non-zero"; fail=1; SPS_OUT=""; }
  SPS_H="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/sps_history_script.txt" 2>&1)" || { echo "$SPS_H" | tail -40; echo "FAIL SPS_run: history script exited non-zero"; fail=1; SPS_H=""; }
else
  SPS_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/sps_scale_script.txt" 2>&1)" || { echo "$SPS_OUT" | tail -40; echo "FAIL SPS_run: scale script exited non-zero"; fail=1; SPS_OUT=""; }
  SPS_H="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/sps_history_script.txt" 2>&1)" || { echo "$SPS_H" | tail -40; echo "FAIL SPS_run: history script exited non-zero"; fail=1; SPS_H=""; }
fi
if grep -q "^FAIL" <<<"$SPS_OUT$SPS_H"; then sps_bad "SPS_script: an @expect line of a script failed"; else sps_ok "SPS_script: every @expect_objects line of both scripts held"; fi
# The output of the n-th Sweep1 command of the scale script (up to the next one).
sps_case() { awk -v n="$1" '/Command: Sweep1$/ { c++ } c == n' <<<"$SPS_OUT"; }
sps_in() { awk -v v="${1:-}" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }'; }
sps_has() { if grep -qF -- "$2" <<<"$1"; then sps_ok "$3"; else sps_bad "$3"; near "$1" "$2"; fi; }
sps_hasnot() { if grep -qF -- "$2" <<<"$1"; then sps_bad "$3"; near "$1" "$2"; else sps_ok "$3"; fi; }
# the number after "exact volume " in [$2, $3]
sps_exactvol() {
  local v
  v="$({ grep -o "exact volume [0-9.e+-]*" <<<"$1" || true; } | head -1 | awk '{print $3}')"
  if sps_in "$v" "$2" "$3"; then sps_ok "$4 (kernel exact volume $v in $2..$3)"; else sps_bad "$4 (exact volume '$v' not in $2..$3)"; fi
}
# the first Bounding box line of $1 inside "x0lo x0hi y0lo y0hi z0lo z0hi x1lo x1hi y1lo y1hi z1lo z1hi" ($2)
sps_bbox() {
  local line
  line="$({ grep -o "Bounding box min [^ ]* max [^ ]*" <<<"$1" || true; } | head -1)"
  if [ -n "$line" ] && awk -v r="$2" '{ split($4, a, ","); split($6, b, ","); split(r, q, " ");
        ok = (a[1] >= q[1] && a[1] <= q[2] && a[2] >= q[3] && a[2] <= q[4] && a[3] >= q[5] && a[3] <= q[6] &&
              b[1] >= q[7] && b[1] <= q[8] && b[2] >= q[9] && b[2] <= q[10] && b[3] >= q[11] && b[3] <= q[12]); exit !ok }' <<<"$line"; then
    sps_ok "$3 ($line)"
  else
    sps_bad "$3 (box '$line' outside $2)"
  fi
}
SPS_1="$(sps_case 1)"; SPS_2="$(sps_case 2)"; SPS_3="$(sps_case 3)"; SPS_4="$(sps_case 4)"; SPS_5="$(sps_case 5)"; SPS_6="$(sps_case 6)"
SPS_7="$(sps_case 7)"; SPS_8="$(sps_case 8)"; SPS_9="$(sps_case 9)"; SPS_10="$(sps_case 10)"; SPS_11="$(sps_case 11)"
# 1: elliptic frustum, semi-axes (1 + f, 1 - f/2) at z = 10 f
sps_has "$SPS_1" "Sweep1: ScaleX = 1,2 (scale along the section's X axis at the rail start, at the rail end)" "SPS_1: the ScaleX option is accepted and echoed"
sps_has "$SPS_1" "Sweep1: exact kernel sweep with a per-axis scale along the rail (x 1,2, y 1,0.5; x axis = world X in the section plane at the rail start, y perpendicular to it)" "SPS_1: the exact kernel sweep reports the per-axis scale"
SPS_1D="$({ grep -o "Closest point [^ ]* distance [0-9.e+-]*" <<<"$SPS_1" || true; } | awk '{print $NF}')"
SPS_1N="$(grep -c . <<<"$SPS_1D" || true)"
if [ "$SPS_1N" = "6" ] && awk 'NR <= 5 { if ($1 + 0 >= 1e-6) bad = 1 } NR == 6 { if ($1 + 0 < 0.3) bad = 1 } END { exit bad }' <<<"$SPS_1D"; then
  sps_ok "SPS_1_ellipses: 5 points ON the scaled ellipses (x = 1.5 / y = 0.75 at z = 5, x = 2 / y = 0.5 at z = 10, x = -1 at z = 0) are within 1e-6 of the surface and the swapped-axes point (0, 1.5, 5) is far; got: $(echo $SPS_1D)"
else
  sps_bad "SPS_1_ellipses: expected 5 distances below 1e-6 then one above 0.3, got $SPS_1N: $(echo $SPS_1D)"
fi
sps_bbox "$SPS_1" "-2.05 -1.9 -1.05 -0.9 -0.01 0.01 1.9 2.05 0.9 1.05 9.99 10.01" "SPS_1_bbox: box is x +-2 (end ellipse), y +-1 (start circle), z = 0..10"
# 2: capped, volume pi * 10 * integral (1 + f)(1 - f/2) df = 10 pi 13/12 = 34.0339
sps_exactvol "$SPS_2" 34.030 34.038 "SPS_2: capped elliptic frustum volume 10 pi 13/12 = 34.0339"
# 3: X only
sps_exactvol "$SPS_3" 62.82 62.846 "SPS_3: ScaleX=2,2 alone gives the elliptic cylinder pi * 2 * 1 * 10 = 62.8319"
sps_bbox "$SPS_3" "-2.05 -1.9 -1.05 -0.9 -0.01 0.01 1.9 2.05 0.9 1.05 9.99 10.01" "SPS_3_bbox: box is x +-2, y +-1 (Y untouched)"
# 4: control
sps_exactvol "$SPS_4" 31.41 31.422 "SPS_4_control: no scale option leaves the plain cylinder pi * 1^2 * 10 = 31.4159"
sps_hasnot "$SPS_4" "per-axis" "SPS_4_control: ...and mentions no per-axis scale"
# 5: three sections
sps_has "$SPS_5" "Sweep1: exact kernel multi-section sweep (3 sections, " "SPS_5: three circles reach the kernel's Brep::Sweep1Sections"
sps_has "$SPS_5" "Sweep1: per-axis scale applied to the blended sections (x 1,2, y 1,0.5)" "SPS_5: ...with the per-axis scale"
sps_exactvol "$SPS_5" 34.020 34.048 "SPS_5: three-section capped solid volume 10 pi 13/12 = 34.0339 (skin through the stations)"
# 6: closed rail
sps_exactvol "$SPS_6" 236.78 236.96 "SPS_6: closed circle rail R = 10, ScaleX=1.5,1.5 ScaleY=0.8,0.8: volume 2 pi^2 R r^2 * 1.5 * 0.8 = 236.870"
sps_has "$SPS_6" "Sweep1: exact kernel sweep with a per-axis scale along the rail (x 1.5,1.5, y 0.8,0.8" "SPS_6: the closed rail takes the kernel's per-axis path (not the revolve)"
# 7..11: refusals
sps_has "$SPS_7" "must return to its starting value at t = 1" "SPS_7: a one-way ramp on a closed rail is refused with the kernel's reason"
sps_has "$SPS_7" "Sweep1: no surface created" "SPS_7: ...and nothing is built (no unscaled fallback)"
sps_has "$SPS_8" "the section sits 50.0% along the rail; a scaled sweep needs the section at the rail start" "SPS_8: a section away from the rail start is refused with that reason"
sps_has "$SPS_8" "Sweep1: no surface created" "SPS_8: ...and nothing is built"
sps_has "$SPS_9" "Sweep1: no surface created - ScaleX must be 'start,end' - two positive numbers (or one), got '0,2'" "SPS_9: ScaleX=0,2 is refused"
sps_has "$SPS_10" "Sweep1: no surface created - ScaleX must be 'start,end' - two positive numbers (or one), got '-1,2'" "SPS_10: ScaleX=-1,2 is refused"
sps_has "$SPS_11" "Sweep1: no surface created - ScaleY must be 'start,end' - two positive numbers (or one), got 'abc'" "SPS_11: ScaleY=abc is refused"
# History: the recorded scale rebuilds the scaled wall
SPS_BOXES="$({ grep -o "Bounding box min [^ ]* max [^ ]*" <<<"$SPS_H" || true; })"
SPS_AREAS="$({ grep -o "Area = [0-9.e+-]*" <<<"$SPS_H" || true; } | awk '{print $3}')"
sps_box() { sed -n "${1}p" <<<"$SPS_BOXES"; }
sps_has "$SPS_H" "Sweep1 <- 1,2" "SPS_H: History lists the scaled Sweep1 as built from the rail and the section"
if [ "$(grep -c . <<<"$SPS_BOXES" || true)" = "4" ]; then sps_ok "SPS_H: four bounding boxes measured"; else sps_bad "SPS_H: expected 4 bounding boxes, got: $SPS_BOXES"; fi
if awk -v a="$(sps_box 1)" 'BEGIN { split(a, t, " "); split(t[4], lo, ","); split(t[6], hi, ","); exit !(lo[1] > -2.05 && lo[1] < -1.9 && hi[1] > 1.9 && hi[1] < 2.05 && lo[2] > -1.05 && lo[2] < -0.9 && hi[2] > 0.9 && hi[2] < 1.05) }'; then
  sps_ok "SPS_H_1: the fresh scaled wall spans x +-2 and y +-1"
else
  sps_bad "SPS_H_1: box '$(sps_box 1)'"
fi
if awk -v a="$(sps_box 2)" 'BEGIN { split(a, t, " "); split(t[4], lo, ","); split(t[6], hi, ","); exit !(lo[1] > -2.05 && lo[1] < -1.9 && hi[1] > 1.9 && hi[1] < 2.05 && lo[2] > -0.05 && lo[2] < 0.1 && hi[2] > 1.9 && hi[2] < 2.05) }'; then
  sps_ok "SPS_H_2: moving the section +1 in Y rebuilt the wall with the scale kept (x +-2, y 0..2)"
else
  sps_bad "SPS_H_2: box '$(sps_box 2)'"
fi
if awk -v a="$(sps_box 2)" -v b="$(sps_box 3)" 'BEGIN { split(a, p, " "); split(b, q, " "); n = split(p[4] "," p[6], x, ","); split(q[4] "," q[6], y, ",");
     for (i = 1; i <= 6; i++) { d = x[i] - y[i]; if (d < 0) d = -d; if (d > 0.01) bad = 1 } exit bad }'; then
  sps_ok "SPS_H_3: the History-rebuilt wall's box equals the same sweep built fresh from the moved section to 0.01 on all six numbers"
else
  sps_bad "SPS_H_3: rebuilt '$(sps_box 2)' vs fresh '$(sps_box 3)'"
fi
SPS_A1="$(sed -n 1p <<<"$SPS_AREAS")"; SPS_A2="$(sed -n 2p <<<"$SPS_AREAS")"
if [ -n "$SPS_A1" ] && [ -n "$SPS_A2" ] && awk -v a="$SPS_A1" -v b="$SPS_A2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a > 0 && d < 1e-3 * a) }'; then
  sps_ok "SPS_H_area: rebuilt area $SPS_A1 equals the fresh sweep's $SPS_A2 within 0.1 percent"
else
  sps_bad "SPS_H_area: rebuilt '$SPS_A1' vs fresh '$SPS_A2'"
fi
if [ "$(sps_box 4)" = "$(sps_box 3)" ]; then sps_ok "SPS_H_off: with History Off a section moved afterwards leaves the wall exactly where it was ($(sps_box 4))"; else sps_bad "SPS_H_off: box changed from '$(sps_box 3)' to '$(sps_box 4)'"; fi
if [ "$(sps_box 2)" != "$(sps_box 1)" ]; then sps_ok "SPS_H_sensitive: the moved wall's box differs from the original one (the comparison can fail)"; else sps_bad "SPS_H_sensitive: the box did not change when the section moved"; fi
