#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
exec $S/kernel_build.sh sbw /home/user/miniature-pancake/.claude/worktrees/agent-ad51202d69d9cbbac -j2 "$@"
