#!/bin/bash
# usage: kernel_build.sh <name> <worktree> <ninja args...>   (kernel tests; never touches the shared dino8-kernel/build)
set -euo pipefail
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
MAIN=/home/user/miniature-pancake
NAME="$1"; WT="$(cd "$2" && pwd)"; shift 2
DST="$S/${NAME}_kbuild"
[ -d "$DST" ] || cp -a "$MAIN/dino8-kernel/build" "$DST"
mkdir -p "$WT/dino8-kernel/build"
if [ ! -f "$WT/.agent_touched" ]; then
  (cd "$WT" && git ls-files -z | xargs -0 touch -d '2020-01-01' && touch .agent_touched)
fi
export GATE_TOUCH="$DST"
exec unshare -m bash -c "mount --bind '$WT' '$MAIN' && mount --bind '$DST' '$MAIN/dino8-kernel/build' && cd '$MAIN/dino8-kernel/build' && exec /tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/gate.sh build ninja $*"
