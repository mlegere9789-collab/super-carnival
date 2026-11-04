#!/bin/bash
# usage: h4r_harness_run.sh <harness file> <out file>: runs a smoke harness against the overlay-built Dino8
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
trap '' PIPE
bash "$S/h4r_run.sh" bash -c "trap '' PIPE; exec bash $1 $S/appbuild/Dino8" > "$2" 2>&1
echo "exit $?"
