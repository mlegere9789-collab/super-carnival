#!/bin/bash
# usage: csk_run.sh <script file> <out file>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
export XDG_CONFIG_HOME="$(mktemp -d)"
timeout 900 $S/gate.sh run xvfb-run -a -s "-screen 0 1600x900x24" $S/csk_build/Dino8 --smoke 60 --script "$1" > "$2" 2>&1
echo "rc=$?"
