set -euo pipefail
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-aa2a3ea1137f2ae4e/dino8-app/tests
BIN="$1"; fail=0
TMP="$(mktemp -d)"; TMPW="$TMP"
trap 'rm -rf "$TMP"' EXIT
near() { echo "     expected: $2"; }

TUTV_DIR="${DINO8_TUTORIAL_VIDEO_DIR:-}"
if [ -z "$TUTV_DIR" ]; then
  echo "skip TUTV_*: set DINO8_TUTORIAL_VIDEO_DIR=DIR to record every tutorial into DIR and probe each video"
elif [ "$(uname -s)" != "Linux" ] || ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL TUTV_: DINO8_TUTORIAL_VIDEO_DIR is set but this needs Linux with ffmpeg, ffprobe and python3"; fail=1
else
  mkdir -p "$TUTV_DIR"
  TUTV_N=0
  for TUTV_PATH in "$HERE"/../tutorials/[0-9][0-9]-*/; do
    TUTV_NAME="$(basename "$TUTV_PATH")"
    TUTV_N=$((TUTV_N + 1))
    TUTV_REC="$(timeout 900 python3 "$HERE/../tutorials/record.py" --bin "$BIN" --id "$TUTV_NAME" --out "$TUTV_DIR" 2>&1)" || { echo "$TUTV_REC" | tail -20; echo "FAIL TUTV_$TUTV_NAME: recorder exited non-zero"; fail=1; continue; }
    TUTV_VID="$TUTV_DIR/$TUTV_NAME/$TUTV_NAME.mp4"
    TUTV_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TUTV_VID" 2>/dev/null || true)"
    TUTV_FR="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$TUTV_VID" 2>/dev/null || true)"
    if [ -n "$TUTV_DUR" ] && [ -n "$TUTV_FR" ] && [ "$TUTV_FR" -gt 0 ] 2>/dev/null && python3 -c "import sys; sys.exit(0 if float('$TUTV_DUR') > 0 else 1)" 2>/dev/null; then
      echo "ok   TUTV_$TUTV_NAME: ffprobe: $TUTV_FR frames, $TUTV_DUR s ($(stat -c %s "$TUTV_VID") bytes)"
    else
      echo "FAIL TUTV_$TUTV_NAME: ffprobe found no video, or zero duration / frames (duration '$TUTV_DUR', frames '$TUTV_FR')"; fail=1
    fi
  done
  if [ "$TUTV_N" -eq 10 ]; then echo "ok   TUTV_count: all 10 tutorials were recorded and probed"; else echo "FAIL TUTV_count: expected 10 tutorials, found $TUTV_N"; fail=1; fi
fi

exit $fail
