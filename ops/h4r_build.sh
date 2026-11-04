#!/bin/bash
# usage: h4r_build.sh <ninja args...>
# Same idea as agent_build.sh (private mount namespace, worktree bound at the main checkout path, build dir at the
# shared build's own path) but the build directory is an overlayfs whose lower layer is the shared build (read-only,
# never written) and whose upper layer is private to this agent, because the volume has too little free space for a
# full copy. Every write lands in $U; the shared build is untouched.
set -euo pipefail
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a92541384807f36f6
U=$S/h4r_upper
W=$S/h4r_work
mkdir -p "$U" "$W"
exec unshare -m bash -c "mount --bind '$WT' /home/user/miniature-pancake && mount -t overlay overlay -o lowerdir='$S/appbuild',upperdir='$U',workdir='$W' '$S/appbuild' && cd '$S/appbuild' && exec ninja $*"
