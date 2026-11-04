#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-ab6dd2aa413bb4a90/dino8-app/tests
head -128 $T/smoke.sh | sed "s|^HERE=.*|HERE=$T|" > $S/mkr_harness.sh
sed -n '/^# ---- MKR_/,$p' $T/smoke.sh >> $S/mkr_harness.sh
sed -i "s#^    mkr_run \"\$MKR_DIR/run4.txt\"#    mkr_run \"\$MKR_DIR/run4.txt\"; cp \"\$MKR_DIR/run1.out\" $S/run1.out#" $S/mkr_harness.sh
exec $S/gate.sh run bash -c "trap '' PIPE; exec bash $S/mkr_harness.sh $S/reg_build/Dino8"
