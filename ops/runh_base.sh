#!/bin/bash
# usage: runh_base.sh <harness.sh> <out file>   runs the harness against the previous agent's base binary (tip before the WIP)
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
trap '' PIPE
START=$(date +%s)
bash "$1" "$S/ts4_Dino8_base" > "$2" 2>&1
echo "harness exit=$? seconds=$(( $(date +%s) - START ))" >> "$2"
