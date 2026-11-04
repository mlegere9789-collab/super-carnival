#!/usr/bin/env python3
# Runs the workflow's "Check that the touch and tutorial checks ran" step script against a synthetic smoke.log.
import os, shutil, subprocess, sys, tempfile, yaml
S = "/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad"
wf = yaml.safe_load(open("/home/user/miniature-pancake/.claude/worktrees/agent-aa2a3ea1137f2ae4e/.github/workflows/dino8-app.yml"))
step = [x for x in wf["jobs"]["linux"]["steps"] if x.get("name", "").startswith("Check that the touch")][0]
good = open(S + "/tchci_smoke.log").read()
cases = {
    "good": good,
    "touch skipped": good.replace("ok   TCH_touch", "skip TCH_ Dino 8 Touch PWA test (node is not installed) x"),
    "tut skipped": good + "skip TUT_*: nope\n",
    "only 9 videos": good.replace("ok   TUTV_10-export-printing", "ok   nothing"),
}
for name, text in cases.items():
    d = tempfile.mkdtemp(dir=S)
    open(d + "/smoke.log", "w").write(text)
    r = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]], cwd=d, capture_output=True, text=True)
    print("%-14s exit=%d" % (name, r.returncode))
    shutil.rmtree(d)
