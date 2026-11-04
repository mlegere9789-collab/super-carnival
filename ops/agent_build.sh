#!/bin/bash
# usage: agent_build.sh <name> <worktree> <ninja args...>
# Builds <worktree>'s sources against a PRIVATE copy ($S/<name>_build) of the shared app build. Inside a private mount
# namespace the copy appears at the shared build's own path and the worktree at the main checkout's path, so every
# command line is identical to the shared build's (nothing rebuilds needlessly) and the real shared directory is hidden.
set -euo pipefail
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
NAME="$1"; WT="$(cd "$2" && pwd)"; shift 2
DST="$S/${NAME}_build"
[ -d "$DST" ] || cp -a "$S/appbuild" "$DST"
if [ ! -f "$WT/.agent_touched" ]; then
  (cd "$WT" && git ls-files -z | xargs -0 touch -d '2020-01-01' && touch .agent_touched)
fi
export GATE_TOUCH="$DST"
exec unshare -m bash -c "mount --bind '$WT' /home/user/miniature-pancake && mount --bind '$DST' '$S/appbuild' && cd '$S/appbuild' && exec /tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/gate.sh build ninja $*"
