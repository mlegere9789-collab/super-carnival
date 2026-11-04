#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
W=/home/user/miniature-pancake/.claude/worktrees/agent-ab8ab49d96ff3bdb2
OUT=$S/csk2_res.txt
cd $W
timeout 2400 $S/agent_build.sh csk $W -j2 Dino8 > $S/csk2_build.log 2>&1
echo "build rc=$?" > "$OUT"
grep -E "error|FAILED" $S/csk2_build.log | head -20 >> "$OUT"
if grep -q "FAILED" $S/csk2_build.log; then exit 1; fi
bash $S/csk_run.sh $W/dino8-app/tests/csk_script.txt $S/csk2_last.out >> "$OUT"
echo done >> "$OUT"
