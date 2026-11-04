#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
export XDG_CONFIG_HOME=$S/sat_show_tmp/cfg
timeout 300 xvfb-run -a $S/sat_manual/Dino8 --smoke 30 --script ${1:-$S/sat_probe.txt} 2>&1 | grep -E "${2:-Bounding|Volume|Area|polysurface|Brep|sphere|SAT}" | cut -c1-250
