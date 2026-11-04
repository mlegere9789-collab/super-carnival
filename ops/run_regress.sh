#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
cd "$S/sfill_kbuild/tests"
: > "$S/regress_result.txt"
ulimit -v 3000000
while read -r name; do
  out=$(DINO8_TEST_FILTER="$name" timeout 60 ./dino8_kernel_tests 2>&1)
  rc=$?
  if [ $rc -eq 124 ]; then echo "TIMEOUT $name" >> "$S/regress_result.txt"
  elif [ $rc -ne 0 ]; then echo "FAIL($rc) $name :: $(echo "$out" | grep -E 'FAILED|terminate|bad_alloc' | head -2 | cut -c1-200)" >> "$S/regress_result.txt"
  else echo "PASS $name" >> "$S/regress_result.txt"; fi
done < "$S/regress_names.txt"
echo DONE >> "$S/regress_result.txt"
