#!/bin/bash
# usage: sbw_run.sh <exe-name> <outfile> [args]  (runs under the run gate)
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
EXE=$1; OUT=$2; shift 2
exec $S/gate.sh run timeout 1200 $S/sbw_kbuild/tests/$EXE "$@" > $S/$OUT 2>&1
