#!/bin/bash
# usage: frh_regress.sh <binary> <out dir>   runs the existing fillet/solid sections of smoke.sh against <binary>
T=/home/user/miniature-pancake/.claude/worktrees/agent-adc31822bebdb17e9/dino8-app/tests
BIN="$1"; OUT="$2"
mkdir -p "$OUT"
run() {
  name="$1"; a="$2"; b="$3"
  {
    sed -n '1,128p' "$T/smoke.sh" | sed "s|^HERE=.*|HERE=$T|"
    sed -n "${a},${b}p" "$T/smoke.sh"
    echo 'exit $fail'
  } > "$OUT/h_$name.sh"
  bash "$OUT/h_$name.sh" "$BIN" > "$OUT/$name.log" 2>&1
  echo "$name exit=$? ok=$(grep -c '^ok ' "$OUT/$name.log") FAIL=$(grep -c '^FAIL' "$OUT/$name.log")" >> "$OUT/summary.txt"
}
: > "$OUT/summary.txt"
run FL 2232 2397
run SX 8937 9050
run SR 9920 10394
run B2S 10396 10619
run SO2 10621 10888
echo DONE >> "$OUT/summary.txt"
