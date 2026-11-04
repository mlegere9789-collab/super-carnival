#!/bin/bash
# Builds one branch per live agent (+ pending verified commits + ops tooling) in the super-carnival clone and pushes them all.
C=/home/user/super-carnival; M=/home/user/miniature-pancake; S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
G="git -c user.name=Claude -c user.email=noreply@anthropic.com"
cd $C; BASE=$(git rev-list --max-parents=0 main | head -1)
git checkout -q main; mkdir -p ops; cp $S/*.sh $S/*.py $S/HORDE.md $S/horde.tsv ops/ 2>/dev/null; git add -A ops >/dev/null
$G commit -q -m "ops: horde tooling (gate, roster, stall detector, verify scripts, merge helpers)" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01HtPNV3oNToKoUMfuRe6cWb" 2>&1 | tail -1
git checkout -q -B staging-verify main
rm -rf /tmp/p2; mkdir /tmp/p2; git -C $M format-patch -q -o /tmp/p2 b40c10b0..staging-verify 2>/dev/null
n2=$(ls /tmp/p2 | wc -l); r2=ok; [ $n2 -gt 0 ] && { $G am -q --3way /tmp/p2/*.patch >/dev/null 2>&1 || { git am --abort >/dev/null 2>&1; r2=am-failed; }; }
echo "staging-verify: $n2 patches $r2"
while IFS=$'\t' read -r id label st; do
  [ -z "$id" ] && continue; W=$M/.claude/worktrees/agent-$id; [ -d "$W" ] || { echo "$id MISSING"; continue; }
  b="agent/${id:1:8}-$(echo "$label" | tr -c 'a-zA-Z0-9' '-' | tr -s '-' | cut -c1-28 | sed 's/-$//')"
  git checkout -q -B "$b" "$BASE"; rm -rf /tmp/pa; mkdir /tmp/pa
  git -C $W format-patch -q -o /tmp/pa 7aff8cc8..HEAD 2>/dev/null
  n=$(ls /tmp/pa | wc -l); ok=ok
  [ $n -gt 0 ] && { $G am -q --3way /tmp/pa/*.patch >/dev/null 2>&1 || { git am --abort >/dev/null 2>&1; ok=am-failed; }; }
  git -C $W diff HEAD > /tmp/pw.diff 2>/dev/null
  if [ -s /tmp/pw.diff ] && [ "$ok" = ok ]; then git apply --index --whitespace=nowarn /tmp/pw.diff >/dev/null 2>&1 && $G commit -q -m "WIP (uncommitted) snapshot of agent $id: $label" || ok="$ok+wipdiff-skipped"; fi
  echo "$b commits=$n $ok"
done < $S/horde.tsv
git checkout -q main
timeout 1500 git push origin main staging-verify $(git branch --list 'agent/*' | tr -d ' *') 2>&1 | tail -6
echo PUSH_ALL_DONE
