#!/bin/bash
set -eu
W=/home/user/miniature-pancake/.claude/worktrees/agent-a870407c233f334f5
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
H=$S/reg_harness.sh
{
  sed -n 1,128p $W/dino8-app/tests/smoke.sh | sed "s|^HERE=.*|HERE=$W/dino8-app/tests|"
  L=$(grep -n '^# ---- MKR_' $W/dino8-app/tests/smoke.sh | head -1 | cut -d: -f1)
  sed -n "${L},\$p" $W/dino8-app/tests/smoke.sh
} > $H
grep -n '^HERE=' $H
tail -2 $H
