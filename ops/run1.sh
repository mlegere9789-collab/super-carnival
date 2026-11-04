#!/bin/bash
# usage: run1.sh script.txt [VAR=val ...]  -> prints app output (filtered) to <script>.out
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
F="$1"; shift
cd "$S"
export XDG_CONFIG_HOME="$S/cfg1"; mkdir -p "$XDG_CONFIG_HOME"
env "$@" timeout 600 xvfb-run -a -s "-screen 0 1600x900x24" "$S/sbl_build/Dino8" --smoke 20 --script "$S/$F" > "$S/${F%.txt}.out" 2>&1
echo "exit $?" >> "$S/${F%.txt}.out"
