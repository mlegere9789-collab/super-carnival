#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
$S/gate.sh run bash -c "trap '' PIPE; exec bash $S/reg_harness.sh $S/reg_build/Dino8" > $S/reg_smoke.out 2>&1
echo "rc=$?" >> $S/reg_smoke.out
