#!/bin/bash
# usage: hso_run.sh <harness.sh> <log>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
trap '' PIPE
exec bash "$1" "$S/hso_build/Dino8" > "$2" 2>&1
