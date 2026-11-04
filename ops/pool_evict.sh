#!/bin/bash
# usage: pool_evict.sh <cap_kernel> <cap_app> [keep_dir]  - delete the oldest IDLE private build dirs until at most cap remain per kind.
# A dir is BUSY if any process command line mentions it. Never touches appbuild or the keep dir.
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
CK=${1:-10}; CA=${2:-4}; KEEP="${3:-}"
evict(){ pat="$1"; cap="$2"
  mapfile -t L < <(ls -dt $S/$pat 2>/dev/null | grep -v '/appbuild$')   # newest first
  n=${#L[@]}; [ $n -le $cap ] && return
  for ((i=n-1;i>=cap;i--)); do d="${L[$i]}"; [ "$d" = "$KEEP" ] && continue
    pgrep -f "$d" >/dev/null 2>&1 && continue
    rm -rf "$d"; echo "evicted $(basename $d)"
  done; }
evict '*_kbuild' $CK; evict '*_build' $CA
