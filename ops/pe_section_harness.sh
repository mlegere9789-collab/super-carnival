trap '' PIPE
set -euo pipefail
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-aa3cc9045c22c4ab3/dino8-app/tests
BIN="$1"
fail=0
IS_WINDOWS=0
SECTION="$(sed -n '/^# Third-party plug-in ecosystem/,$p' "$HERE/smoke.sh")"
eval "$SECTION"
