# ---------------------------------------------------------------------------
# TS4_: ToSubD of a torus and of right prisms (tosubd4_script.txt). A torus used
# to go through the dense grid tessellation (an 18432-face triangle cage at the
# default 0.001 tolerance); an extruded L, or a box with FilletEdge-rounded
# vertical edges, through the dense chord-tolerance path (thousands of
# triangles, usually unverified). Now the torus gets the face's own N x M quad
# grid and a right prism one quad ring per profile column plus ear-clipped flat
# caps; both are interpolated onto the exact surface and the Catmull-Clark limit
# surface is MEASURED against it (a cage is only accepted within the document
# tolerance, and a prism ladder that verifies only marginally must be confirmed
# by its finer neighbour, else the cage is refused with the reason printed and
# the dense path is used). The two-adjacent-rounded-edges box is the regression:
# a line tangent at one end and sharp at the other used to end in a sliver column
# next to the sharp corner, whose interpolating crease overshot the corner (every
# finer rung 0.13-0.24, the coarsest verified at 0.00096 by luck). Ranges rather
# than exact numbers (tessellated Volumes and deviations depend on the platform's
# float evaluation). Eight solids, in script order: torus R5 r2, torus R6 r2,
# torus R20 r1, extruded L, box with 4 rounded edges, 2 adjacent, 2 opposite and
# 1 rounded edge.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  TS4="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/tosubd4_script.txt" 2>&1)" || { echo "$TS4"; echo "FAIL: tosubd4 script exited non-zero"; exit 1; }
else
  TS4="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/tosubd4_script.txt" 2>&1)" || { echo "$TS4"; echo "FAIL: tosubd4 script exited non-zero"; exit 1; }
fi
ts4check() { if grep -q -- "$1" <<<"$TS4"; then echo "ok   $2"; else echo "FAIL $2"; near "$TS4" "$1"; fail=1; fi; }
# in range: ts4range VALUE LO HI DESC
ts4range() { if [ -n "$1" ] && awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 ($1 in [$2, $3])"; else echo "FAIL $4 ('${1:-none}' not in [$2, $3])"; fail=1; fi; }
mapfile -t TS4_TOSUBD < <(grep -F "history: ToSubD: created" <<<"$TS4" || true)
mapfile -t TS4_LIST < <(grep -E "^history:   [0-9]+ faces, [0-9]+ edges, [0-9]+ vertices, [0-9]+ creases" <<<"$TS4" || true)
mapfile -t TS4_VOL < <(grep -o "Volume = [0-9.e+-]*" <<<"$TS4" | awk '{print $3}' || true)
if [ "${#TS4_TOSUBD[@]}" -eq 8 ] && [ "${#TS4_LIST[@]}" -eq 8 ]; then
  echo "ok   tosubd4 script printed 8 ToSubD lines and 8 SubD List lines"
  ts4dev() { sed -E 's/.*worst measured deviation ([0-9.]+)\).*/\1/' <<<"${TS4_TOSUBD[$1]}"; }
  ts4faces() { sed -E 's/^history: +([0-9]+) faces, .*/\1/' <<<"${TS4_LIST[$1]}"; }
  ts4vef() { sed -E 's/^history: +([0-9]+) faces, ([0-9]+) edges, ([0-9]+) vertices.*/\3 \2 \1/' <<<"${TS4_LIST[$1]}"; }
  ts4name=("torus R=5 r=2" "torus R=6 r=2" "torus R=20 r=1" "extruded L" "box with 4 rounded edges" "box with 2 ADJACENT rounded edges (regression)" "box with 2 opposite rounded edges" "box with 1 rounded edge")
  ts4kind=(torus torus torus prism prism prism prism prism)
  ts4flo=(400 400 400 20 300 300 200 150)
  ts4fhi=(1100 1100 1100 40 1500 1500 1500 1500)
  for i in 0 1 2 3 4 5 6 7; do
    if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.0[0-9]*)" <<<"${TS4_TOSUBD[$i]}"; then
      echo "ok   ToSubD of the ${ts4name[$i]} is verified within the document tolerance"
      ts4range "$(ts4dev "$i")" 0 0.001 "...worst measured deviation of the ${ts4name[$i]}"
    else
      echo "FAIL ToSubD of the ${ts4name[$i]} is not verified: ${TS4_TOSUBD[$i]}"; fail=1
    fi
    if [ "${ts4kind[$i]}" = torus ]; then ts4want="analytic torus cage ("; else ts4want="analytic right-prism cage ("; fi
    if grep -qF -- "$ts4want" <<<"${TS4_TOSUBD[$i]}"; then
      echo "ok   ...the ${ts4name[$i]} reports its analytic cage"
    else
      echo "FAIL the ${ts4name[$i]} does not report '$ts4want': ${TS4_TOSUBD[$i]}"; fail=1
    fi
    ts4range "$(ts4faces "$i")" "${ts4flo[$i]}" "${ts4fhi[$i]}" "...cage face count of the ${ts4name[$i]} (the dense torus cage was 18432 faces)"
    read -r ts4v ts4e ts4f <<<"$(ts4vef "$i")"
    if [ "${ts4kind[$i]}" = torus ]; then ts4chi=0; else ts4chi=2; fi
    if [ "$((ts4v - ts4e + ts4f))" -eq "$ts4chi" ]; then echo "ok   ...Euler characteristic of the ${ts4name[$i]} is $ts4chi ($ts4v - $ts4e + $ts4f)"; else echo "FAIL Euler characteristic of the ${ts4name[$i]} is $((ts4v - ts4e + ts4f)), expected $ts4chi"; fail=1; fi
  done
  # The 2-adjacent-edges box now converges; its accepted deviation must sit comfortably inside the tolerance (not a lucky marginal rung).
  ts4range "$(ts4dev 5)" 0 0.0008 "...the 2-adjacent-edges deviation is comfortably inside the tolerance (before the fix the coarsest rung verified at 0.00096 and every finer one failed at 0.13-0.24)"
  ts4range "$(ts4dev 3)" 0 0.0001 "...the extruded L (straight edges only) is exact"
  # Volumes in script order: torus net x3 (cage, +1, +2 SubDivide rounds), L net x3, box Brep, box net x3, 2-adjacent Brep.
  if [ "${#TS4_VOL[@]}" -eq 11 ]; then
    ts4range "${TS4_VOL[0]}" 395 420 "torus R=5 r=2 control-net Volume (an interpolated cage's net overshoots the exact 394.78)"
    ts4range "${TS4_VOL[2]}" 393 398 "...and after two SubDivide rounds the net is back near 2 pi^2 R r^2 = 394.78"
    ts4range "${TS4_VOL[3]}" 383 385 "extruded L control-net Volume = area 64 x height 6 = 384 (a prism cage's net is exact)"
    ts4range "${TS4_VOL[6]}" 594 596 "box with 4 rounded edges: Brep Volume = 6 x (100 - 4 (1 - pi/4)) = 594.85"
    ts4range "${TS4_VOL[10]}" 588 591 "box with 2 adjacent rounded edges: Brep Volume = 6 x (100 - 2 (4 - pi)) = 589.70"
  else
    echo "FAIL tosubd4 script printed ${#TS4_VOL[@]} Volume lines (expected 11)"; fail=1
  fi
else
  echo "FAIL tosubd4 script printed ${#TS4_TOSUBD[@]} ToSubD / ${#TS4_LIST[@]} List lines (expected 8 / 8)"; fail=1
fi
ts4check "gl_error=0" "tosubd4 script ran without OpenGL errors"

