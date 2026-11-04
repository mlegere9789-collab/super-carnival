#!/bin/bash
T=/home/user/miniature-pancake/.claude/worktrees/agent-a102f7e751a3e860d/dino8-app/tests/smoke.sh
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
for r in 1278,1350 8690,8883 10501,10521 10755,10898; do
  sed -n "${r}p" "$T" > "$S/range.tmp"
  echo "range $r:"
  bash -n "$S/range.tmp" 2>&1 | head -3
  head -c 150 "$S/range.tmp" | head -1
  tail -n 2 "$S/range.tmp" | cut -c1-120
done
