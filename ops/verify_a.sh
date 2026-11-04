#!/bin/bash
# usage: verify_a.sh <name> : rebuild app (abort on failure), run broad sections
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/dino8-app/tests; SM=$T/smoke.sh
cd $S/appbuild || exit 9
cmake . >/dev/null; ninja -j2 Dino8 > $S/$1.build 2>&1 || { echo "BUILD_FAILED" > $S/$1.log; echo "EXIT=99" >> $S/$1.log; exit 99; }
{ sed -n '1,128p' $SM | sed "s#^HERE=.*#HERE=\"$T\"#"; sed -n '1278,1567p' $SM; sed -n '2232,2420p' $SM; sed -n '8695,10335p' $SM; sed -n '10417,10754p' $SM; sed -n '11137,11357p' $SM; sed -n '11358,$p' $SM; } | grep -v '^exit \$fail$' > $S/$1.sh; echo 'exit $fail' >> $S/$1.sh
timeout 3600 bash -c "trap '' PIPE; exec bash $S/$1.sh $S/appbuild/Dino8" > $S/$1.log 2>&1
echo "EXIT=$?" >> $S/$1.log
