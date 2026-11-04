#!/bin/bash
# usage: xt_build.sh <worktree> <ninja target...>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT="$1"; shift
mount --bind "$WT" /home/user/miniature-pancake || exit 90
mkdir -p /home/user/miniature-pancake/dino8-kernel/build
mount --bind $S/xt_kbuild /home/user/miniature-pancake/dino8-kernel/build || exit 92
cd /home/user/miniature-pancake/dino8-kernel/build || exit 91
if [ "$XT_CMAKE" = "1" ]; then cmake . > $S/xt_cmake.log 2>&1; tail -2 $S/xt_cmake.log; fi
ninja "$@" 2>&1 | tee $S/xt_ninja.log | grep -E 'error|FAILED' -A4 | head -${XT_LINES:-80}
echo "NINJA_DONE ${PIPESTATUS[0]}"
