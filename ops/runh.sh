#!/bin/bash
# usage: runh.sh harness.sh [VAR=val ...]   (runs against the private sbl binary, output to harness.log)
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
H="$1"; shift
trap '' PIPE
cd "$S"
env "$@" bash "$S/$H" "$S/sbl_build/Dino8" > "$S/${H%.sh}.log" 2>&1
echo "exit $?" >> "$S/${H%.sh}.log"
