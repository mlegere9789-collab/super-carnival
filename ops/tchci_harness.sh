set -euo pipefail
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-aa2a3ea1137f2ae4e/dino8-app/tests
BIN="$1"; fail=0
TMP="$(mktemp -d)"; TMPW="$TMP"
trap 'rm -rf "$TMP"' EXIT
near() { echo "     expected: $2"; }

TCH_TEST="$HERE/../touch/tests/touch_gestures.test.js"
# DINO8_REQUIRE_TOUCH=1 (set only by CI) turns every skip below into a FAIL, so a
# runner that lost node / playwright / xvfb-run cannot silently stop testing the PWA.
tch_skip() {
  if [ "${DINO8_REQUIRE_TOUCH:-0}" = "1" ]; then
    echo "FAIL TCH_touch: Dino 8 Touch PWA test is required (DINO8_REQUIRE_TOUCH=1) but was skipped: $1"
    fail=1
  else
    echo "skip TCH_ Dino 8 Touch PWA test ($1)"
  fi
}
if ! command -v node >/dev/null 2>&1; then
  tch_skip "node is not installed"
elif ! (cd "$HERE/../touch" && node -e "require('playwright')") >/dev/null 2>&1; then
  # Resolved from touch/ (where CI runs npm ci), the same place the test itself requires it from.
  tch_skip "the node 'playwright' package is not installed"
elif ! command -v xvfb-run >/dev/null 2>&1; then
  tch_skip "xvfb-run is not installed"
elif [ ! -f "$TCH_TEST" ]; then
  tch_skip "$TCH_TEST not found"
else
  TCH_RC=0
  TCH_OUT="$(timeout 900 node "$TCH_TEST" "$BIN" 2>&1)" || TCH_RC=$?
  TCH_OK="$(grep -c '^ok ' <<<"$TCH_OUT" || true)"
  TCH_BAD="$(grep -c '^FAIL' <<<"$TCH_OUT" || true)"
  if [ "$TCH_RC" -eq 0 ] && grep -q '^all passed' <<<"$TCH_OUT"; then
    echo "ok   TCH_touch: Dino 8 Touch PWA test passed ($TCH_OK checks: gestures, auth refusal, command round trip, offline service worker)"
  else
    echo "$TCH_OUT"
    echo "FAIL TCH_touch: Dino 8 Touch PWA test exited $TCH_RC ($TCH_OK ok, $TCH_BAD failed)"
    fail=1
  fi
fi

# ---------------------------------------------------------------------------
exit $fail
