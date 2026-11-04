#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e/dino8-app/tests
W=$S/sat_show_tmp
mkdir -p $W/cfg
export XDG_CONFIG_HOME=$W/cfg
printf 'this is not an ACIS save file\n' > $W/satf_bad.sat
for n in satf_script satf_bool_script; do
  sed "s|@TMP@|$W|g" $T/$n.txt > $W/$n.txt
  echo "######## $n"
  timeout 600 xvfb-run -a -s "-screen 0 1600x900x24" $S/sat_manual/Dino8 --smoke 40 --script $W/$n.txt 2>&1 | grep -E "SAT |^  [A-Za-z_0-9 ()-]+: |UNVERIFIED|Not written|Refused|Volume = |Area = |Coordinates|Format status|Imported|Exported|Opened|refused" | cut -c1-420
done
head -c 600 $W/satf_box.sat
