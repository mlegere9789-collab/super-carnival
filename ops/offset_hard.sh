#!/bin/bash
cd /tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
bash offset_scratch.sh offset_scratch2.cpp offset_scratch2 2>&1 | head -5
for a in "10 3 1.0 1.9 0.1 1e-4" "10 3 1.0 1.9 0.1 1e-7" "10 3 1.0 1.9 0.3 1e-4" "12 5 1.0 2.2 0.2 1e-5"; do
  echo "== $a"
  timeout 90 ./offset_scratch2 3 $a 2>&1 | cut -c1-250
done
