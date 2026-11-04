trap '' PIPE
set -euo pipefail
WT=/home/user/miniature-pancake/.claude/worktrees/agent-aa3cc9045c22c4ab3
SP=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
rm -rf "$SP/pe_pristine"
mkdir -p "$SP/pe_pristine"
git -C "$WT" archive origin/claude/pdf-audit-i2bvwm dino8-app | tar -x -C "$SP/pe_pristine"
find "$SP/pe_pristine" -type f -exec touch -d '2020-01-01' {} +
# regenerate ONLY the build files (no compile) so the shared build.ninja no longer references plugin-sdk
unshare -m bash -c "mount --bind $SP/pe_pristine/dino8-app /home/user/miniature-pancake/dino8-app && cd $SP/appbuild && cmake . > $SP/pe_restore_cmake.log 2>&1"
tail -3 "$SP/pe_restore_cmake.log"
grep -c "plugin-sdk" "$SP/appbuild/build.ninja" || true
