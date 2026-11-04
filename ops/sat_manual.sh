#!/bin/bash
# Compiles the four changed/new app sources into a private dir and relinks Dino8 there, reading (never writing) the shared
# appbuild's objects/libs, because the volume has no room for a private copy of the build directory.
set -euo pipefail
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT=/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e
A=$S/appbuild
D=$A/_deps
OUT=$S/sat_manual
mkdir -p "$OUT"
INC="-I$WT/dino8-app/src -I$WT/dino8-app/include -I$D/opennurbs-src/freetype263/include -I$D/libredwg-src/include -I$WT/dino8-kernel/include -I$D/opennurbs-src/. -I$D/opennurbs-src/zlib/. -I$D/opennurbs-src/android_uuid/. -I$D/manifold-src/include -I$D/manifold-build/include -I$D/imgui-src -I$D/imgui-src/backends -I$D/glfw-src/include -I$D/lua-src"
DEFS='-DDINO8_VERSION="0.1.0" -DGL_SILENCE_DEPRECATION -DIMGUI_DEFINE_MATH_OPERATORS -DMANIFOLD_PAR=-1'
FLAGS="-O3 -DNDEBUG -std=gnu++17 -Wall -Wextra"
comp() { # name relative-source
  /usr/bin/c++ $DEFS $INC $FLAGS -o "$OUT/$1.o" -c "$WT/dino8-app/$2"
}
case "${1:-all}" in
  compile)
    comp FileSat src/io/FileSat.cpp
    comp cmd_file src/commands/cmd_file.cpp &
    wait
    comp Application src/app/Application.cpp &
    comp DwgCompare src/compare/DwgCompare.cpp &
    wait
    ;;
  satonly)
    comp FileSat src/io/FileSat.cpp
    ;;
  link)
    cd "$A"
    LINE="$(grep -m1 '^build Dino8: CXX_EXECUTABLE_LINKER__Dino8_Release' build.ninja)"
    OBJS="${LINE#build Dino8: CXX_EXECUTABLE_LINKER__Dino8_Release }"
    OBJS="${OBJS%% |*}"
    NEW=""
    for o in $OBJS; do
      case "$o" in
        CMakeFiles/Dino8.dir/src/app/Application.cpp.o) NEW="$NEW $OUT/Application.o" ;;
        CMakeFiles/Dino8.dir/src/commands/cmd_file.cpp.o) NEW="$NEW $OUT/cmd_file.o" ;;
        CMakeFiles/Dino8.dir/src/compare/DwgCompare.cpp.o) NEW="$NEW $OUT/DwgCompare.o" ;;
        *) NEW="$NEW $o" ;;
      esac
    done
    NEW="$NEW $OUT/FileSat.o"
    LL="$(sed -n '/^build Dino8: /,/^$/p' build.ninja | grep -m1 'LINK_LIBRARIES = ')"
    LL="${LL#*LINK_LIBRARIES = }"
    LP="$(sed -n '/^build Dino8: /,/^$/p' build.ninja | grep -m1 'LINK_PATH = ' || true)"
    LP="${LP#*LINK_PATH = }"
    /usr/bin/c++ -O3 -DNDEBUG $NEW -o "$OUT/Dino8" $LP $LL
    [ -e "$OUT/data" ] || ln -s "$A/data" "$OUT/data"
    ls -l "$OUT/Dino8"
    ;;
esac
