#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
B=$S/g1g2_kbuild/tests/dino8_kernel_tests
cd /tmp
for f in edge_continuity_tests Surface Loft Network Patch MatchEdge; do
  DINO8_TEST_FILTER=$f timeout 1500 $B > $S/run_$f.txt 2>&1
  code=$?
  echo "filter=$f exit=$code ok=$(grep -c '^ok' $S/run_$f.txt) FAILED=$(grep -c 'FAILED' $S/run_$f.txt) last: $(tail -1 $S/run_$f.txt)"
done
