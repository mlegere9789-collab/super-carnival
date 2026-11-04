#!/bin/bash
# usage: h4r_run.sh <command...>   runs the command inside the private overlay namespace (worktree + overlay build dir)
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a92541384807f36f6
U=$S/h4r_upper
W=$S/h4r_work
mkdir -p "$U" "$W"
exec unshare -m bash -c "mount --bind '$WT' /home/user/miniature-pancake && mount -t overlay overlay -o lowerdir='$S/appbuild',upperdir='$U',workdir='$W' '$S/appbuild' && exec \"\$@\"" bash "$@"
