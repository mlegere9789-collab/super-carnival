p = '/home/user/miniature-pancake/.claude/worktrees/agent-aa3cc9045c22c4ab3/dino8-app/tests/smoke.sh'
s = open(p).read()
old = '''    if ! grep -q "^ok   $n[: ]" <<<"$PSITE"; then echo "FAIL $n did not report ok (check missing or helper skipped it)"; fail=1; fi
  done
fi
'''
new = '''    if ! grep -q "^ok   $n[: ]" <<<"$PSITE"; then echo "FAIL $n did not report ok (check missing or helper skipped it)"; fail=1; fi
  done
  # Touch support of the exported web viewer (src/io/WebViewer.cpp): markers in
  # the real exported HTML, plus - where node + Playwright + Chromium exist - real
  # touch input (one-finger orbit, two-finger pinch) via tests/web_viewer_touch_check.js.
  PWV="$(timeout 900 bash "$HERE/web_viewer_touch_test.sh" "$BIN" 2>&1)" || { echo "$PWV" | tail -30; echo "FAIL: web_viewer_touch_test.sh exited non-zero"; fail=1; }
  echo "$PWV" | grep -E "^(ok|FAIL|skip)" || true
  if grep -q "^FAIL" <<<"$PWV"; then fail=1; fi
  for n in pwv_export pwv_viewport_meta pwv_touch_action pwv_pointer_events pwv_coarse_ui pwv_no_mouse_only pwv_self_contained; do
    if ! grep -q "^ok   $n[: ]" <<<"$PWV"; then echo "FAIL $n did not report ok"; fail=1; fi
  done
fi
'''
assert s.count(old) == 1
s = s.replace(old, new)
open(p, 'w').write(s)

p = '/home/user/miniature-pancake/.claude/worktrees/agent-aa3cc9045c22c4ab3/dino8-app/docs/COMMUNITY.md'
s = open(p).read()
old = '## Video tutorials'
new = '''## Touch / phone use

There is no native companion app and no sync-back from a phone to a Dino 8 document. What exists: the
`ExportWebViewer Path=<file.html>` output is one self-contained file that now works with fingers on a
phone or tablet browser - one-finger orbit, two-finger pinch zoom, a mobile viewport, larger Scale
sliders on touch screens (Pointer Events; `src/io/WebViewer.cpp`). `tests/web_viewer_touch_test.sh`
checks the exported HTML and, where node + Playwright + Chromium are installed, drives real touch
input through `tests/web_viewer_touch_check.js`. Pan, selection and editing on touch are not implemented.

## Video tutorials'''
assert s.count(old) == 1
s = s.replace(old, new)
open(p, 'w').write(s)
print('ok')
