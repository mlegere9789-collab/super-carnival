#!/bin/bash
W=$1; shift
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
mount --bind "$W" /home/user/miniature-pancake || exit 90
mount --bind $S/sat_kbuild /home/user/miniature-pancake/dino8-kernel/build || exit 91
cd /home/user/miniature-pancake/dino8-kernel/build || exit 92
timeout 1500 ninja "$@" > $S/sat_ninja.log 2>&1
echo NINJA_EXIT=$?
