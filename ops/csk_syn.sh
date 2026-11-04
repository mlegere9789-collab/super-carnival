#!/bin/bash
# usage: csk_syn.sh <source file relative to dino8-app/src/commands>
B=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/appbuild/_deps
W=/home/user/miniature-pancake/.claude/worktrees/agent-ab8ab49d96ff3bdb2
exec /usr/bin/c++ -DDINO8_VERSION=\"0.1.0\" -DGL_SILENCE_DEPRECATION -DIMGUI_DEFINE_MATH_OPERATORS -DMANIFOLD_PAR=-1 -I$W/dino8-app/src -I$W/dino8-app/include -I$B/opennurbs-src/freetype263/include -I$B/libredwg-src/include -I$W/dino8-kernel/include -I$B/opennurbs-src/. -I$B/opennurbs-src/zlib/. -I$B/opennurbs-src/android_uuid/. -I$B/manifold-src/include -I$B/manifold-build/include -I$B/imgui-src -I$B/imgui-src/backends -I$B/glfw-src/include -I$B/lua-src -O0 -DNDEBUG -std=gnu++17 -Wall -Wextra -fsyntax-only $W/dino8-app/src/commands/$1
