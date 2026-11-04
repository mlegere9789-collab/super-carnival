#!/bin/bash
# usage: syn.sh file.cpp   (syntax-only compile against the worktree headers)
W=/home/user/miniature-pancake/.claude/worktrees/agent-ad9fdba50f11440b3/dino8-kernel
D=/home/user/miniature-pancake/dino8-kernel/build
nice -n 19 c++ -fsyntax-only -std=gnu++17 -I$W/include -I$D/_deps/opennurbs-src/. -I$D/_deps/opennurbs-src/zlib/. -I$D/_deps/opennurbs-src/android_uuid/. -I$D/_deps/manifold-src/include -I$D/_deps/manifold-build/include "$@" 2>&1 | head -40
