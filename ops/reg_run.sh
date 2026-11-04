#!/bin/bash
trap "" PIPE
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
exec bash "$S/reg_harness.sh" "$S/bin2/Dino8" > "$S/reg_run.log" 2>&1
