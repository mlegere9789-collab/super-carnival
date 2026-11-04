#!/bin/bash
# usage: fsr_mkharness.sh <kind: fsr|reg>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a102f7e751a3e860d/dino8-app/tests
SM=$T/smoke.sh
OUT=$S/fsr_harness_$1.sh
{
  head -128 "$SM" | sed "s|^HERE=.*|HERE=\"$T\"|"
  case "$1" in
    fsr)
      sed -n '6432,6443p' "$SM"
      L=$(grep -n '^# FSR_: ' "$SM" | cut -d: -f1)
      sed -n "$((L-1)),\$p" "$SM" | grep -v '^exit \$fail$'
      ;;
    reg)
      sed -n '1278,1347p' "$SM"
      sed -n '8690,8883p' "$SM"
      sed -n '10501,10521p' "$SM"
      sed -n '10755,10898p' "$SM"
      ;;
  esac
  echo 'exit $fail'
} > "$OUT"
echo "$OUT $(wc -l < "$OUT") lines"
