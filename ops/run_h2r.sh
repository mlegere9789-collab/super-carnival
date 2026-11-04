#!/bin/bash
# usage: run_h2r.sh <edge|cap|proj>  -> runs tests/h2r_<name>_script.txt, output in scratchpad/h2r_<name>.out
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests
n="$1"
sed "s|@TMP@|$S/h2r_tmp|g" "$T/h2r_${n}_script.txt" > "$S/h2r_${n}_run.txt"
timeout 600 xvfb-run -a -s "-screen 0 1600x900x24" "$S/history2_build/Dino8" --smoke 100 --script "$S/h2r_${n}_run.txt" > "$S/h2r_${n}.out" 2>&1
echo "rc=$? $n"
