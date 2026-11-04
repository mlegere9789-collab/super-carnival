# Dino 8 horde protocol (standing order: 25-40 live agents, 24/7, nothing stalled >20 min)
Why slow (measured): 4 cores / 15 GB; one 99.5k-line test TU (3-10 min rebuilds, every agent appends -> every merge conflicts);
full kernel suite 25-35 min serial; smoke sections 15-40 min; one human-supervisor verifying serially.
Fixes in place: build gate (gate.sh, 2 build slots / 2 run slots, waiting agents heartbeat), infra agent (shards, per-feature test files,
selective/parallel smoke runner), stall detector on REAL activity (worktree files, commits, private builds), category-targeted agents,
two standing QC reviewers that write failing tests, 15-min watchdog (send_later), ledger.
Loop each watchdog: horde_status.sh -> nudge/retire/refire; cherry-pick delivered commits -> verify_k.sh / verify_a.sh myself (never trust reports)
-> push only green -> skeptic+refuter workflow on affected bullets -> move rows only when both agree with named tests -> refill to target -> ledger.
Never pkill by name. Agents commit locally only.
