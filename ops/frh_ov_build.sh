#!/bin/bash
# usage: frh_ov_build.sh <worktree> <ninja args...>
# Same idea as agent_build.sh, but the private "copy" of the shared app build is an OVERLAY (lower = the shared build,
# read-only; upper = a small private dir) because the volume has no room for another 1.6 GB copy. Nothing is ever
# written to the shared build.
set -euo pipefail
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT="$(cd "$1" && pwd)"; shift 1
UP="$S/frh_ov_upper"; WK="$S/frh_ov_work"
mkdir -p "$UP" "$WK"
if [ ! -f "$WT/.agent_touched" ]; then
  (cd "$WT" && git ls-files -z | xargs -0 touch -d '2020-01-01' && touch .agent_touched)
fi
exec unshare -m bash -c "mount --bind '$WT' /home/user/miniature-pancake && mount -t overlay overlay -o lowerdir='$S/appbuild',upperdir='$UP',workdir='$WK' '$S/appbuild' && cd '$S/appbuild' && exec ninja $*"
