#!/bin/bash
# usage: sat_runk.sh <filter> : runs the kernel tests with a memory cap, output to sat_runk.log
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
ulimit -v 6000000
cd $S/sat_kbuild/tests
DINO8_TEST_FILTER="$1" timeout 300 ./dino8_kernel_tests > $S/sat_runk.log 2>&1
echo "exit $?"
