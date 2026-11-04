#!/bin/bash
# usage: h3_run.sh <script basename without _script.txt>   -> prints filtered output, full output in h3/<name>.out
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a6793fdf3e148e078/dino8-app/tests
mkdir -p $S/h3
sed "s|@TMP@|$S/h3|g" $T/$1_script.txt > $S/h3/$1_script.txt
timeout 600 xvfb-run -a -s "-screen 0 1600x900x24" $S/history3_build/Dino8 --smoke 30 --script $S/h3/$1_script.txt > $S/h3/$1.out 2>&1
echo rc=$?
grep -E "${2:-Sweep|Bounding box|Area =|Volume =|history|History|UpdateHistory|kept|FAIL|rror|Patch|Fillet|Chamfer}" $S/h3/$1.out | cut -c1-300
