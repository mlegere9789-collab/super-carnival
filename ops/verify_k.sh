#!/bin/bash
# usage: verify_k.sh <logname>  - rebuild kernel tests (abort if build fails), run full suite
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
cd /home/user/miniature-pancake/dino8-kernel/build || exit 9
ninja -j3 dino8_kernel_tests > $S/$1.build 2>&1 || { echo "BUILD_FAILED" > $S/$1.log; echo "KFULL_EXIT=99" >> $S/$1.log; exit 99; }
./tests/dino8_kernel_tests > $S/$1.log 2>&1
echo "KFULL_EXIT=$?" >> $S/$1.log
