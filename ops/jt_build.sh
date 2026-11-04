#!/bin/bash
# Builds the kernel tests from the JT worktree. Inside a private mount namespace
# the worktree is bound over the main checkout path and the private build copy
# (jt_kbuild) is bound over <main>/dino8-kernel/build, so every baked-in
# absolute path resolves to the worktree sources and to the PRIVATE copy; the
# lead's shared build directory is never reachable from here.
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a2aa73788815f8842
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
mount --bind "$WT" /home/user/miniature-pancake || exit 90
mount --bind "$S/jt_kbuild" /home/user/miniature-pancake/dino8-kernel/build || exit 91
cd /home/user/miniature-pancake/dino8-kernel/build || exit 92
cmake . > "$S/jt_cmake.log" 2>&1
tail -2 "$S/jt_cmake.log"
timeout 540 ninja "$@" 2>&1 | tail -60
