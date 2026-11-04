#!/bin/bash
# usage: h4r_exec.sh <name>   runs dino8-app/tests/h4r_<name>_script.txt (with @TMP@ replaced) and writes h4r_<name>.out
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a92541384807f36f6
N="$1"
mkdir -p "$S/h4r_tmp"
sed "s|@TMP@|$S/h4r_tmp|g" "$WT/dino8-app/tests/h4r_${N}_script.txt" > "$S/h4r_tmp/h4r_${N}_script.txt"
timeout 600 xvfb-run -a -s "-screen 0 1600x900x24" bash "$S/h4r_run.sh" "$S/appbuild/Dino8" --smoke 100 --script "$S/h4r_tmp/h4r_${N}_script.txt" > "$S/h4r_${N}.out" 2>&1
echo "exit $?"
