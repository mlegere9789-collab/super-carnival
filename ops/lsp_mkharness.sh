#!/bin/bash
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a3d1d6e7e4e138db2/dino8-app/tests
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
START=$(grep -n '^# LSP_ : AutoLISP' $WT/smoke.sh | head -1 | cut -d: -f1)
START=$((START-1))
{ head -128 $WT/smoke.sh | sed "s|^HERE=.*|HERE=$WT|"; sed -n "${START},\$p" $WT/smoke.sh; } > $S/lsp_harness.sh
