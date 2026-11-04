#!/bin/bash
# usage: sat_ov.sh <worktree> <command...>
# Same idea as agent_build.sh but the private build directory is an overlayfs on top of the shared appbuild (lower, never
# written) with a small upper layer of my own, because the volume has no room for another full copy.
set -euo pipefail
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT="$(cd "$1" && pwd)"; shift
mkdir -p "$S/sat_app_upper" "$S/sat_app_work"
exec unshare -m bash -c "mount --bind '$WT' /home/user/miniature-pancake && mount -t overlay overlay -o lowerdir='$S/appbuild',upperdir='$S/sat_app_upper',workdir='$S/sat_app_work' '$S/appbuild' && cd '$S/appbuild' && exec $*"
