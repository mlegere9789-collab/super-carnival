#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT="$1"; shift
mount --bind "$WT" /home/user/miniature-pancake || exit 90
mkdir -p /home/user/miniature-pancake/dino8-kernel/build
mount --bind $S/xt_kbuild /home/user/miniature-pancake/dino8-kernel/build || exit 92
cd /home/user/miniature-pancake/dino8-kernel/build || exit 91
ninja libdino8_kernel.a 2>&1 | grep -E 'error|FAILED' -A4 | head -40
SRC=${XT_SRC:-$S/xt_mini.cpp}
g++ -O1 -g -std=gnu++17 -DMANIFOLD_PAR=-1 -I../include -I_deps/opennurbs-src/. -I_deps/opennurbs-src/zlib/. -I_deps/opennurbs-src/android_uuid/. -I_deps/manifold-src/include -I_deps/manifold-build/include \
  $SRC -o $S/xt_mini.bin libdino8_kernel.a -Wl,--start-group _deps/opennurbs-build/libopennurbsStatic.a _deps/opennurbs-build/freetype263/libopennurbs_public_freetype.a _deps/opennurbs-build/android_uuid/libandroid_uuid.a _deps/opennurbs-build/zlib/libzlib.a -Wl,--end-group _deps/manifold-build/src/libmanifold.a -lpthread 2>&1 | grep -E 'error|undefined' -A3 | head -40
timeout 300 stdbuf -o0 $S/xt_mini.bin "$@"
