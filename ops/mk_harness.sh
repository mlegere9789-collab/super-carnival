#!/bin/bash
# usage: mk_harness.sh <section file> <output harness>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests
{
  echo '#!/usr/bin/env bash'
  echo "trap '' PIPE"
  sed -n '2,128p' "$T/smoke.sh" | sed "s|^HERE=.*|HERE=$T|"
  cat "$1"
  echo 'exit $fail'
} > "$2"
