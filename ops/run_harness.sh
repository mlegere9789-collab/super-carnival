#!/bin/bash
# usage: run_harness.sh <section file> <name>  -> scratchpad/<name>_harness.sh / <name>_harness.out
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
bash "$S/mk_harness.sh" "$1" "$S/$2_harness.sh"
bash "$S/$2_harness.sh" "$S/history2_build/Dino8" > "$S/$2_harness.out" 2>&1
echo "rc=$? ok=$(grep -c '^ok' "$S/$2_harness.out") fail=$(grep -c '^FAIL' "$S/$2_harness.out")"
grep -A3 '^FAIL' "$S/$2_harness.out" | head -80
