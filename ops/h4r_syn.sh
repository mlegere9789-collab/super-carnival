#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a92541384807f36f6
D=$S/rev3_build/_deps
INC="-I$WT/dino8-app/src -I$WT/dino8-app/include -I$D/opennurbs-src/freetype263/include -I$D/libredwg-src/include -I$WT/dino8-kernel/include -I$D/opennurbs-src/. -I$D/opennurbs-src/zlib/. -I$D/opennurbs-src/android_uuid/. -I$D/manifold-src/include -I$D/manifold-build/include -I$D/imgui-src -I$D/imgui-src/backends -I$D/glfw-src/include -I$D/lua-src"
for f in "$@"; do
  c++ -DDINO8_VERSION=\"0.1.0\" -DGL_SILENCE_DEPRECATION -DIMGUI_DEFINE_MATH_OPERATORS -DMANIFOLD_PAR=-1 -O0 -std=gnu++17 -Wall -Wextra $INC -fsyntax-only "$WT/dino8-app/src/commands/$f" > "$S/h4r_syn_$f.log" 2>&1 &
done
wait
