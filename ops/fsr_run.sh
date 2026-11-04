#!/bin/bash
# usage: fsr_run.sh <script file> <out file>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
timeout 600 xvfb-run -a -s "-screen 0 1600x900x24" "$S/fsr_build/Dino8" --smoke 60 --script "$1" > "$2" 2>&1
echo "exit $?"
