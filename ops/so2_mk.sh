#!/bin/bash
# usage: so2_mk.sh out.sh start end [start end ...]
T=/home/user/miniature-pancake/.claude/worktrees/agent-a85dac6234d906358/dino8-app/tests
out="$1"; shift
{
  echo '#!/usr/bin/env bash'
  echo "trap '' PIPE"
  sed -n '2,128p' "$T/smoke.sh" | sed "s|^HERE=.*|HERE=$T|"
  while [ $# -gt 0 ]; do sed -n "$1,$2p" "$T/smoke.sh"; shift 2; done
  echo 'exit $fail'
} > "$out"
