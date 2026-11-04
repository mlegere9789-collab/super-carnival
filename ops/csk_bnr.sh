#!/bin/bash
# usage: csk_bnr.sh <out file>   build then run the csk script
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
W=/home/user/miniature-pancake/.claude/worktrees/agent-a1461cbbcbfc614b8
cd $W
timeout 2400 $S/agent_build.sh csk $W -j2 Dino8 > $S/csk_build.log 2>&1
echo "build rc=$?" > "$1"
grep -E "error|FAILED" $S/csk_build.log | head -20 >> "$1"
if grep -q "FAILED" $S/csk_build.log; then exit 1; fi
bash $S/csk_run.sh $W/dino8-app/tests/csk_script.txt $S/csk_last.out >> "$1"
echo done >> "$1"
