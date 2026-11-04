trap '' PIPE
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a9ddf722e2f2d2152/dino8-app/tutorials
for d in $T/[0-9][0-9]-*/; do
  i=$(basename $d)
  python3 $T/verify.py $S/outall $i | tr '\n' ' ' | sed -e 's/TUT_//g' | cut -c1-400
  echo
done
