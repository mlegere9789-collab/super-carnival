#!/bin/bash
cd /tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
: > offset_regress_summary.txt
for f in offset_unified_tests Offset Shell Thicken Ribbon Sphere; do
  DINO8_TEST_FILTER=$f timeout 1500 ./offset_kbuild/tests/dino8_kernel_tests > offset_reg_$f.log 2>&1
  echo "$f exit=$? ok=$(grep -c '^ok' offset_reg_$f.log) FAILED=$(grep -c '^FAILED' offset_reg_$f.log)" >> offset_regress_summary.txt
done
echo DONE >> offset_regress_summary.txt
