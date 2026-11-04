#!/bin/bash
# usage: horde_status.sh  - reads horde.tsv (id<TAB>label<TAB>started_epoch). Activity = newest of: tool-output file, newest source file in the
# agent's worktree, its latest commit, its private build dirs. STALLED if no activity for >20 min (default; override STALL_MIN).
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/tasks
W=/home/user/miniature-pancake/.claude/worktrees
LIM=${STALL_MIN:-20}
now=$(date +%s); n=0; stalled=0
while IFS=$'\t' read -r id label started; do
  [ -z "$id" ] && continue
  best=0
  f="$T/$id.output"; [ -f "$f" ] && best=$(stat -c %Y "$f")
  wt="$W/agent-$id"
  if [ -d "$wt" ]; then
    m=$(find "$wt/dino8-kernel/src" "$wt/dino8-kernel/include" "$wt/dino8-kernel/tests" "$wt/dino8-app/src" "$wt/dino8-app/tests" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1); [ -n "$m" ] && [ "$m" -gt "$best" ] && best=$m
    c=$(git -C "$wt" log -1 --format=%ct 2>/dev/null); [ -n "$c" ] && [ "$c" -gt "$best" ] && best=$c
  fi
  for b in "$S"/*"${id:0:8}"*_kbuild "$S"/*"${id:0:8}"*_build; do [ -d "$b" ] && { m=$(stat -c %Y "$b"); [ "$m" -gt "$best" ] && best=$m; }; done
  age=$(( (now-best)/60 )); run=$(( (now-started)/60 )); st=OK
  [ $age -gt $LIM ] && { st=STALLED; stalled=$((stalled+1)); }
  printf '%-18s %-36s running %4dm  last activity %4dm ago  %s\n' "$id" "$label" $run $age $st; n=$((n+1))
done < "$S/horde.tsv"
echo "agents: $n   stalled: $stalled   (target 12 live)"
