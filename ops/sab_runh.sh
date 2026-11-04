#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
ulimit -v 16000000
cd $S
timeout 1500 ./sab_harness.sh $S/sab_build/Dino8 > $S/sab_harness.out 2>&1
echo "exit $?"
