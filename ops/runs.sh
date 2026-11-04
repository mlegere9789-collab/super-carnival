trap '' PIPE
# usage: runs.sh scriptfile   (runs under xvfb in scratchpad/t1, prints history lines)
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
cd $S/t1
timeout 300 xvfb-run -a -s "-screen 0 1280x720x24" $S/appbuild/Dino8 --smoke 10 --script "$1" 2>&1 | grep -v "CurveTools\|Saved \|^dino8:"
