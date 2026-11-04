#!/bin/bash
# usage: sab_runk.sh <filter> <logname>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
ulimit -v 8000000
cd $S/sab_kbuild/tests
export DINO8_TEST_FILTER="$1"
start=$(date +%s.%N)
timeout 1200 ./dino8_kernel_tests > $S/$2 2>&1
echo "exit $? elapsed $(echo "$(date +%s.%N) - $start" | bc) s"
