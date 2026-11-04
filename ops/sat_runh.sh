#!/bin/bash
# usage: sat_runh.sh <harness.sh> : runs a smoke harness against my manually linked Dino8; output to sat_runh.log
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
trap '' PIPE
bash "$1" "$S/sat_manual/Dino8" > "$S/sat_runh.log" 2>&1
echo "harness exit $?"
