#!/bin/bash
# read-only syntax check of the files I changed, against the shared build's include dirs (nothing is written there)
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e
D=$S/appbuild/_deps
INC="-I$WT/dino8-app/src -I$WT/dino8-app/include -I$D/opennurbs-src/freetype263/include -I$WT/dino8-kernel/include -I$D/opennurbs-src/. -I$D/opennurbs-src/zlib/. -I$D/opennurbs-src/android_uuid/. -I$D/manifold-src/include -I$D/manifold-build/include -I$D/imgui-src -I$D/imgui-src/backends -I$D/glfw-src/include -I$D/lua-src -I$D/libredwg-src/include"
for f in "$@"; do
  echo "== $f"
  g++ -fsyntax-only -std=gnu++17 -Wall -Wextra -DDINO8_VERSION=\"0.1.0\" -DGL_SILENCE_DEPRECATION -DIMGUI_DEFINE_MATH_OPERATORS -DMANIFOLD_PAR=-1 $INC "$WT/dino8-app/$f" -Wno-unknown-pragmas 2>&1 | grep -E "error|FileSat|warning: unused" | head -40
done
