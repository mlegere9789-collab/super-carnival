import re, sys, yaml

wf = ".github/workflows/dino8-app.yml"
act = ".github/actions/sign-windows/action.yml"
text = open(wf).read()
d = yaml.safe_load(text)
problems = []

# 1. no `secrets` in any if: (workflow and composite)
for f in (wf, act):
    for n, line in enumerate(open(f), 1):
        if re.match(r"\s*(-\s+)?if:", line) and "secrets." in line:
            problems.append(f"{f}:{n}: secrets in if: {line.strip()}")

# 2. permissions
assert d["permissions"] == {"contents": "read"}, d["permissions"]
for name, job in d["jobs"].items():
    perms = job.get("permissions")
    if name != "release" and perms:
        problems.append(f"job {name} has its own permissions {perms}")
rel = d["jobs"]["release"]
assert rel["permissions"] == {"contents": "write", "id-token": "write", "attestations": "write"}
assert "github.event_name == 'push'" in rel["if"] and "pull_request" not in rel["if"]

# 3. every signing/notarize step is gated on non-pull_request
for name, job in d["jobs"].items():
    for st in job["steps"]:
        sn = st.get("name", "")
        uses = st.get("uses", "")
        if re.search(r"sign|notar|keychain", sn, re.I) or "sign-windows" in uses:
            cond = str(st.get("if", ""))
            if "github.event_name != 'pull_request'" not in cond:
                problems.append(f"{name}: step '{sn}' not event-gated: {cond!r}")
            if "env." not in cond:
                problems.append(f"{name}: step '{sn}' not env-gated: {cond!r}")

# 4. third-party uses pinned to a version
for f in (wf, act):
    for n, line in enumerate(open(f), 1):
        m = re.search(r"uses:\s*(\S+)", line)
        if m and not m.group(1).startswith("./") and "@" not in m.group(1):
            problems.append(f"{f}:{n}: unpinned {m.group(1)}")

# 5. which job steps used actions (for the setup-time resolution risk)
actions = set()
for job in d["jobs"].values():
    for st in job["steps"]:
        if "uses" in st:
            actions.add(st["uses"])
print("actions referenced by the workflow:", sorted(actions))

# 6. existing-job step names unchanged except intentionally modified ones
print("problems:", problems or "none")
sys.exit(1 if problems else 0)
