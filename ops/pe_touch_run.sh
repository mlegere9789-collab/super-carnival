trap '' PIPE
set -euo pipefail
SP=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
WT=/home/user/miniature-pancake/.claude/worktrees/agent-aa3cc9045c22c4ab3
mkdir -p "$SP/pe_cfg_v"
rm -f "$SP/pe_view_old.html"
XDG_CONFIG_HOME="$SP/pe_cfg_v" timeout 300 xvfb-run -a -s "-screen 0 1600x900x24" "$SP/appbuild/Dino8" --smoke 20 --script "$SP/pe_export.txt" 2>&1 | tail -3
python3 "$SP/pe_fixture.py" "$SP/pe_view_old.html" "$SP/pe_view_new.html"
echo "--- OLD viewer (expect FAILs) ---"
cd "$WT/dino8-app/tests"
NODE_PATH=$(npm root -g) node web_viewer_touch_check.js "$SP/pe_view_old.html" || true
echo "--- NEW viewer ---"
NODE_PATH=$(npm root -g) node web_viewer_touch_check.js "$SP/pe_view_new.html"
