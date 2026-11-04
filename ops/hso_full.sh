#!/bin/bash
# usage: hso_full.sh <bindir> <log>   (runs the whole smoke.sh of the worktree against <bindir>/Dino8)
trap '' PIPE
exec bash /home/user/miniature-pancake/.claude/worktrees/agent-ae1115806603edb25/dino8-app/tests/smoke.sh "$1/Dino8" > "$2" 2>&1
