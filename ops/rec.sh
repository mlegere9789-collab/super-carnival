trap '' PIPE
# usage: rec.sh ID [fmt]
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a9ddf722e2f2d2152/dino8-app/tutorials
python3 $T/record.py --bin $S/appbuild/Dino8 --id "$1" --out $S/out --format "${2:-mp4}" --work $S/w/$1
