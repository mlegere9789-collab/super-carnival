#!/bin/bash
# builds two regression harnesses from the current smoke.sh and runs them in parallel
M=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
python3 $M/mkharness_w.py $M/h_r1.sh 1528 1663 8885 9061
python3 $M/mkharness_w.py $M/h_r2.sh 9718 9925 10029 10067 10885 10953 11047 11119
for f in h_r1 h_r2; do bash -n $M/$f.sh || echo "syntax error in $f"; done
$M/runh.sh $M/h_r1.sh $M/h_r1.out &
$M/runh.sh $M/h_r2.sh $M/h_r2.out &
wait
