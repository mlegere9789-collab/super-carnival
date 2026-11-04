trap '' PIPE
set -euo pipefail
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a9ddf722e2f2d2152/dino8-app/tutorials
ID=04-extrude-revolve-vase
rm -rf $S/neg; mkdir -p $S/neg/$ID
cp $S/out/$ID/* $S/neg/$ID/
# 1) swap two cues' times -> out-of-order
python3 - <<EOF
p="$S/neg/$ID/$ID.vtt"
t=open(p).read().split("\n")
idx=[i for i,l in enumerate(t) if "-->" in l]
t[idx[1]],t[idx[2]]=t[idx[2]],t[idx[1]]
open(p,"w").write("\n".join(t))
EOF
python3 $T/verify.py $S/neg $ID | grep "vtt"
# 2) replace the video by an all-black one of the same length
ffmpeg -nostdin -loglevel error -y -f lavfi -i color=c=black:s=1280x720:r=10 -t 62.6 -c:v libx264 -pix_fmt yuv420p $S/neg/$ID/$ID.mp4
python3 $T/verify.py $S/neg $ID | grep -E "blank|min_var|frames"
