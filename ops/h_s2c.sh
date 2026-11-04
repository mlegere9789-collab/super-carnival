set -euo pipefail
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE="/home/user/miniature-pancake/.claude/worktrees/agent-ab77c189bc1293fa4/dino8-app/tests"
BIN="${1:-$HERE/../build/Dino8}"
TMP="$(mktemp -d -p /tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad)"
if command -v cygpath >/dev/null 2>&1; then TMPW="$(cygpath -m "$TMP")"; else TMPW="$TMP"; fi
if command -v cygpath >/dev/null 2>&1; then HEREW="$(cygpath -m "$HERE")"; else HEREW="$HERE"; fi
export XDG_CONFIG_HOME="$TMPW/config"
mkdir -p "$XDG_CONFIG_HOME"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; *) IS_WINDOWS=0 ;; esac
if [ "$IS_WINDOWS" = 1 ]; then
  export APPDATA="$XDG_CONFIG_HOME"
  CONFIG_DIR="$APPDATA/Dino8"
else
  CONFIG_DIR="$XDG_CONFIG_HOME/dino8"
fi
:

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
near() {
  local out="$1" pat="$2" prefix
  prefix="${pat%%[0-9]*}"
  prefix="${prefix%%\\*}"
  prefix="${prefix%%[\[\]\(\)\.\*\^\$]*}"
  if [ "$prefix" == "$pat" ]; then prefix="${pat%% *}"; fi
  echo "     expected: $pat"
  if [ -n "$prefix" ] && [ "$prefix" != "$pat" ]; then
    echo "$out" | grep -F -- "$prefix" | head -16 | sed 's/^/     actual:   /' || true
  fi
}
s2c_ok() { echo "ok   $1"; }
s2c_bad() { echo "FAIL $1"; fail=1; }
S2C_CMD=(timeout 900 "$BIN" --smoke 30 --script "$HERE/sweep2_cyclic_script.txt")
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  S2C="$("${S2C_CMD[@]}" 2>&1)" || { echo "$S2C" | tail -40; echo "FAIL S2C_run: sweep2 cyclic script exited non-zero"; fail=1; S2C=""; }
else
  S2C="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/sweep2_cyclic_script.txt" 2>&1)" || { echo "$S2C" | tail -40; echo "FAIL S2C_run: sweep2 cyclic script exited non-zero"; fail=1; S2C=""; }
fi
if grep -q "^FAIL" <<<"$S2C"; then s2c_bad "S2C_script: an @expect line of the script failed"; else s2c_ok "S2C_script: every @expect_objects line of the script held"; fi
s2c_case() { awk -v n="$1" '/Command: Sweep2$/ { c++ } c == n' <<<"$S2C"; }
s2c_dists() {
  local d n
  d="$(grep -o "Closest point [^ ]* distance [0-9.e+-]*" <<<"$1" | awk '{print $NF}' || true)"
  n="$(grep -c . <<<"$d" || true)"
  if [ "$n" = "$2" ] && awk '{ if ($1 + 0 >= 1e-6) bad = 1 } END { exit bad }' <<<"$d"; then
    s2c_ok "$3 (all $2 points on the input sections are within 1e-6 of the surface; got: $(echo $d))"
  else
    s2c_bad "$3 (expected $2 distances below 1e-6, got $n: $(echo $d))"
  fi
}
s2c_acc() {
  local line
  line="$(grep -o "([0-9]* sections, [0-9]* rail stations); measured: sections reproduced to [0-9.e+-]*, wall edges within [0-9.e+-]* of the rails" <<<"$1" | head -1 || true)"
  if [ -n "$line" ] && awk -v b="$2" '{ s = $10; e = $14; exit !(s + 0 < 1e-12 && e + 0 <= b) }' <<<"$line"; then
    s2c_ok "$3 ($line)"
  else
    s2c_bad "$3 (accuracy line missing or out of bounds: '$line')"
  fi
}
s2c_bbox() {
  local line
  line="$(grep -o "Bounding box min [^ ]* max [^ ]*" <<<"$1" | head -1 || true)"
  if [ -n "$line" ] && awk -v r="$2" '{ split($4, a, ","); split($6, b, ","); split(r, q, " ");
        ok = (a[1] >= q[1] && a[1] <= q[2] && a[2] >= q[3] && a[2] <= q[4] && a[3] >= q[5] && a[3] <= q[6] &&
              b[1] >= q[7] && b[1] <= q[8] && b[2] >= q[9] && b[2] <= q[10] && b[3] >= q[11] && b[3] <= q[12]); exit !ok }' <<<"$line"; then
    s2c_ok "$3 ($line)"
  else
    s2c_bad "$3 (box '$line' outside the expected ranges $2)"
  fi
}
s2c_area() {
  local v
  v="$(grep -o "Area = [0-9.e+-]*" <<<"$1" | head -1 | awk '{print $3}' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v > lo && v < hi) }'; then s2c_ok "$4 (area $v in ($2, $3))"; else s2c_bad "$4 (area '$v' outside ($2, $3))"; fi
}
S2C_A="$(s2c_case 1)"; S2C_B="$(s2c_case 2)"; S2C_C="$(s2c_case 3)"; S2C_D="$(s2c_case 4)"; S2C_E="$(s2c_case 5)"; S2C_F="$(s2c_case 6)"; S2C_G="$(s2c_case 7)"
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_A"; then s2c_ok "S2C_A_kernel: two closed rings + 3 radial sections reach the kernel's Brep::Sweep2Sections (no fallback)"; else s2c_bad "S2C_A_kernel: closed rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_A" 1e-3 "S2C_A_accuracy: sections reproduced below 1e-12 and the wall edges within the document tolerance 0.001 of both rings"
s2c_area "$S2C_A" 121.0 123.6 "S2C_A_area: flat annulus area pi (8^2 - 5^2) = 122.52 to the display mesh's tessellation"
s2c_bbox "$S2C_A" "-8.05 -7.8 -8.05 -7.8 -0.01 0.01 7.8 8.05 7.8 8.05 -0.01 0.01" "S2C_A_bbox: box is the r = 8 ring's extent and z = 0"
s2c_dists "$S2C_A" 5 "S2C_A_passthrough"
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_B"; then s2c_ok "S2C_B_kernel: three different arched sections between closed rings reach the kernel"; else s2c_bad "S2C_B_kernel: arched sections on closed rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_B" 1e-3 "S2C_B_accuracy: sections reproduced below 1e-12, wall edges within the document tolerance of both rings"
s2c_bbox "$S2C_B" "-8.05 -7.8 -8.05 -7.8 -0.01 0.01 7.8 8.05 7.8 8.05 1.9 2.2" "S2C_B_bbox: ring extent in x/y and a tallest arch of about 2 (the 4-control-height section's 4 / 2)"
s2c_dists "$S2C_B" 3 "S2C_B_passthrough"
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_C"; then s2c_ok "S2C_C_kernel: two rails meeting at both ends reach the kernel (no fallback)"; else s2c_bad "S2C_C_kernel: touching rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_C" 1e-3 "S2C_C_accuracy: sections reproduced below 1e-12, wall edges within the document tolerance of the rails"
s2c_area "$S2C_C" 26.2 27.1 "S2C_C_area: flat lens area 2 int y dx = 26.667 to the display mesh's tessellation"
s2c_bbox "$S2C_C" "-0.01 0.01 -2.05 -1.95 -0.01 0.01 9.99 10.01 1.95 2.05 -0.01 0.01" "S2C_C_bbox: box is x 0..10 (the rails' meeting points), y +-2 (the rails' bulge), z = 0"
s2c_dists "$S2C_C" 3 "S2C_C_passthrough"
if grep -q "Sweep2: exact kernel multi-section sweep (3 sections, " <<<"$S2C_D"; then s2c_ok "S2C_D_kernel: arched sections between touching rails reach the kernel"; else s2c_bad "S2C_D_kernel: arched sections on touching rails did not reach Brep::Sweep2Sections"; fi
s2c_acc "$S2C_D" 1e-3 "S2C_D_accuracy: sections reproduced below 1e-12, wall edges within the document tolerance of the rails"
s2c_bbox "$S2C_D" "-0.01 0.01 -2.05 -1.95 -0.01 0.01 9.99 10.01 1.95 2.05 1.4 1.6" "S2C_D_bbox: x 0..10, y +-2 and the middle section's arch height 3 / 2 = 1.5"
s2c_dists "$S2C_D" 3 "S2C_D_passthrough"
if grep -q "Sweep2: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep2Sections: the sections are not ordered consistently along the two rails (their anchors cross)); using the scaled-frame fit" <<<"$S2C_E" && grep -q "Sweep2: 3 section(s) along " <<<"$S2C_E"; then s2c_ok "S2C_E_refusal: crossing anchors round closed rails are refused with that reason and the old fit builds"; else s2c_bad "S2C_E_refusal: refusal text or fallback line missing"; fi
if grep -q "Sweep2: exact kernel multi-section sweep (2 sections, 256 rail stations)" <<<"$S2C_F"; then s2c_ok "S2C_F_kernel: the straight-run-into-a-bend rails reach the kernel after the ladder 32, 64, 128 missed the tolerance (256 stations)"; else s2c_bad "S2C_F_kernel: expected the exact sweep at 256 stations"; fi
s2c_acc "$S2C_F" 1e-3 "S2C_F_accuracy: sections reproduced below 1e-12 and the wall edges within the document tolerance 0.001 of the rails at 256 stations"
s2c_bbox "$S2C_F" "-0.01 0.01 -0.01 0.01 -0.01 0.01 103.9 104.1 3.9 4.1 3.9 4.1" "S2C_F_bbox: box is the rails' extent x 0..104, y 0..4, z 0..4"
s2c_dists "$S2C_F" 2 "S2C_F_passthrough"
if grep -q "Sweep2: the exact multi-section sweep was not used (the wall edges are [0-9.e-]* from the rails at 512 stations (tolerance 0.001)); using the scaled-frame fit" <<<"$S2C_G" && grep -q "Sweep2: 2 section(s) along " <<<"$S2C_G"; then s2c_ok "S2C_G_miss: a tangent jump in the rails is a reported miss at 512 stations (not an exact sweep) and the old fit builds"; else s2c_bad "S2C_G_miss: miss reason or fallback line missing"; fi
S2C_N="$(grep -c "exact kernel multi-section sweep" <<<"$S2C" || true)"
if [ "$S2C_N" = "5" ]; then s2c_ok "S2C_count: exactly the five well-formed sweeps reached the kernel"; else s2c_bad "S2C_count: $S2C_N multi-section sweeps reached the kernel, expected 5"; fi

exit $fail
