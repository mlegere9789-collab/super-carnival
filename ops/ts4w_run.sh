#!/bin/bash
# usage: ts4w_run.sh <script>   (runs ts4_build/Dino8 on a script, prints output)
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" $S/ts4_build/Dino8 --smoke 30 --script "$1" 2>&1
