#!/bin/bash
# usage: ts4_run.sh <binary> <script> <out>
timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$1" --smoke 30 --script "$2" > "$3" 2>&1
echo "exit=$?" >> "$3"
