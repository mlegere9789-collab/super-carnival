trap '' PIPE
# Runs ONLY the TUT_ section of smoke.sh with the same shell options and helpers.
set -euo pipefail
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-a9ddf722e2f2d2152/dino8-app/tests
BIN=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/appbuild/Dino8
TMPW="$(mktemp -d)"
export XDG_CONFIG_HOME="$TMPW/config"; mkdir -p "$XDG_CONFIG_HOME"
fail=0
near() { builtin echo "     expected: $2"; }
# extract from the marker to the end
sed -n '/^# --- Tutorial video pipeline/,$p' "$HERE/smoke.sh" | sed '$d' > "$TMPW/section.sh"
echo "section lines: $(wc -l < "$TMPW/section.sh")"
source "$TMPW/section.sh"
echo "fail=$fail"
rm -rf "$TMPW"
exit $fail
