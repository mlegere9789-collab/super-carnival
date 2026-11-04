#!/bin/bash
# usage: offset_scratch.sh <src.cpp> <out exe>
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
B=$S/offset_kbuild
WT=/home/user/miniature-pancake/.claude/worktrees/agent-aa6e534ddf8535ecc/dino8-kernel
g++ -O2 -std=gnu++17 -DMANIFOLD_PAR=-1 -I$WT/include -I$B/_deps/opennurbs-src -I$B/_deps/opennurbs-src/zlib -I$B/_deps/opennurbs-src/android_uuid -I$B/_deps/manifold-src/include -I$B/_deps/manifold-build/include "$1" -o "$2" $B/libdino8_kernel.a -Wl,--start-group $B/_deps/opennurbs-build/libopennurbsStatic.a $B/_deps/opennurbs-build/freetype263/libopennurbs_public_freetype.a $B/_deps/opennurbs-build/android_uuid/libandroid_uuid.a $B/_deps/opennurbs-build/zlib/libzlib.a -Wl,--end-group $B/_deps/manifold-build/src/libmanifold.a -lpthread
