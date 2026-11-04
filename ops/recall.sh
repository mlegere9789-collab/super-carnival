trap '' PIPE
# usage: recall.sh id...   records each and shows problems
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
for i in "$@"; do
  echo "=== $i"
  bash $S/rec.sh $i 2>&1 | tail -2 | cut -c1-260
  grep -n "FAIL\|^history: !\|Volume\|Warn\|nknown\|rror" $S/w/$i/app.log | grep -v "Saved\|Command:" | head -14 || true
done
