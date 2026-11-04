#!/bin/bash
# usage: gate.sh <kind: build|run> <command...>
# A counting semaphore (flock slot files) so at most N heavy jobs of one kind run at once on this 4-core machine.
# Waits for a free slot (never gives up silently: prints the wait), runs the command holding the slot.
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
KIND="$1"; shift
case "$KIND" in build) N=${GATE_BUILD_SLOTS:-2};; run) N=${GATE_RUN_SLOTS:-2};; *) echo "gate: bad kind $KIND"; exit 2;; esac
mkdir -p "$S/gate"
waited=0
while true; do
  for i in $(seq 1 $N); do
    exec 9>"$S/gate/$KIND.$i.lock"
    if flock -n 9; then
      [ $waited -gt 0 ] && echo "gate: acquired $KIND slot $i after ${waited}s" >&2
      "$@"; rc=$?; exec 9>&-; exit $rc
    fi
    exec 9>&-
  done
  [ -n "${GATE_TOUCH:-}" ] && touch "$GATE_TOUCH" 2>/dev/null; sleep 5; waited=$((waited+5))
done
