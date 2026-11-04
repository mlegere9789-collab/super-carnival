#!/bin/bash
# usage: ofitbench_build.sh <outname>
set -e
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
W=/home/user/miniature-pancake/.claude/worktrees/agent-a2f776fd9ea5af42e/dino8-kernel
B=/home/user/miniature-pancake/dino8-kernel/build
K=$S/${KB:-ofit_kbuild}
g++ -O2 -std=gnu++17 -DMANIFOLD_PAR=-1 -I$W/include -I$B/_deps/opennurbs-src/. -I$B/_deps/opennurbs-src/zlib/. -I$B/_deps/opennurbs-src/android_uuid/. -I$B/_deps/manifold-src/include -I$B/_deps/manifold-build/include $S/ofitbench.cpp -o $S/$1 $K/libdino8_kernel.a -Wl,--start-group $K/_deps/opennurbs-build/libopennurbsStatic.a $K/_deps/opennurbs-build/freetype263/libopennurbs_public_freetype.a $K/_deps/opennurbs-build/android_uuid/libandroid_uuid.a $K/_deps/opennurbs-build/zlib/libzlib.a -Wl,--end-group $K/_deps/manifold-build/src/libmanifold.a -lpthread
ls -la $S/$1
