#!/bin/bash
# usage: fsr_runharness.sh <fsr|reg>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
trap '' PIPE
exec timeout 900 bash "$S/fsr_harness_$1.sh" "$S/fsr_build/Dino8" > "$S/fsr_harness_$1.out" 2>&1
