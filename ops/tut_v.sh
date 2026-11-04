#!/usr/bin/env bash
# Headless functional QC for Dino 8: runs a command script through the real
# app under Xvfb and checks the resulting history/object counts.
set -euo pipefail
# Hundreds of checks below are `echo "$BIG" | grep -q PATTERN`. GitHub's
# runner starts this script with SIGPIPE ignored, so when grep exits on its
# first match a still-writing echo gets EPIPE ("echo: write error: Broken
# pipe") instead of dying silently, and under `pipefail` that turned a
# MATCHED check into a FAIL at random (the e7b5a52c Linux run). An echo's
# write status must never decide a check: only grep's does.
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE=/home/user/miniature-pancake/dino8-app/tests
BIN="${1:-$HERE/../build/Dino8}"
TMP="$(mktemp -d)"
# The real, OS-native form of $TMP - needed wherever a path is embedded as
# literal TEXT inside a script file the app itself parses (Save/Open/Export/
# Import command lines), as opposed to a bash-level file operation or a
# command-line argument handed straight to $BIN. Bash's own POSIX-path file
# ops (mkdir/cat/grep/rm) and argv passed directly to a spawned native
# process both get Git-for-Windows' automatic MSYS<->Windows path
# translation; a path baked into a script file's own bytes gets none of
# that; the app's own file I/O then tries to open "/tmp/xxx" literally,
# which Windows resolves as "current drive's root\tmp\xxx" - never the
# real temp directory - and every Save/Export/Import in that script fails.
# cygpath -m gives the same drive-letter path with forward slashes (valid
# to Win32 file APIs, and avoids backslash-escaping issues in sed/heredoc
# text); on Linux/macOS (no cygpath) this is just $TMP again, a no-op.
if command -v cygpath >/dev/null 2>&1; then TMPW="$(cygpath -m "$TMP")"; else TMPW="$TMP"; fi
# Same reasoning as TMPW above, for $HERE (this file's own directory):
# a handful of sed substitutions below bake $HERE into a *.dflow/script
# path that becomes literal TEXT inside a generated script file (an
# @DINO8ROOT@/@TREEFILE@/@SOLVERFILE@/@GEOMFILE@ token, not a bash-level
# file argument), so it needs the same OS-native form.
if command -v cygpath >/dev/null 2>&1; then HEREW="$(cygpath -m "$HERE")"; else HEREW="$HERE"; fi
# Isolate settings so persisted toggles (Ortho, snaps, theme) from earlier runs cannot leak into the checks.
export XDG_CONFIG_HOME="$TMPW/config"
mkdir -p "$XDG_CONFIG_HOME"
# Windows (Git-Bash on the CI runner): the app's config directory there is
# %APPDATA%\Dino8 (app/Settings.h - XDG_CONFIG_HOME is a freedesktop
# convention the app rightly does not consult on Windows), so the export
# above alone isolated nothing on that platform: every script shared, and
# persisted into, the runner's real %APPDATA%\Dino8, and the one check that
# reads the config directory back off disk (plugin_reviews.json, below)
# looked in a directory the app never wrote to. Pointing APPDATA at the
# same per-run scratch directory gives Windows exactly the isolation
# XDG_CONFIG_HOME gives Linux. Nothing else this script runs (the app, curl,
# python3's stdlib) keys off APPDATA. CONFIG_DIR is the directory the app
# actually writes on the current platform, for the checks that read it.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; *) IS_WINDOWS=0 ;; esac
if [ "$IS_WINDOWS" = 1 ]; then
  export APPDATA="$XDG_CONFIG_HOME"
  CONFIG_DIR="$APPDATA/Dino8"
else
  CONFIG_DIR="$XDG_CONFIG_HOME/dino8"
fi
trap 'rm -rf "$TMP"' EXIT

cat > "$TMPW/script.txt" <<EOS
Box 0,0,0 20,20,0 10
Sphere 10,10,10 8
SelNone
SelID 1
BooleanDifference
SelID 2
Enter
SelAll
Volume
SelNone
Circle 40,0,0 5
SelCrv
ExtrudeCrv 12
SelAll
Save $TMPW/test.3dm
New
Open $TMPW/test.3dm
SelAll
List
Undo
Redo
Line 0,0,0 10,10,0
SelCrv
Length
SelAll
Export $TMPW/test.obj
SelNone
Cylinder 60,0,0 5 15
SelLast
What
ToolbarAddCommand Fillet
ToolbarAddCommand NotARealCommandXYZ
ToolbarAddCommand b
EOS

if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  OUT="$(timeout 900 "$BIN" --smoke 200 --script "$TMPW/script.txt" 2>&1)" || { echo "$OUT"; echo "FAIL: app exited non-zero"; exit 1; }
else
  OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$TMPW/script.txt" 2>&1)" || { echo "$OUT"; echo "FAIL: app exited non-zero"; exit 1; }
fi
echo "$OUT" | grep "^smoke:" || { echo "$OUT"; echo "FAIL: no smoke line"; exit 1; }
fail=0
# On a FAIL, show what the app actually printed for the line the check was
# looking for, so a platform-specific value difference (e.g. MSVC vs GCC
# producing "Volume = 199.9999" instead of "Volume = 200") is visible in the
# CI log directly instead of only "FAIL <description>". The expected pattern
# is trimmed at its first digit to get a stable prefix ("Volume = ", "CV[0] ",
# "Shell: thickness "), and every output line carrying that prefix is echoed
# (capped, so a runaway match can't flood the log). Diagnostic only - never
# changes pass/fail.
near() {
  local out="$1" pat="$2" prefix
  prefix="${pat%%[0-9]*}"
  prefix="${prefix%%\\*}"
  prefix="${prefix%%[\[\]\(\)\.\*\^\$]*}"
  # A pattern with no digits/regex-special char to trim at (e.g. a plain
  # "Command: installed X" literal) leaves prefix == pat, which used to skip
  # printing entirely - a self-grep for the exact string that already failed
  # grep -q is pointless, but giving up there means a command that printed
  # nothing AT ALL (or printed an error instead of its success line) shows
  # no actual output here either, just "expected:" with nothing to compare
  # against. Fall back to the pattern's own first word (most of this app's
  # commands print "CommandName: <result or error>", so even an error line
  # usually still starts with it) so at least something nearby surfaces.
  if [ "$prefix" == "$pat" ]; then prefix="${pat%% *}"; fi
  echo "     expected: $pat"
  if [ -n "$prefix" ] && [ "$prefix" != "$pat" ]; then
    echo "$out" | grep -F -- "$prefix" | head -16 | sed 's/^/     actual:   /' || true
  fi
}
# Docs tutorials (docs/site/tutorials.html and README's "10 tutorials,
# verified by running them" claim): run every 01..10 tutorial script
# through the real binary via docs/tutorial_scripts/run_all.sh and fold
# its pass/fail into this script's own count. Without this, the tutorial
# scripts are real and do pass, but nothing gates them - a change that
# breaks a documented tutorial sequence would only be noticed by a human
# manually re-running run_all.sh, not by smoke.sh or CI.
TUT="$(bash "$HERE/../docs/tutorial_scripts/run_all.sh" "$BIN" 2>&1)" || true
echo "$TUT" | grep -E "^(FAIL|PASS:)"
if echo "$TUT" | grep -q "^FAIL"; then fail=1; fi
TUT_PASS_COUNT=$(echo "$TUT" | grep -c "^PASS:")
[ "$TUT_PASS_COUNT" -eq 10 ] || { echo "FAIL: expected 10/10 tutorial scripts to pass, got $TUT_PASS_COUNT"; fail=1; }

# DwgCompare / XrefCompare / CompareClear QC (compare/DwgCompare.h,
# src/commands/cmd_compare.cpp - see compare_script.txt for the full
# v1-vs-v2 scenario this drives).
sed "s|@TMP@|$TMPW|g" "$HERE/compare_script.txt" > "$TMPW/compare_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  CMP="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/compare_script.txt" 2>&1)" || { echo "$CMP"; echo "FAIL: compare script exited non-zero"; exit 1; }
else
  CMP="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/compare_script.txt" 2>&1)" || { echo "$CMP"; echo "FAIL: compare script exited non-zero"; exit 1; }
fi
cmpcheck() { if echo "$CMP" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$CMP" "$1"; fail=1; fi; }
cmpcheck "Exported $TMPW/cmp_v1.3dm" "compare script saved the v1 baseline"
cmpcheck "Deleted 1 object(s)" "only the old circle was deleted (the moved line stayed selected-clean)"
cmpcheck "DwgCompare: 1 added, 1 removed, 1 modified, 1 unchanged" "DwgCompare landed the moved line as modified, the deleted circle as removed, the untouched polyline as unchanged (not counted as a hit), and the new circle as added"
cmpcheck "CompareClear: 3 object.s. restored/removed" "CompareClear restored the 2 tinted objects and removed the 1 ghost"
echo "$CMP" | grep -q "DwgCompare: 0 added, 0 removed" && { echo "FAIL: DwgCompare produced no diff at all"; fail=1; }

# Activity Log + Named Snapshots persistence (Document::ActivityLog/
# RecordActivityLogEntry, ActivityExport, Document::CaptureSnapshotAsDocument/
# AdoptNamedSnapshotFromDocument + Application's sidecar files - see
# activity_log_script.txt): a create, a move and a delete must each show up
# in the exported CSV with the right label, and a Named Snapshot saved
# before Save must still be listed after New+Open re-reads the file from
# disk (proving both the activity-log sidecar and the snapshot sidecar
# survive a real save/close/reopen, not just the live in-memory session).
sed "s|@TMP@|$TMPW|g" "$HERE/activity_log_script.txt" > "$TMPW/activity_log_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  AL="$(timeout 900 "$BIN" --smoke 40 --script "$TMPW/activity_log_script.txt" 2>&1)" || { echo "$AL"; echo "FAIL: activity-log script exited non-zero"; exit 1; }
else
  AL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 40 --script "$TMPW/activity_log_script.txt" 2>&1)" || { echo "$AL"; echo "FAIL: activity-log script exited non-zero"; exit 1; }
fi
alcheck() { if echo "$AL" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$AL" "$1"; fail=1; fi; }
alcheck "Snapshot 'MySnap' saved" "Snapshots Save created the named snapshot before the file was saved"
alcheck "Saved $TMPW/activity_test.3dm" "Save wrote the .3dm (and, alongside it, the snapshot sidecar)"
alcheck "Opened $TMPW/activity_test.3dm" "Open re-read the .3dm"
alcheck "1 snapshot(s)" "Snapshots List found exactly the one snapshot after New+Open, proving Named Snapshots survive Save/Open"
alcheck "  MySnap" "the reloaded snapshot kept its original name"
alcheck "ActivityExport: " "ActivityExport ran and reported how many entries it wrote"
test -s "$TMPW/activity_export.csv" && echo "ok   activity_export.csv exists" || { echo "FAIL activity_export.csv missing"; fail=1; }
head -1 "$TMPW/activity_export.csv" | grep -q '^Timestamp (UTC),Action,Detail$' && echo "ok   activity_export.csv has the expected CSV header" || { echo "FAIL activity_export.csv header"; fail=1; }
grep -q '"Box"' "$TMPW/activity_export.csv" && echo "ok   activity_export.csv recorded the Box creation" || { echo "FAIL activity_export.csv missing the Box entry"; fail=1; }
grep -q '"Move"' "$TMPW/activity_export.csv" && echo "ok   activity_export.csv recorded the Move edit" || { echo "FAIL activity_export.csv missing the Move entry"; fail=1; }
grep -q '"Delete"' "$TMPW/activity_export.csv" && echo "ok   activity_export.csv recorded the Delete" || { echo "FAIL activity_export.csv missing the Delete entry"; fail=1; }
# The exported log must also include entries recorded *before* this session
# started (i.e. loaded back from the on-disk sidecar log by
# Document::LoadActivityLog after Open, not just this run's own edits) -
# count real per-edit label rows (excluding the header) and require at
# least the 3 edits made above.
[ "$(($(wc -l < "$TMPW/activity_export.csv") - 1))" -ge 3 ] && echo "ok   activity_export.csv has at least the 3 recorded edits" || { echo "FAIL activity_export.csv has too few rows"; fail=1; }
test -s "$TMPW/activity_test.3dm.activity.log" && echo "ok   the durable activity.log sidecar file was written next to the document" || { echo "FAIL activity.log sidecar file missing"; fail=1; }
test -d "$TMPW/activity_test.3dm.snapshots" && echo "ok   the Named Snapshots sidecar directory was written next to the document" || { echo "FAIL snapshots sidecar directory missing"; fail=1; }

# Smart Blocks (SmartBlockDetect/SmartBlockConvert, cmd_smartblocks.cpp):
# scatter 3 occurrences of one shape (one plain, one translated, one
# translated-then-rotated) among unrelated noise, confirm detection finds
# exactly the 3 real occurrences as a single repeated group and ignores the
# noise, then confirm conversion turns all 3 into tagged instances of one
# new block without touching object count or the noise.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SB="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/smartblocks_script.txt" 2>&1)" || { echo "$SB"; echo "FAIL: Smart Blocks script exited non-zero"; exit 1; }
else
  SB="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/smartblocks_script.txt" 2>&1)" || { echo "$SB"; echo "FAIL: Smart Blocks script exited non-zero"; exit 1; }
fi
sbcheck() { if echo "$SB" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SB" "$1"; fail=1; fi; }
echo "$SB" | grep -q "^FAIL expect_" && { echo "FAIL Smart Blocks script's own @expect_objects/@expect_selected checks failed"; fail=1; }
sbcheck "^history: SmartBlockDetect: 1 repeated group(s) found$" "SmartBlockDetect found exactly one repeated group (not 0, not split into several)"
sbcheck "^history:   group 1: 3 instance(s), 3 object(s) each$" "SmartBlockDetect correctly counted 3 occurrences of the 3-object bracket shape, ignoring the noise objects"
sbcheck "^history: SmartBlockConvert: 1 block definition(s) created, 3 instance(s) converted$" "SmartBlockConvert created exactly one new block and converted all 3 detected occurrences"
sbcheck "^ok   expect_objects 13 (got 13)$" "SmartBlockConvert tags occurrences in place rather than replacing them, so the total object count is unchanged"
sbcheck "^ok   expect_selected 9 (got 9)$" "SelBlockInstance selects exactly the 9 objects (3 instances x 3 objects) that were converted, and none of the noise objects"
sbcheck "Block 'SmartBlock1': 3 object(s), base .*, 9 object(s) in instances" "BlockManager confirms the new block's definition has 3 objects and 9 objects across its instances"

# CAD Standards Checker: Standards/CheckStandards (see standards_script.txt).
mkdir -p "$TMPW/standards"
cat > "$TMPW/standards/standards.json" <<'EOS'
{
  "layers": [
    {"name": "Default", "color": "0,0,0", "linetype": "Continuous"},
    {"name": "Dims", "color": "0,0,0", "linetype": "Continuous"},
    {"name": "Notes", "color": "0,0,0", "linetype": "Dashed"}
  ],
  "text_styles": ["Default"],
  "dim_styles": []
}
EOS
sed "s|@TMP@|$TMPW/standards|g" "$HERE/standards_script.txt" > "$TMPW/standards/standards_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  ST="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/standards/standards_script.txt" 2>&1)" || { echo "$ST"; echo "FAIL: standards script exited non-zero"; exit 1; }
else
  ST="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/standards/standards_script.txt" 2>&1)" || { echo "$ST"; echo "FAIL: standards script exited non-zero"; exit 1; }
fi
stcheck() { if echo "$ST" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$ST" "$1"; fail=1; fi; }
stcheck "Standards: document linked to '$TMPW/standards/standards.json'" "Standards linked the document to the standards file"
stcheck "CheckStandards: 0 violations" "CheckStandards reports clean before any drift is introduced"
stcheck "CheckStandards found 3 violation(s)" "CheckStandards found exactly 3 violations after introducing drift"
stcheck "layer 'Extra' is not defined in the standards file" "CheckStandards flagged the undefined layer 'Extra'"
stcheck "layer 'Notes' linetype 'Continuous' does not match the standard 'Dashed'" "CheckStandards flagged the linetype drift on 'Notes'"
stcheck "text/dimension style 'Rogue' is used in the drawing but is not in the standards file" "CheckStandards flagged the non-standard annotation style 'Rogue'"
if echo "$ST" | grep -q "layer 'Dims'"; then echo "FAIL: CheckStandards incorrectly flagged the compliant layer 'Dims'"; fail=1; else echo "ok   compliant layer 'Dims' was not flagged"; fi
if echo "$ST" | grep -q "layer 'Default'"; then echo "FAIL: CheckStandards incorrectly flagged the compliant layer 'Default'"; fail=1; else echo "ok   compliant layer 'Default' was not flagged"; fi
if echo "$ST" | grep -q "style 'Default'"; then echo "FAIL: CheckStandards incorrectly flagged the compliant style 'Default'"; fail=1; else echo "ok   compliant style 'Default' was not flagged"; fi
echo "$ST" | grep -E "^(ok|FAIL)" || true
if echo "$ST" | grep -q "^FAIL"; then fail=1; fi

# Sheet sets (SheetSetNew/Add/Open/Plot - session/SheetSet.h/cmd_sheetset.cpp):
# two small single-layout drawings get added to one sheet set file spanning
# both, then batch-plotted, proving the set genuinely reaches across files
# rather than only listing layouts within the currently-open document (see
# sheetset_script.txt).
sed "s|@TMP@|$TMPW|g" "$HERE/sheetset_script.txt" > "$TMPW/sheetset_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SS="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/sheetset_script.txt" 2>&1)" || { echo "$SS"; echo "FAIL: sheetset script exited non-zero"; exit 1; }
else
  SS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/sheetset_script.txt" 2>&1)" || { echo "$SS"; echo "FAIL: sheetset script exited non-zero"; exit 1; }
fi
sscheck() { if echo "$SS" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$SS" "$1"; fail=1; fi; }
sscheck "SheetSetNew: created 'Smoke Test Set'" "SheetSetNew created the sheet set file"
sscheck "SheetSetAdd: added .*sheetset_b\.3dm / SheetB" "SheetSetAdd added the second document's layout before it was even the open document"
sscheck "SheetSetAdd: added .*sheetset_a\.3dm / SheetA" "SheetSetAdd added the current document's active layout"
sscheck "SheetSetOpen: 'Smoke Test Set' .*, 2 sheet(s)" "SheetSetOpen listed both entries"
sscheck "1\. .*sheetset_b\.3dm : SheetB" "SheetSetOpen listed the first entry (file + layout)"
sscheck "2\. .*sheetset_a\.3dm : SheetA" "SheetSetOpen listed the second entry (file + layout)"
sscheck "SheetSetPlot: 2/2 sheet(s) plotted" "SheetSetPlot batch-plotted every sheet in the set"
for f in "$TMPW/sheetset_out"/*.pdf; do
  [ -s "$f" ] || { echo "FAIL: $f missing or empty"; fail=1; }
done
PDF_COUNT=$(ls "$TMPW/sheetset_out"/*.pdf 2>/dev/null | wc -l)
[ "$PDF_COUNT" -eq 2 ] && echo "ok   SheetSetPlot wrote one PDF per sheet (2 files)" || { echo "FAIL: expected 2 plotted PDFs, found $PDF_COUNT"; fail=1; }
for f in "$TMPW/sheetset_out"/*.pdf; do
  SZ=$(wc -c < "$f")
  [ "$SZ" -gt 200 ] && echo "ok   $(basename "$f") is a non-trivial PDF ($SZ bytes)" || { echo "FAIL: $(basename "$f") is too small ($SZ bytes)"; fail=1; }
  head -c 5 "$f" | grep -q "%PDF-" && echo "ok   $(basename "$f") starts with %PDF-" || { echo "FAIL: $(basename "$f") missing PDF header"; fail=1; }
done

# DataLink / DataLinkUpdate (see datalink_script1..4.txt): a table linked to
# a CSV file two-way syncs with it. Four separate app invocations, sharing
# @TMP@/datalink.3dm on disk, with this script itself playing "someone
# editing the file in a spreadsheet program" between stages 1->2 and
# 3->4 - which a single script/single invocation cannot exercise, since the
# whole point is a file changing *outside* the app between syncs.
run_dl_stage() {
  local script="$1" label="$2"
  sed "s|@TMP@|$TMPW|g" "$HERE/$script" > "$TMPW/$script"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    "$BIN" --smoke 60 --script "$TMPW/$script" 2>&1 || { echo "FAIL: DataLink stage $label exited non-zero"; exit 1; }
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/$script" 2>&1 || { echo "FAIL: DataLink stage $label exited non-zero"; exit 1; }
  fi
}

DL1="$(run_dl_stage datalink_script1.txt 1)"
dlcheck() { if echo "$DL1" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$DL1" "$1"; fail=1; fi; }
dlcheck "DataLink: pushed 2x2 table to " "DataLink pushed the new table to the CSV file (it didn't exist yet)"
[ -f "$TMPW/datalink.csv" ] || { echo "FAIL DataLink actually wrote $TMPW/datalink.csv"; fail=1; }
DL1_CSV="$(cat "$TMPW/datalink.csv" 2>/dev/null || true)"
if [ "$DL1_CSV" = "$(printf 'A,B\nC,D\n')" ]; then echo "ok   the pushed CSV's content matches the table's cells (A,B / C,D)"; else echo "FAIL the pushed CSV's content matches the table's cells (got: $DL1_CSV)"; fail=1; fi

# Simulate an external spreadsheet edit of the linked file before stage 2.
#
# DataLinkUpdate's push/pull direction heuristic compares this file's mtime
# against the *previous* stage's last_sync_utc. A plain write here already
# gives the file a fresh "now" mtime (no explicit touch needed) - the sleep
# just guarantees real separation from the previous stage's last_sync_utc.
# NOTE: forcing the mtime artificially far into the future was tried here
# and reverted - it "fixes" this one comparison but then permanently reads
# as "still changed" in every later stage too, since a pull never rewrites
# the file to give it a fresh, real mtime. A plain write + sleep is the
# correct approach; the real, permanent fix for the two genuine bugs this
# surfaced lives in cmd_drafting2.cpp (NowMillis()'s monotonic ratchet, and
# RebuildWithLink pinning a sync's own table rebuild timestamp to exactly
# last_sync_utc so a sync is never mistaken for a change since itself).
sleep 5
printf 'P,Q\nR,S\n' > "$TMPW/datalink.csv"

DL2="$(run_dl_stage datalink_script2.txt 2)"
dlcheck() { if echo "$DL2" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$DL2" "$1"; fail=1; fi; }
dlcheck "DataLinkUpdate: pulled 2x2 table from " "DataLinkUpdate auto-detected the file was the only side that changed and pulled it"

sleep 5

DL3="$(run_dl_stage datalink_script3.txt 3)"
dlcheck() { if echo "$DL3" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$DL3" "$1"; fail=1; fi; }
dlcheck "DataLinkUpdate: pushed 2x2 table to " "DataLinkUpdate auto-detected the table was the only side that changed (after stage 2's TableEdit) and pushed it - the reverse direction from stage 2"
DL3_CSV="$(cat "$TMPW/datalink.csv" 2>/dev/null || true)"
if [ "$DL3_CSV" = "$(printf 'M,N\nO,P\n')" ]; then echo "ok   the re-pushed CSV's content matches stage 2's TableEdit (M,N / O,P), not the stale P,Q / R,S it pulled"; else echo "FAIL the re-pushed CSV's content matches stage 2's TableEdit (got: $DL3_CSV)"; fail=1; fi

# Simulate a second external edit, so that stage 4's own TableEdit and this
# file both change before the next sync - the ambiguous case.
sleep 5
printf 'Z1,Z2\nZ3,Z4\n' > "$TMPW/datalink.csv"

DL4="$(run_dl_stage datalink_script4.txt 4)"
dlcheck() { if echo "$DL4" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$DL4" "$1"; fail=1; fi; }
dlcheck "! DataLinkUpdate: both the table and .* changed since the last sync" "DataLinkUpdate refused to silently guess a direction when both the table and the file changed since the last sync"
dlcheck "DataLinkUpdate: pushed 2x2 table to " "the follow-up DataLinkUpdate Direction=Push resolved the ambiguity explicitly"
DL4_CSV="$(cat "$TMPW/datalink.csv" 2>/dev/null || true)"
if [ "$DL4_CSV" = "$(printf 'Q,R\nS,T\n')" ]; then echo "ok   Direction=Push wrote the table's edit (Q,R / S,T) to the file, discarding the file's own outside edit as the caller explicitly chose"; else echo "FAIL Direction=Push wrote the table's edit to the file (got: $DL4_CSV)"; fail=1; fi

# DataLink / DataLinkUpdate to a native .xlsx file (drafting/Xlsx.cpp - see
# PARITY_MAP.md's "Live external data linking into tables" entry), not just
# CSV: the same push/external-edit/pull/push shape as the CSV stages above
# (datalink_script1..4.txt), but round-tripping through a real .xlsx,
# independently verified at every stage by Python's own zipfile/xml - never
# this app's own reader - so both directions are checked against a
# genuinely external tool, not just a round trip through this app's own
# writer and reader agreeing with each other.
XDL1="$(run_dl_stage xlsx_datalink_script1.txt "xlsx 1")"
xdlcheck() { if echo "$XDL1" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$XDL1" "$1"; fail=1; fi; }
xdlcheck "DataLink: pushed 2x2 table to " "DataLink pushed the new table to the .xlsx file (it didn't exist yet)"
[ -f "$TMPW/xlsx_datalink.xlsx" ] || { echo "FAIL DataLink actually wrote $TMPW/xlsx_datalink.xlsx"; fail=1; }
head -c 2 "$TMPW/xlsx_datalink.xlsx" | grep -q "PK" && echo "ok   xlsx_datalink.xlsx starts with a real zip signature (PK)" || { echo "FAIL xlsx_datalink.xlsx is not a real zip"; fail=1; }
python3 - "$TMPW/xlsx_datalink.xlsx" <<'PY' && echo "ok   the pushed .xlsx's content matches the table's cells (E,F / G,H), read independently by Python's own zipfile/xml" || { echo "FAIL the pushed .xlsx's content does not match the table's cells"; fail=1; }
import sys, zipfile, xml.etree.ElementTree as ET
ns = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
z = zipfile.ZipFile(sys.argv[1])
root = ET.fromstring(z.read('xl/worksheets/sheet1.xml'))
cells = {}
for c in root.findall('.//m:c', ns):
    if c.get('t') == 'inlineStr':
        cells[c.get('r')] = c.find('m:is/m:t', ns).text or ''
    else:
        v = c.find('m:v', ns)
        cells[c.get('r')] = v.text if v is not None else ''
assert cells.get('A1') == 'E' and cells.get('B1') == 'F', cells
assert cells.get('A2') == 'G' and cells.get('B2') == 'H', cells
PY

# Simulate an external spreadsheet edit of the linked .xlsx - written by
# Python's own zipfile/zlib with real DEFLATE (zip method 8) compression
# and a proper shared-strings table, the shape an actual Excel/LibreOffice/
# openpyxl save produces, not just this app's own inlineStr writer - so
# ReadXlsxCells is proven against a genuinely independent writer, not just
# a round trip through its own.
sleep 5
python3 - "$TMPW/xlsx_datalink.xlsx" <<'PY'
import sys, zipfile
path = sys.argv[1]
content_types = '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/></Types>'
root_rels = '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
workbook = '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
workbook_rels = '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>'
shared = '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4"><si><t>P</t></si><si><t>Q</t></si><si><t>R</t></si><si><t>S</t></si></sst>'
sheet = '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row></sheetData></worksheet>'
z = zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED)
z.writestr('[Content_Types].xml', content_types)
z.writestr('_rels/.rels', root_rels)
z.writestr('xl/workbook.xml', workbook)
z.writestr('xl/_rels/workbook.xml.rels', workbook_rels)
z.writestr('xl/sharedStrings.xml', shared)
z.writestr('xl/worksheets/sheet1.xml', sheet)
z.close()
PY

XDL2="$(run_dl_stage xlsx_datalink_script2.txt "xlsx 2")"
xdlcheck() { if echo "$XDL2" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$XDL2" "$1"; fail=1; fi; }
xdlcheck "DataLinkUpdate: pulled 2x2 table from " "DataLinkUpdate auto-detected the externally-rewritten .xlsx was the only side that changed and pulled it"
xdlcheck '"cells":\["P","Q","R","S"\]' "the pulled table's own TableData cells (P,Q / R,S) match the real DEFLATE-compressed, shared-string-indexed .xlsx Python wrote - not just this app's own writer's output"

sleep 5

XDL3="$(run_dl_stage xlsx_datalink_script3.txt "xlsx 3")"
xdlcheck() { if echo "$XDL3" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$XDL3" "$1"; fail=1; fi; }
xdlcheck "DataLinkUpdate: pushed 2x2 table to " "DataLinkUpdate auto-detected the table (TableEdit) was the only side that changed and pushed it back to the real .xlsx file - the reverse direction from stage 2"
python3 - "$TMPW/xlsx_datalink.xlsx" <<'PY' && echo "ok   the re-pushed .xlsx's content matches stage 3's TableEdit (U,V / W,X), read independently by Python's own zipfile/xml" || { echo "FAIL the re-pushed .xlsx's content does not match stage 3's TableEdit"; fail=1; }
import sys, zipfile, xml.etree.ElementTree as ET
ns = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
z = zipfile.ZipFile(sys.argv[1])
root = ET.fromstring(z.read('xl/worksheets/sheet1.xml'))
cells = {}
for c in root.findall('.//m:c', ns):
    if c.get('t') == 'inlineStr':
        cells[c.get('r')] = c.find('m:is/m:t', ns).text or ''
    else:
        v = c.find('m:v', ns)
        cells[c.get('r')] = v.text if v is not None else ''
assert cells.get('A1') == 'U' and cells.get('B1') == 'V', cells
assert cells.get('A2') == 'W' and cells.get('B2') == 'X', cells
PY

# Real OS-clipboard image write (ViewCaptureToClipboard/ScreenCaptureToClipboard/
# CopyRenderWindowToClipboard - see src/platform/Clipboard.h). There is no
# clipboard reader available in this headless harness, so DINO8_CLIPBOARD_DEBUG_FILE
# is used instead: it makes WriteImageToClipboard also write the exact PNG bytes
# it handed the platform clipboard backend to a file, so the assertions below
# can check for a real, non-trivial PNG rather than just "the command didn't
# crash" (see tests/clipboard_script.txt).
CLIP_DEBUG="$TMPW/clipboard_debug.png"
export DINO8_CLIPBOARD_DEBUG_FILE="$CLIP_DEBUG"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  CB="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/clipboard_script.txt" 2>&1)" || { echo "$CB"; echo "FAIL: clipboard script exited non-zero"; exit 1; }
else
  CB="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/clipboard_script.txt" 2>&1)" || { echo "$CB"; echo "FAIL: clipboard script exited non-zero"; exit 1; }
fi
unset DINO8_CLIPBOARD_DEBUG_FILE
cbcheck() { if echo "$CB" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$CB" "$1"; fail=1; fi; }
cbcheck "CopyRenderWindowToClipboard: [0-9]*x[0-9]* rendering copied to the system clipboard (image/png)" "CopyRenderWindowToClipboard ran the real OS-clipboard write path"
cbcheck "ViewCaptureToClipboard: [0-9]*x[0-9]* image copied to the system clipboard (image/png)" "ViewCaptureToClipboard ran the real OS-clipboard write path"
cbcheck "ScreenCaptureToClipboard: [0-9]*x[0-9]* image copied to the system clipboard (image/png)" "ScreenCaptureToClipboard ran the real OS-clipboard write path"
if [ -s "$CLIP_DEBUG" ]; then
  echo "ok   DINO8_CLIPBOARD_DEBUG_FILE was written"
  CLIP_SIG="$(head -c 8 "$CLIP_DEBUG" | od -An -tx1 | tr -d ' \n')"
  if [ "$CLIP_SIG" = "89504e470d0a1a0a" ]; then echo "ok   clipboard debug file starts with a real PNG signature (89 50 4E 47 0D 0A 1A 0A)"; else echo "FAIL clipboard debug file does not start with a PNG signature (got $CLIP_SIG)"; fail=1; fi
  CLIP_SIZE="$(wc -c < "$CLIP_DEBUG")"
  if [ "$CLIP_SIZE" -gt 1000 ]; then echo "ok   clipboard debug file is a non-trivial size ($CLIP_SIZE bytes)"; else echo "FAIL clipboard debug file is too small to be real image data ($CLIP_SIZE bytes)"; fail=1; fi
else
  echo "FAIL DINO8_CLIPBOARD_DEBUG_FILE was never written"
  fail=1
fi

# History / RecordHistory / UpdateHistory: a real, intentionally-scoped
# constructional-history mechanism (Extrude/ExtrudeCrv, ExtrudeCrvToPoint,
# Revolve, Loft, SubDLoft - see cmd_history.cpp's own header comment and
# tests/history_script.txt's for exactly what this checks). The key
# assertion is a real bounding-box move, not just an object count: after
# History On, Extrude, moving the source curve and running UpdateHistory,
# the extruded surface's bounding box must have actually shifted to match
# the curve's new position - the exact check a fake/no-op implementation
# would fail.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HS="$(timeout 900 "$BIN" --smoke 150 --script "$HERE/history_script.txt" 2>&1)" || { echo "$HS"; echo "FAIL: history script exited non-zero"; exit 1; }
else
  HS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 150 --script "$HERE/history_script.txt" 2>&1)" || { echo "$HS"; echo "FAIL: history script exited non-zero"; exit 1; }
fi
echo "$HS" | grep -E "^(ok|FAIL)"
if echo "$HS" | grep -q "^FAIL"; then fail=1; fi
echo "$HS" | grep -q "^smoke:" || { echo "$HS"; echo "FAIL: history script produced no smoke line"; fail=1; }
hcheck() { if echo "$HS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HS" "$1"; fail=1; fi; }
hcheck "History recording: off. 0 object(s) with live construction history" "History defaults Off and reports it"
hcheck "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry" "an Extrude made while History was Off recorded nothing for UpdateHistory to redo"
hcheck "History recording: on - new results of 23 construction commands (Boolean2Objects/BooleanDifference/BooleanIntersection/BooleanUnion/Extrude/" "History On toggled recording on and now lists the registry-driven set of recordable constructions (was a hand-written 10-name sentence; the registry has 23 names, e.g. Shell, ExtrudeSrf, Offset, OffsetSrf, RailRevolve and the four booleans on top of the old Extrude/ExtrudeCrvToPoint/Revolve/Loft/SubDLoft/Pipe/Sweep1/Sweep2/Patch/NetworkSrf2)"
hcheck "Bounding box min 20,0,0 max 30,0,5" "the freshly-extruded surface's bounding box, before the source curve moves"
hcheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one object History was tracking"
hcheck "Bounding box min 20,0,20 max 30,0,25" "UpdateHistory genuinely re-derived the extruded surface's geometry from the source curve's new z=20 position - not the z=0..5 box baked at creation time"
hcheck "History recording: on. 1 object(s) with live construction history:" "the live report lists exactly one tracked object"
hcheck "object 4: Extrude <- 3" "the report names the real dependent/source pair (surface 4 built from curve 3)"

# ExtrudeCrvToPoint Solid=Yes: RebuildExtrudeToPoint (cmd_solids.cpp) now
# wires a closed, planar, non-self-intersecting profile into
# kernel::Brep::ExtrudeToPoint for a genuine capped B-rep cone instead of
# the old centroid-collapsed ruled surface - see
# extrude_to_point_solid_script.txt's own header comment for exactly what
# this checks, including the pre-existing (not newly broken) app-level
# Volume gap on this topology.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  E2P="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/extrude_to_point_solid_script.txt" 2>&1)" || { echo "$E2P"; echo "FAIL: extrude-to-point-solid script exited non-zero"; exit 1; }
else
  E2P="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/extrude_to_point_solid_script.txt" 2>&1)" || { echo "$E2P"; echo "FAIL: extrude-to-point-solid script exited non-zero"; exit 1; }
fi
echo "$E2P" | grep -E "^(ok|FAIL)"
if echo "$E2P" | grep -q "^FAIL"; then fail=1; fi
echo "$E2P" | grep -q "^smoke:" || { echo "$E2P"; echo "FAIL: extrude-to-point-solid script produced no smoke line"; fail=1; }
e2pcheck() { if echo "$E2P" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$E2P" "$1"; fail=1; fi; }
e2pcheck "Object 2 (polysurface) layer Default" "Solid=Yes on a closed planar rectangle builds a real polysurface, not a degenerate surface"
e2pcheck "2 faces, 3 edges, closed solid" "the built cone is a genuine closed solid (IsSolid), not just visually cone-shaped"
e2pcheck "Object 2: valid" "Check reports the new solid cone as valid"
e2pcheck "Object 4 (surface) layer Default" "Solid=No on the identical curve/apex still falls back to the pre-existing ruled surface, unchanged"
e2pcheck "Object 6 (surface) layer Default" "a non-star-shaped (C-shaped) profile falls back to the ruled surface instead of throwing or crashing when ExtrudeToPoint refuses its flat cap"
e2pcheck "Object 8 (surface) layer Default" "an open curve is unaffected - still the pre-existing ruled surface, since this pass only wires the closed-profile capped-cone case"

# RailRevolve: RailRevolveCommand (cmd_srfedit.cpp) now wires a profile
# planar through the picked axis into kernel::Brep::RailRevolve for a
# genuine B-rep instead of the old approximate curve-through-points fit -
# see railrevolve_solid_script.txt's own header comment for exactly what
# this checks.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RRV="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/railrevolve_solid_script.txt" 2>&1)" || { echo "$RRV"; echo "FAIL: railrevolve-solid script exited non-zero"; exit 1; }
else
  RRV="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/railrevolve_solid_script.txt" 2>&1)" || { echo "$RRV"; echo "FAIL: railrevolve-solid script exited non-zero"; exit 1; }
fi
echo "$RRV" | grep -E "^(ok|FAIL)"
if echo "$RRV" | grep -q "^FAIL"; then fail=1; fi
echo "$RRV" | grep -q "^smoke:" || { echo "$RRV"; echo "FAIL: railrevolve-solid script produced no smoke line"; fail=1; }
rrvcheck() { if echo "$RRV" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RRV" "$1"; fail=1; fi; }
rrvcheck_re() { if echo "$RRV" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RRV" "$1"; fail=1; fi; }
rrvcheck "RailRevolve: genuine B-rep solid/shell built (profile planar through the picked axis)" "a profile planar through the picked axis hits the new kernel::Brep::RailRevolve path"
rrvcheck "Object 3 (polysurface) layer Default" "the result is a real polysurface, not a degenerate approximate surface"
rrvcheck "1 faces, 2 edges, closed solid" "a closed off-axis profile with a constant-radius rail builds a genuine closed solid (doubly-periodic single face, torus topology)"
rrvcheck "Object 3: valid" "Check reports the new solid as valid"
rrvcheck_re "Volume = 224\.[67] cubic Millimeters" "Volume measures the new solid directly - no apex/seam mesh-closure gap on this topology, unlike ExtrudeCrvToPoint's own cone"
rrvcheck "RailRevolve: surface created (profile scaled radially to follow the rail)" "an axis outside the profile's own plane falls back to the pre-existing approximate surface, unchanged"
rrvcheck "Object 6 (surface) layer Default" "the fallback result is still the pre-existing approximate surface kind, not a Brep"

# Revolve Angle/StartAngle: RevolveCommand (cmd_solids.cpp) now exposes
# both options (previously unavailable anywhere in the app) and routes a
# genuinely non-default combination through kernel::Brep::Revolve - see
# revolve_angle_script.txt's own header comment for exactly what this
# checks, including the pre-existing partial-angle-cap Volume gap it
# shares with ExtrudeCrvToPoint's own cone.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RAS="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/revolve_angle_script.txt" 2>&1)" || { echo "$RAS"; echo "FAIL: revolve-angle script exited non-zero"; exit 1; }
else
  RAS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/revolve_angle_script.txt" 2>&1)" || { echo "$RAS"; echo "FAIL: revolve-angle script exited non-zero"; exit 1; }
fi
echo "$RAS" | grep -E "^(ok|FAIL)"
if echo "$RAS" | grep -q "^FAIL"; then fail=1; fi
echo "$RAS" | grep -q "^smoke:" || { echo "$RAS"; echo "FAIL: revolve-angle script produced no smoke line"; fail=1; }
rascheck() { if echo "$RAS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RAS" "$1"; fail=1; fi; }
rascheck_re() { if echo "$RAS" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RAS" "$1"; fail=1; fi; }
rascheck "3 faces, 5 edges, closed solid" "Angle=90 on a closed off-axis profile builds a real capped solid via kernel::Brep::Revolve (wall + 2 pie-slice caps)"
rascheck "Object 4: valid" "Check reports the partial-angle solid as valid"
rascheck_re "Volume = 149\.[12] cubic Millimeters" "StartAngle=45 at full angle (torus topology, no cap-adjacent mesh gap) measures correctly"

# History extended to a sixth command, Pipe (PipeCommand, cmd_surface.cpp;
# RebuildPipe, history_rebuild.h) - see history_pipe_script.txt's own
# header comment for exactly what this checks. Same real-bounding-box-move
# money check as the Extrude case above, not just an object count.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HSP="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_pipe_script.txt" 2>&1)" || { echo "$HSP"; echo "FAIL: history-pipe script exited non-zero"; exit 1; }
else
  HSP="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_pipe_script.txt" 2>&1)" || { echo "$HSP"; echo "FAIL: history-pipe script exited non-zero"; exit 1; }
fi
echo "$HSP" | grep -E "^(ok|FAIL)"
if echo "$HSP" | grep -q "^FAIL"; then fail=1; fi
echo "$HSP" | grep -q "^smoke:" || { echo "$HSP"; echo "FAIL: history-pipe script produced no smoke line"; fail=1; }
hspcheck() { if echo "$HSP" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HSP" "$1"; fail=1; fi; }
hspcheck "object 2: Pipe <- 1" "History tracks a Pipe result (object 2) built from its rail curve (object 1)"
hspcheck "Bounding box min 0,-1,-1 max 10,1,1" "the freshly-built pipe's bounding box, before the rail curve moves"
hspcheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Pipe History was tracking"
hspcheck "Bounding box min 0,-1,4 max 10,1,6" "UpdateHistory genuinely re-derived the pipe's geometry from the rail curve's new z=5 position - not the z=-1..1 mesh baked at creation time"

# History extended to a seventh command, Sweep1's single-cross-section case
# (Sweep1Command, cmd_surface.cpp; RebuildSweep1, history_rebuild.h) - see
# history_sweep1_script.txt's own header comment for exactly what this
# checks. Same real-bounding-box-move money check as Extrude/Pipe above.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HSS="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_sweep1_script.txt" 2>&1)" || { echo "$HSS"; echo "FAIL: history-sweep1 script exited non-zero"; exit 1; }
else
  HSS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_sweep1_script.txt" 2>&1)" || { echo "$HSS"; echo "FAIL: history-sweep1 script exited non-zero"; exit 1; }
fi
echo "$HSS" | grep -E "^(ok|FAIL)"
if echo "$HSS" | grep -q "^FAIL"; then fail=1; fi
echo "$HSS" | grep -q "^smoke:" || { echo "$HSS"; echo "FAIL: history-sweep1 script produced no smoke line"; fail=1; }
hsscheck() { if echo "$HSS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HSS" "$1"; fail=1; fi; }
hsscheck "object 3: Sweep1 <- 1,2" "History tracks a Sweep1 result (object 3) built from its rail (object 1) and section (object 2)"
hsscheck "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" "the freshly-built sweep's bounding box, before the section curve moves"
hsscheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Sweep1 History was tracking"
hsscount() { local n; n="$(echo "$HSS" | grep -cF "$1" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HSS" "$1"; fail=1; fi; }
hsscount "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" 2 "after the section slid +5 in Z (to half way along the rail) UpdateHistory's rebuilt sweep still covers the rail's own z=0..10 extent - the old rigid-from-rail-start result was z=5..15, overshooting the rail's end by 5 (this line and the freshly-built one above)"
hsscheck "Sweep1: the section sits 50.0% along the rail; the rail was split there and both sides swept from the section and joined; the result reproduces the section to " "the rebuild reports where it found the section (50.0% along the rail) and that the joined two-sided sweep reproduces it"
hsscheck "Bounding box min 2.093,-0.978,0 max 4,0.978,10" "UpdateHistory genuinely re-derived the swept surface's geometry from the section curve's new +3 x offset (x: -0.9073..1 became 2.093..4, z still the rail's 0..10) - not the surface baked at creation time"

# History extended to an eighth command, Sweep2's single-cross-section case
# (Sweep2Command, cmd_surface.cpp; RebuildSweep2, history_rebuild.h) - see
# history_sweep2_script.txt's own header comment for exactly what this
# checks. Same real-bounding-box-move money check as Sweep1 above.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HS2="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_sweep2_script.txt" 2>&1)" || { echo "$HS2"; echo "FAIL: history-sweep2 script exited non-zero"; exit 1; }
else
  HS2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_sweep2_script.txt" 2>&1)" || { echo "$HS2"; echo "FAIL: history-sweep2 script exited non-zero"; exit 1; }
fi
echo "$HS2" | grep -E "^(ok|FAIL)"
if echo "$HS2" | grep -q "^FAIL"; then fail=1; fi
echo "$HS2" | grep -q "^smoke:" || { echo "$HS2"; echo "FAIL: history-sweep2 script produced no smoke line"; fail=1; }
hs2check() { if echo "$HS2" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HS2" "$1"; fail=1; fi; }
hs2check "object 4: Sweep2 <- 1,2,3" "History tracks a Sweep2 result (object 4) built from its two rails (objects 1,2) and section (object 3)"
hs2check "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" "the freshly-built sweep's bounding box, before the section curve moves"
hs2check "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Sweep2 History was tracking"
hs2count() { local n; n="$(echo "$HS2" | grep -cF "$1" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HS2" "$1"; fail=1; fi; }
hs2count "Bounding box min -0.9073,-0.978,0 max 1,0.978,10" 2 "after the section slid +5 in Z (to half way along both rails) UpdateHistory's rebuilt sweep still covers the rails' own z=0..10 extent - the old rigid-from-rail-start result was z=5..15 (this line and the freshly-built one above)"
hs2check "Sweep2: the section sits 50.0% along rail 1 and 50.0% along rail 2; both rails were split there and both sides swept from the section and joined; the result reproduces the section to " "the rebuild reports where it found the section (50.0% along both rails) and that the joined two-sided sweep reproduces it"
hs2check "Bounding box min 2.093,-0.978,0 max 4,0.978,10" "UpdateHistory genuinely re-derived the swept surface's geometry from the section curve's new +3 x offset (x: -0.9073..1 became 2.093..4, z still the rails' 0..10) - not the surface baked at creation time"

# History extended to a ninth command, Patch's single-closed-planar-curve
# case (the free Patch function, cmd_surface.cpp; RebuildPatch,
# history_rebuild.h) - see history_patch_script.txt's own header comment
# for exactly what this checks. Same real-bounding-box-move money check as
# Pipe/Sweep1/Sweep2 above; the result is a flat Brep, so (like
# history_script.txt's own flat Extrude case) BoundingBox never adds an
# extra box object for it.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HPA="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_patch_script.txt" 2>&1)" || { echo "$HPA"; echo "FAIL: history-patch script exited non-zero"; exit 1; }
else
  HPA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_patch_script.txt" 2>&1)" || { echo "$HPA"; echo "FAIL: history-patch script exited non-zero"; exit 1; }
fi
echo "$HPA" | grep -E "^(ok|FAIL)"
if echo "$HPA" | grep -q "^FAIL"; then fail=1; fi
echo "$HPA" | grep -q "^smoke:" || { echo "$HPA"; echo "FAIL: history-patch script produced no smoke line"; fail=1; }
hpacheck() { if echo "$HPA" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HPA" "$1"; fail=1; fi; }
hpacheck "object 2: Patch <- 1" "History tracks a Patch result (object 2) built from its closed curve (object 1)"
hpacheck "Bounding box min -5,-5,0 max 5,5,0" "the freshly-patched circle's exact bounding box, before the source curve moves"
hpacheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one Patch History was tracking"
hpacheck "Bounding box min -5,-5,5 max 5,5,5" "UpdateHistory genuinely re-derived the patched face's geometry from the source circle's new z=5 position - not the z=0 flat face baked at creation time"

# History extended to a tenth command, NetworkSrf's 2-curve ruled-surface
# case (the free NetworkSrf function, cmd_surface.cpp; RebuildNetworkSrf2,
# history_rebuild.h) - see history_networksrf_script.txt's own header
# comment for exactly what this checks. Same real-bounding-box-move money
# check as Pipe/Sweep1/Sweep2/Patch above (a flat ruled surface between
# two ground-plane lines, max z 0 -> 5 once the first line moves).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HNS="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_networksrf_script.txt" 2>&1)" || { echo "$HNS"; echo "FAIL: history-networksrf script exited non-zero"; exit 1; }
else
  HNS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_networksrf_script.txt" 2>&1)" || { echo "$HNS"; echo "FAIL: history-networksrf script exited non-zero"; exit 1; }
fi
echo "$HNS" | grep -E "^(ok|FAIL)"
if echo "$HNS" | grep -q "^FAIL"; then fail=1; fi
echo "$HNS" | grep -q "^smoke:" || { echo "$HNS"; echo "FAIL: history-networksrf script produced no smoke line"; fail=1; }
hnscheck() { if echo "$HNS" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HNS" "$1"; fail=1; fi; }
hnscheck "object 3: NetworkSrf2 <- 1,2" "History tracks a NetworkSrf2 result (object 3) built from its two source lines (objects 1,2)"
hnscheck "Bounding box min 0,0,0 max 10,10,0" "the freshly-ruled surface's exact bounding box, before either source line moves"
hnscheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" "UpdateHistory found and rebuilt exactly the one NetworkSrf2 History was tracking"
hnscheck "Bounding box min 0,0,0 max 10,10,5" "UpdateHistory genuinely re-derived the ruled surface's geometry from source line 1's new z=5 position - not the flat z=0 surface baked at creation time"

# RecordMacro: a real action recorder for the Macro Editor's buffer (see
# record_macro_script.txt's own header comment for exactly what this
# checks) - PARITY_MAP.md's "VBA-style macro recorder and editor" item.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RMAC="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/record_macro_script.txt" 2>&1)" || { echo "$RMAC"; echo "FAIL: record-macro script exited non-zero"; exit 1; }
else
  RMAC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/record_macro_script.txt" 2>&1)" || { echo "$RMAC"; echo "FAIL: record-macro script exited non-zero"; exit 1; }
fi
echo "$RMAC" | grep -E "^(ok|FAIL)"
if echo "$RMAC" | grep -q "^FAIL"; then fail=1; fi
echo "$RMAC" | grep -q "^smoke:" || { echo "$RMAC"; echo "FAIL: record-macro script produced no smoke line"; fail=1; }
rmaccheck() { if echo "$RMAC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RMAC" "$1"; fail=1; fi; }
rmaccheck "Macro recording: off (type On to start). Buffer:" "RecordMacro with no argument reports Off and dumps the buffer before anything was recorded"
rmaccheck "Macro recording: on - every command line you type is appended to the Macro Editor's buffer" "RecordMacro On reports the state changed"
rmaccheck "  Line 0,0,0 10,0,0" "the Line command typed while recording was on was appended to the buffer verbatim"
rmaccheck "  Box 20,0,0 25,5,5 5" "the Box command typed while recording was on was appended to the buffer verbatim, in order after Line"
RMAC_LINE50_COUNT="$(echo "$RMAC" | grep -cF "Line 50,0,0 60,0,0" || true)"
[ "$RMAC_LINE50_COUNT" = "1" ] && echo "ok   the Line command typed AFTER RecordMacro Off was run but NOT appended to the buffer (it appears exactly once, as the typed command line itself, not a second time in the final dump)" || { echo "FAIL a command typed after RecordMacro Off leaked into the buffer (expected 1 occurrence, got $RMAC_LINE50_COUNT)"; fail=1; }
RMAC_SELF_COUNT="$(echo "$RMAC" | grep -cF "  RecordMacro" || true)"
[ "$RMAC_SELF_COUNT" = "0" ] && echo "ok   RecordMacro never recorded itself into its own buffer" || { echo "FAIL RecordMacro recorded one of its own toggle lines into the buffer"; fail=1; }

# Named macro library (MacroSave/MacroLoad/MacroDelete/RunSavedMacro,
# cmd_misc.cpp) - see macro_library_script.txt's own header comment for
# exactly what this checks - PARITY_MAP.md's "VBA-style macro recorder and
# editor" item, the "only one macro could ever be kept at a time" half.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  MLIB="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/macro_library_script.txt" 2>&1)" || { echo "$MLIB"; echo "FAIL: macro-library script exited non-zero"; exit 1; }
else
  MLIB="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/macro_library_script.txt" 2>&1)" || { echo "$MLIB"; echo "FAIL: macro-library script exited non-zero"; exit 1; }
fi
echo "$MLIB" | grep -E "^(ok|FAIL)"
if echo "$MLIB" | grep -q "^FAIL"; then fail=1; fi
echo "$MLIB" | grep -q "^smoke:" || { echo "$MLIB"; echo "FAIL: macro-library script produced no smoke line"; fail=1; }
mlibcheck() { if echo "$MLIB" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$MLIB" "$1"; fail=1; fi; }
mlibcheck "Saved macro 'saved macro'" "MacroSave confirms the name, including a space, round-tripped through Tokenize's quoting"
mlibcheck "Bounding box min 20,0,0 max 25,5,5" "RunSavedMacro really executed its saved Box line - SelLast's real geometry, not just a printed confirmation, and immune to how many other lines the shared buffer happened to carry in from an earlier script in this same smoke.sh run"
mlibcheck "  Line 0,0,0 10,0,0" "RunSavedMacro/MacroLoad's effect is visible via the buffer dump, starting with the saved Line text"
mlibcheck "  Box 20,0,0 25,5,5 5" "the saved macro's second recorded line"
MLIB_CIRCLE_IN_DUMP="$(echo "$MLIB" | grep -cF "  Circle 50,0,0 5" || true)"
[ "$MLIB_CIRCLE_IN_DUMP" = "0" ] && echo "ok   the buffer dump after MacroLoad shows the saved snapshot, not the Circle line typed into the live buffer after MacroSave ran" || { echo "FAIL MacroLoad did not actually restore the saved snapshot - the later Circle edit leaked through"; fail=1; }
mlibcheck "Loaded macro 'saved macro' into the Macro Editor buffer" "MacroLoad's own confirmation"
mlibcheck "Deleted macro 'saved macro'" "MacroDelete's own confirmation"
mlibcheck "MacroDelete: no saved macro named 'saved macro'" "deleting an already-deleted name warns instead of silently no-oping"
mlibcheck "RunSavedMacro: no saved macro named 'saved macro'" "running a deleted name warns instead of silently doing nothing or crashing"
mlibcheck "MacroLoad: no saved macro named 'saved macro'" "loading a deleted name warns instead of silently clearing the buffer"

# Alias targets that are real command lines (CommandEngine::Execute's new
# "!Find(name) && (space or ';')" branch) - see alias_macro_script.txt's
# own header comment for exactly what this checks and why it used to be
# silently broken rather than merely narrow. PARITY_MAP.md "Command
# aliases and shortcut customization" (the fix itself) and "VBA-style
# macro recorder and editor" (the "bind a saved macro to an alias" half
# this fix also closes).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  AMAC="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/alias_macro_script.txt" 2>&1)" || { echo "$AMAC"; echo "FAIL: alias-macro script exited non-zero"; exit 1; }
else
  AMAC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/alias_macro_script.txt" 2>&1)" || { echo "$AMAC"; echo "FAIL: alias-macro script exited non-zero"; exit 1; }
fi
echo "$AMAC" | grep -E "^(ok|FAIL)"
if echo "$AMAC" | grep -q "^FAIL"; then fail=1; fi
echo "$AMAC" | grep -q "^smoke:" || { echo "$AMAC"; echo "FAIL: alias-macro script produced no smoke line"; fail=1; }
amaccheck() { if echo "$AMAC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$AMAC" "$1"; fail=1; fi; }
amaccheck "Alias ln1 -> Line 0,0,0 10,0,0" "a multi-word alias target is captured verbatim, args included"
amaccheck "Command: Line 0,0,0 10,0,0" "invoking the alias really runs its full target line (used to fail with Unknown command before this fix), proven by the real object it creates (expect_objects just above)"
amaccheck "Command: Line 20,0,0 30,0,0" "a ';'-separated multi-command alias runs its first command"
amaccheck "Command: Circle 40,0,0 5" "...and its second command, in order"
amaccheck "Command: RunSavedMacro mymac" "a saved macro, bound to an alias, really runs when the alias is invoked"
amaccheck "Bounding box min 50,0,0 max 55,5,5" "the alias-bound macro's own replayed Box is real, freshly-created geometry (SelLast), not a stale object or a printed-only confirmation"
amaccheck "Added 'runmac1' to the Standard toolbar" "a macro-bound alias (not just a bare command name) can now go on a toolbar button via AddToolbarCommand - the toolbar half of the same fix"

# BlockSetArraySpacing/BlockSetArrayCount command-line wiring: PARITY_MAP.md
# "Dynamic blocks" Array parameter/action (the Document-level math itself is
# unit-tested directly in dino8_block_array/test_block_array.cpp) - see
# block_array_script.txt's own header comment.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BAR="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/block_array_script.txt" 2>&1)" || { echo "$BAR"; echo "FAIL: block-array script exited non-zero"; exit 1; }
else
  BAR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/block_array_script.txt" 2>&1)" || { echo "$BAR"; echo "FAIL: block-array script exited non-zero"; exit 1; }
fi
echo "$BAR" | grep -E "^(ok|FAIL)" || true
if echo "$BAR" | grep -q "^FAIL"; then fail=1; fi
echo "$BAR" | grep -q "^smoke:" || { echo "$BAR"; echo "FAIL: block-array script produced no smoke line"; fail=1; }
barcheck() { if echo "$BAR" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BAR" "$1"; fail=1; fi; }
barcheck "  1,0,0" "the block-defining leftover instance (created before BlockAddState/BlockSetArraySpacing ran) keeps its untouched original point"
barcheck "  11,0,0" "array copy 0 lands at the plain insert point (local 1,0,0 + insert 10,0,0)"
barcheck "  16,0,0" "array copy 1 is stepped 5 units along X from copy 0, not stacked on top of it"
barcheck "  21,0,0" "array copy 2 is stepped 10 units along X from copy 0"

# BlockSetLookupTable/BlockSetLookup command-line wiring: PARITY_MAP.md
# "Dynamic blocks" Lookup parameter/action - the fourth and last of the
# four named parameter/action types, after Visibility states, Flip and
# Array above (the Document-level math itself is unit-tested directly in
# dino8_block_lookup/test_block_lookup.cpp) - see block_lookup_script.txt's
# own header comment.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BLK="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/block_lookup_script.txt" 2>&1)" || { echo "$BLK"; echo "FAIL: block-lookup script exited non-zero"; exit 1; }
else
  BLK="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/block_lookup_script.txt" 2>&1)" || { echo "$BLK"; echo "FAIL: block-lookup script exited non-zero"; exit 1; }
fi
echo "$BLK" | grep -E "^(ok|FAIL)" || true
if echo "$BLK" | grep -q "^FAIL"; then fail=1; fi
echo "$BLK" | grep -q "^smoke:" || { echo "$BLK"; echo "FAIL: block-lookup script produced no smoke line"; fail=1; }
blkcheck() { if echo "$BLK" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BLK" "$1"; fail=1; fi; }
blkcheck "  12,0,0" "lookup key 'L' switches the instance to state Large: local (2,0,0) + insert (10,0,0) = (12,0,0)"
blkcheck "  11,0,0" "an unmatched lookup key falls back to the instance's own explicit state (Small): local (1,0,0) + insert (10,0,0) = (11,0,0)"

# BlockSetStretchAxis/BlockSetStretchGroup/BlockSetStretch command-line
# wiring: PARITY_MAP.md "Dynamic blocks" Stretch parameter/action - the
# fifth and last of the five named parameter/action types, after
# Visibility states, Flip, Array and Lookup above (the Document-level math
# itself is unit-tested directly in dino8_test_block_stretch/
# test_block_stretch.cpp) - see block_stretch_script.txt's own header
# comment.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  BST="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/block_stretch_script.txt" 2>&1)" || { echo "$BST"; echo "FAIL: block-stretch script exited non-zero"; exit 1; }
else
  BST="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/block_stretch_script.txt" 2>&1)" || { echo "$BST"; echo "FAIL: block-stretch script exited non-zero"; exit 1; }
fi
echo "$BST" | grep -E "^(ok|FAIL)" || true
if echo "$BST" | grep -q "^FAIL"; then fail=1; fi
echo "$BST" | grep -q "^smoke:" || { echo "$BST"; echo "FAIL: block-stretch script produced no smoke line"; fail=1; }
bstcheck() { if echo "$BST" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BST" "$1"; fail=1; fi; }
bstcheck "  2,0,0" "the block-defining leftover instance (created before BlockAddState/BlockSetStretchAxis ran) keeps its untouched original tagged point"
bstcheck "  -3,0,0" "...and its untouched original untagged point"
bstcheck "  106,0,0" "the placed instance's tagged point moved 4 units along the stretch axis: local (2,0,0) + insert (100,0,0) + stretch 4 = (106,0,0)"
bstcheck "  97,0,0" "the placed instance's untagged point is unaffected by the same stretch: local (-3,0,0) + insert (100,0,0) = (97,0,0)"

# LayerPlotColor command-line wiring: PARITY_MAP.md "Print and plot output"
# item - the color half of "plot styles (CTB/STB)", alongside
# print_width_mm/LayerPrintWidth's lineweight half (the pure
# EffectivePlotColor function itself is unit-tested directly in
# dino8_plot_color/test_plot_color.cpp) - see plot_color_script.txt's own
# header comment. Checked directly against the real exported SVG files'
# stroke colors, not just a printed command confirmation.
sed "s|@TMP@|$TMPW|g" "$HERE/plot_color_script.txt" > "$TMPW/plot_color_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PLC="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/plot_color_script.txt" 2>&1)" || { echo "$PLC"; echo "FAIL: plot-color script exited non-zero"; exit 1; }
else
  PLC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/plot_color_script.txt" 2>&1)" || { echo "$PLC"; echo "FAIL: plot-color script exited non-zero"; exit 1; }
fi
echo "$PLC" | grep -E "^(ok|FAIL)" || true
if echo "$PLC" | grep -q "^FAIL"; then fail=1; fi
grep -q 'stroke="#000000"' "$TMPW/plot_color_off.svg" && echo "ok   with no plot color override, the exported SVG strokes the line in its own display color (black)" || { echo "FAIL plot_color_off.svg does not stroke black"; fail=1; }
grep -q 'stroke="#ff0000"' "$TMPW/plot_color_on.svg" && echo "ok   LayerPlotColor 255,0,0 makes the exported SVG stroke the line red, not its unchanged on-screen display color" || { echo "FAIL plot_color_on.svg does not stroke red"; fail=1; }
grep -q 'stroke="#000000"' "$TMPW/plot_color_cleared.svg" && echo "ok   LayerPlotColor ByLayer clears the override back to the display color (black)" || { echo "FAIL plot_color_cleared.svg does not stroke black again after clearing"; fail=1; }

# PlotStyleTable/LayerPlotStyle command-line wiring: PARITY_MAP.md "Print
# and plot output" item - the named, reusable CTB/STB-table half of "plot
# styles", alongside LayerPlotColor's own flat per-layer-only field just
# above (the pure ResolvePlotStyle/EffectivePlotColor overloads themselves
# are unit-tested directly in dino8_plot_style/test_plot_style.cpp) - see
# plot_style_script.txt's own header comment. Checked directly against the
# real exported SVG files' stroke colors, same as the LayerPlotColor check
# above, specifically proving two layers sharing one named style change
# together when the style's own row is edited.
sed "s|@TMP@|$TMPW|g" "$HERE/plot_style_script.txt" > "$TMPW/plot_style_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PST="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/plot_style_script.txt" 2>&1)" || { echo "$PST"; echo "FAIL: plot-style script exited non-zero"; exit 1; }
else
  PST="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/plot_style_script.txt" 2>&1)" || { echo "$PST"; echo "FAIL: plot-style script exited non-zero"; exit 1; }
fi
echo "$PST" | grep -E "^(ok|FAIL)" || true
if echo "$PST" | grep -q "^FAIL"; then fail=1; fi
RED_COUNT="$(grep -c 'stroke="#ff0000"' "$TMPW/plot_style_red.svg" || true)"
[ "$RED_COUNT" = "2" ] && echo "ok   both layers' lines stroke the named style's own red, though neither layer's own flat plot color was ever set" || { echo "FAIL plot_style_red.svg: expected 2 red strokes (one per layer sharing the style), got $RED_COUNT"; fail=1; }
BLUE_COUNT="$(grep -c 'stroke="#0000ff"' "$TMPW/plot_style_blue.svg" || true)"
[ "$BLUE_COUNT" = "2" ] && echo "ok   editing the shared style's color to blue changes both layers' lines together, with neither layer touched again" || { echo "FAIL plot_style_blue.svg: expected 2 blue strokes, got $BLUE_COUNT"; fail=1; }
grep -q 'stroke="#000000"' "$TMPW/plot_style_cleared.svg" && echo "ok   LayerPlotStyle None on the Default layer clears it back to its own display color (black)" || { echo "FAIL plot_style_cleared.svg: Default layer's line is not black after clearing its style"; fail=1; }
grep -q 'stroke="#0000ff"' "$TMPW/plot_style_cleared.svg" && echo "ok   ...while SecondLayer, never cleared, still strokes the shared style's current color (blue)" || { echo "FAIL plot_style_cleared.svg: SecondLayer's line lost its still-assigned style's color"; fail=1; }
# Transparency (PlotStyle::transparency, the third real CTB/STB plot-style
# column - no flat per-layer equivalent, so only reachable through a named
# style): Mono's own transparency set to 50% must halve the stroke-opacity
# of both layers sharing it in the exported SVG, and the exported PDF must
# carry a real ExtGState resource switched in via "gs" before the stroked
# content, not just a printed confirmation.
OPACITY_COUNT="$(grep -c 'stroke-opacity="0.5"' "$TMPW/plot_style_transparent.svg" || true)"
[ "$OPACITY_COUNT" = "2" ] && echo "ok   PlotStyleTable's optional 4th token (50% transparency) halves both layers' stroke-opacity to 0.5 in the exported SVG" || { echo "FAIL plot_style_transparent.svg: expected 2 stroke-opacity=\"0.5\" groups (one per layer sharing the style), got $OPACITY_COUNT"; fail=1; }
grep -aq '/ExtGState' "$TMPW/plot_style_transparent.pdf" && echo "ok   plot_style_transparent.pdf's page carries a real /ExtGState resource dict, not just a printed confirmation" || { echo "FAIL plot_style_transparent.pdf: no /ExtGState resource"; fail=1; }
grep -aq '/CA 0.5' "$TMPW/plot_style_transparent.pdf" && echo "ok   the ExtGState's own /CA (stroking alpha) is 0.5, matching the style's 50% transparency" || { echo "FAIL plot_style_transparent.pdf: no /CA 0.5 ExtGState"; fail=1; }
grep -aq '/GS1 gs' "$TMPW/plot_style_transparent.pdf" && echo "ok   the content stream switches the ExtGState in with a real \"gs\" operator before the stroked paths" || { echo "FAIL plot_style_transparent.pdf: no /GS1 gs operator in the content stream"; fail=1; }
# Linetype override (PlotStyle::linetype, the fourth and last real CTB/STB
# column this bullet named as missing): LinetypeLayer's line is really on
# the "Dashed" (5,3) linetype, but its own style (LTStyle) names "Hidden"
# (2,2) - the exported SVG must carry the STYLE's own dasharray, not the
# object's real one, and clearing the style's linetype column (PlotStyleTable
# re-saved without that token) must revert it back to the object's own.
grep -q 'stroke-dasharray="2,2"' "$TMPW/plot_style_linetype_override.svg" && echo "ok   a named style's own linetype override (Hidden, 2,2) drives the exported dasharray, not the object's own real linetype (Dashed, 5,3)" || { echo "FAIL plot_style_linetype_override.svg: expected a 2,2 dasharray from the style's own linetype override"; fail=1; }
grep -q 'stroke-dasharray="5,3"' "$TMPW/plot_style_linetype_cleared.svg" && echo "ok   clearing the style's own linetype column (PlotStyleTable re-saved without that token) reverts the same line to its own real linetype (Dashed, 5,3)" || { echo "FAIL plot_style_linetype_cleared.svg: expected the object's own 5,3 dasharray once the style's override was cleared"; fail=1; }
echo "$PST" | grep -qF "PlotStyle 'LTStyle': color ByLayer, width 0.5 mm, transparency 0%, linetype Hidden, screening 100%" && echo "ok   the linetype column survives a real Save/Open round trip through the native .3dm file (Dino8.PlotStyle.<name> user string, io/File3dm.cpp), not just kept in memory for this one process" || { echo "FAIL PlotStyleTable's own linetype column did not survive a real .3dm Save/Open round trip"; fail=1; }
# Screening (PlotStyle::screening, the fifth and last real CTB/STB column):
# ScreenStyle's own color is pure black and its screening column is 50% -
# the exported SVG must stroke exact mid-gray (#808080), not black, and
# re-saving the style with the screening token omitted (the same "one-shot,
# set every field" convention transparency/linetype above already have)
# must revert the same line to full black.
grep -q 'stroke="#808080"' "$TMPW/plot_style_screening_on.svg" && echo "ok   a named style's own 50% screening lightens its black color to exact mid-gray (#808080) in the exported SVG, not a see-through alpha blend" || { echo "FAIL plot_style_screening_on.svg: expected a #808080 stroke from the style's own 50% screening"; fail=1; }
grep -q 'stroke="#000000"' "$TMPW/plot_style_screening_cleared.svg" && echo "ok   clearing the style's own screening column (PlotStyleTable re-saved without that token, resetting to 100%) reverts the same line to full black" || { echo "FAIL plot_style_screening_cleared.svg: expected a #000000 stroke once the style's screening was cleared"; fail=1; }

# Print/Export linetype (dash pattern) wiring: PARITY_MAP.md "Print and
# plot output" item - ExportSvg/ExportPdf (io/FileExchange.cpp) now carry
# each curve's own real linetype through to a real vector dasharray/d
# operator, independent of the on-screen-only "Linetype Display" toggle
# (see dash_export_script.txt's own header comment for the real bug this
# fixes: the old behavior silently depended on that cosmetic toggle).
# Checked directly against the real exported SVG/PDF files, with an exact
# forced Scale=1 from a Top (parallel) view so the expected values are
# exact, not fit-to-page-dependent.
sed "s|@TMP@|$TMPW|g" "$HERE/dash_export_script.txt" > "$TMPW/dash_export_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  DES="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/dash_export_script.txt" 2>&1)" || { echo "$DES"; echo "FAIL: dash-export script exited non-zero"; exit 1; }
else
  DES="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/dash_export_script.txt" 2>&1)" || { echo "$DES"; echo "FAIL: dash-export script exited non-zero"; exit 1; }
fi
echo "$DES" | grep -E "^(ok|FAIL)" || true
if echo "$DES" | grep -q "^FAIL"; then fail=1; fi
grep -q 'stroke-dasharray="5,3"' "$TMPW/dash_scale1.svg" && echo "ok   a dashed line's real linetype (5,3) is exported as a real SVG stroke-dasharray, not a silently solid stroke, even with on-screen Linetype Display off" || { echo "FAIL dash_scale1.svg: no stroke-dasharray=\"5,3\""; fail=1; }
grep -aq '\[14.173 8.504\] 0 d' "$TMPW/dash_scale1.pdf" && echo "ok   the same linetype reaches ExportPdf as a real \"d\" dash operator (14.173/8.504 pt = 5/3 mm at Scale=1)" || { echo "FAIL dash_scale1.pdf: no [14.173 8.504] 0 d operator"; fail=1; }
grep -q 'stroke-dasharray' "$TMPW/solid_scale1.svg" && grep -q 'stroke-dasharray="5,3"' "$TMPW/solid_scale1.svg" || { echo "FAIL solid_scale1.svg: expected exactly one dasharray (the dashed line), none or more found"; fail=1; }
SOLID_DASH_COUNT="$(grep -c 'stroke-dasharray' "$TMPW/solid_scale1.svg" || true)"
[ "$SOLID_DASH_COUNT" = "1" ] && echo "ok   the Continuous-linetype line exported alongside it has no stray dasharray of its own" || { echo "FAIL solid_scale1.svg: expected exactly 1 stroke-dasharray (only the dashed line's), got $SOLID_DASH_COUNT"; fail=1; }
grep -aq '\[\] 0 d' "$TMPW/solid_scale1.pdf" && echo "ok   ExportPdf resets to a plain solid \"[] 0 d\" before the Continuous-linetype line, not leaking the other line's dash pattern" || { echo "FAIL solid_scale1.pdf: no [] 0 d reset operator"; fail=1; }

# Automatic associative-annotation recompute (PARITY_MAP.md "Associative
# annotation updating" - see auto_annotation_update_script.txt's own
# header comment for the full construction/reasoning): a dimension
# associative to a real Line's endpoints must already carry a brand new
# object id by the time this script's SECOND "List" runs, with no
# UpdateDimensions call anywhere in between the Scale1D that stretched
# the line and that second List - proof Application::Frame()'s new
# per-frame hook, not this script, already tore the old dimension down
# and rebuilt it. The explicit UpdateDimensions at the very end (run only
# to confirm correctness, not to cause the rebuild) must still report the
# correct stretched 40-unit measurement.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  AAU="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/auto_annotation_update_script.txt" 2>&1)" || { echo "$AAU"; echo "FAIL: auto-annotation-update script exited non-zero"; exit 1; }
else
  AAU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/auto_annotation_update_script.txt" 2>&1)" || { echo "$AAU"; echo "FAIL: auto-annotation-update script exited non-zero"; exit 1; }
fi
printf '%s' "$AAU" > "$TMPW/auto_annotation_update_output.txt"
python3 - "$TMPW/auto_annotation_update_output.txt" <<'PY' && echo "ok   the dimension already carried a brand new object id by the second List - proving Frame()'s new per-frame hook rebuilt it with no UpdateDimensions call in between" || { echo "FAIL the dimension's object id did not change between the two List calls (no automatic rebuild happened)"; fail=1; }
import re, sys
text = open(sys.argv[1]).read()
ids = [int(m.group(1)) for m in re.finditer(r"^history: Object (\d+) ", text, re.MULTILINE)]
assert len(ids) >= 2, f"expected at least 2 'Object <id>' List lines, got {ids}"
before, after = ids[0], ids[1]
assert after > before, f"expected the second List id ({after}) to be strictly greater than the first ({before}) - Add() always allocates higher ids, so an unchanged or lower id means no automatic rebuild happened"
PY
echo "$AAU" | grep -q "^history: UpdateDimensions:   DimLinear now measures 40$" && echo "ok   the automatically-rebuilt dimension's measurement is correct (40, the stretched length) - UpdateDimensions, run afterward only to confirm, agrees with what the per-frame hook already built" || { echo "FAIL auto-annotation-update: expected UpdateDimensions to confirm a 40-unit measurement"; fail=1; }

# Undo id-reuse regression (see the last section of history_script.txt):
# a Box drawn right after undoing a tracked Extrude used to be handed the
# undone extrusion's own id (6), so its HistoryRecord/Provenance entries -
# side tables keyed by ObjectId, deliberately outside the undo history -
# attached to the Box, and UpdateHistory rebuilt the Box into "surface
# (40,0,0)-(50,0,5)". Document::ApplyDelta now keeps the id counter
# monotonic across Undo, so the Box gets a fresh id (7) and the stale
# record resolves to nothing.
hcheck_absent() { if echo "$HS" | grep -qF "$1"; then echo "FAIL $2"; fail=1; else echo "ok   $2"; fi; }
hcheck "object 6: Extrude <- 5" "an Undo/Redo round trip keeps the redone extrusion's own id (6) and its HistoryRecord (the record survives Undo+Redo, it is only ever orphaned by a real removal)"
hcheck "  ID: 7" "a Box drawn after undoing the tracked extrusion (id 6) gets a fresh id (7), not the undone object's id"
# History records are now part of the undo deltas (automatic propagation work): undoing a
# tracked construction removes its record with it, so UpdateHistory has no orphan to clear
# (the old output said "1 orphaned entry cleared"). The invariant the test protects is
# unchanged: only the still-live tracked surface (4) is re-evaluated, and the new Box is
# NOT treated as a tracked object (checked just below: its geometry stays untouched).
hcheck "UpdateHistory: 1 object(s) re-evaluated from their source curve(s)' current geometry" \
  "UpdateHistory rebuilt only the still-live tracked surface (4) - it did NOT treat the new Box as a tracked object"
hcheck_absent "orphaned entry cleared (object deleted" "an Undo takes the undone construction's history record with it, so UpdateHistory has no orphaned record to clear"
hcheck_absent "Bounding box: (40, 0, 0) to (50, 0, 5)" "the Box was never rebuilt into line 5's extrusion (the exact silent wrong result the id reuse produced before)"
hcheck "Bounding box: (50, 50, 0) to (60, 60, 10)" "the Box's own geometry is untouched after UpdateHistory"

# HistoryPurge/HistoryUpdate/SelObjectsWithHistory against REAL recorded
# history (see history_purge_script.txt's own header comment): before this
# fix all three were dead - HistoryPurge/HistoryUpdate (cmd_state.cpp) always
# claimed no history was recorded, and SelObjectsWithHistory (cmd_select2.cpp)
# always selected 0 objects and claimed Dino 8 keeps no construction history
# at all - regardless of what cmd_history.cpp's real mechanism, right next to
# all three, actually had tracked.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HP="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_purge_script.txt" 2>&1)" || { echo "$HP"; echo "FAIL: history-purge script exited non-zero"; exit 1; }
else
  HP="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_purge_script.txt" 2>&1)" || { echo "$HP"; echo "FAIL: history-purge script exited non-zero"; exit 1; }
fi
echo "$HP" | grep -E "^(ok|FAIL)"
if echo "$HP" | grep -q "^FAIL"; then fail=1; fi
echo "$HP" | grep -q "^smoke:" || { echo "$HP"; echo "FAIL: history-purge script produced no smoke line"; fail=1; }
hpcheck() { if echo "$HP" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HP" "$1"; fail=1; fi; }
hpcheck "2 object(s) selected" "SelObjectsWithHistory finds both tracked extrusions (objects 2 and 4) - real selection, not the old hardcoded 0"
hpcheck "HistoryPurge: 1 object(s) had their recorded construction history removed; HistoryPurge will no longer rebuild it from a source curve" "HistoryPurge, with object 2 selected, purges only that one object's recorded history"
hpcheck "1 object(s) selected" "SelObjectsWithHistory now finds only object 4 - object 2's history was really dropped, not just reported as dropped"
hpcheck "HistoryUpdate: 1 object(s) re-evaluated from their source curve(s)' current geometry" "HistoryUpdate (the catalog's real name - see cmd_history.cpp) still finds and rebuilds the surviving tracked object"
hpcheck "0 object(s) selected" "after a second HistoryPurge with nothing selected (whole-document purge), SelObjectsWithHistory finds nothing left"
hpcheck "HistoryUpdate: 0 object(s) re-evaluated from their source curve(s)' current geometry" "HistoryUpdate confirms no recorded history remains anywhere in the document"

# RemoveLayer must keep every OTHER holder of a layer index consistent, not
# just live objects (see tests/layer_remap_script.txt): a layout detail's
# per-detail hidden layers, a block definition's own member objects, and its
# "in use" check must also look at block definition members, not just live
# objects.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  LR="$(timeout 900 "$BIN" --smoke 200 --script "$HERE/layer_remap_script.txt" 2>&1)" || { echo "$LR"; echo "FAIL: layer-remap script exited non-zero"; exit 1; }
else
  LR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$HERE/layer_remap_script.txt" 2>&1)" || { echo "$LR"; echo "FAIL: layer-remap script exited non-zero"; exit 1; }
fi
echo "$LR" | grep -E "^(ok|FAIL)"
if echo "$LR" | grep -q "^FAIL"; then fail=1; fi
echo "$LR" | grep -q "^smoke:" || { echo "$LR"; echo "FAIL: layer-remap script produced no smoke line"; fail=1; }
lcheck() { if echo "$LR" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
lcheck "ShowLayersInDetail: 1 layer(s) in 1 detail(s)" "the detail's hidden-layer entry followed Walls to its new index (0 before the fix - the stale index resolved to the wrong, or no, layer)"
lcheck "  Layer index: 1" "a fresh Bk instance lands on Walls (index 1 after Purge removes Spare), not Roof (index 2 before the fix, since block members were never remapped)"
lcheck "Purge: nothing to remove" "Walls is reported in use (and left alone) once only a block definition's member is on it - the 'in use' check before the fix looked at live objects only"

# New must start a genuinely empty document (see tests/new_doc_script.txt):
# Document::Clear() used to leave block definitions and the id-keyed
# HistoryRecord/Provenance/CageBinding side tables from the OLD document in
# place, so the new document's first objects, handed the same small ids,
# could silently inherit them.
sed "s|@TMP@|$TMPW|g" "$HERE/new_doc_script.txt" > "$TMPW/new_doc_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  ND="$(timeout 900 "$BIN" --smoke 200 --script "$TMPW/new_doc_script.txt" 2>&1)" || { echo "$ND"; echo "FAIL: new-doc script exited non-zero"; exit 1; }
else
  ND="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 200 --script "$TMPW/new_doc_script.txt" 2>&1)" || { echo "$ND"; echo "FAIL: new-doc script exited non-zero"; exit 1; }
fi
echo "$ND" | grep -E "^(ok|FAIL)"
if echo "$ND" | grep -q "^FAIL"; then fail=1; fi
echo "$ND" | grep -q "^smoke:" || { echo "$ND"; echo "FAIL: new-doc script produced no smoke line"; fail=1; }
ndcheck() { if echo "$ND" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
ndcheck "History recording: on. 0 object(s) with live construction history" "New starts with an empty HistoryRecord table - the fresh Circle was not silently inherited as document A's tracked Extrude"
ndcheck "0 object(s) selected" "SelExtrusion finds nothing in the new document (1 before the fix: the fresh Circle wrongly matched the old Provenance/HistoryRecord entry)"
ndcheck "UpdateHistory: 0 object(s) re-evaluated" "UpdateHistory has nothing to rebuild in the new document"
ndcheck "history: curve" "SelLast + What still reports the fresh object as the Circle it really is"
ndcheck_absent() { if echo "$ND" | grep -qF "$1"; then echo "FAIL $2"; fail=1; else echo "ok   $2"; fi; }
ndcheck_absent "history: surface" "the Circle was never silently rebuilt into a surface (document A's Line-1 extrusion - the exact silent wrong result the leaked HistoryRecord produced before)"
ndcheck "No block definitions. Use Block to create one." "BlockManager's block table was cleared by New, not left holding document A's block"

# Load3dm must reject a .3dm mesh whose face vertex indices point past its
# own vertex array (see src/io/File3dm.cpp's MeshFaceIndicesInRange and
# tests/mesh_fixture_gen.cpp): OpenNURBS' own reader copies such a mesh in
# verbatim with no check and no diagnostic, after which every mesh query
# would read memory past the end of the vertex array. Dino 8 has no command
# of its own that can construct such a mesh, so mesh_fixture_gen builds one
# directly through ONX_Model/ON_Mesh, independent of Dino 8's own exporter.
MESHBIN="$(dirname "$BIN")/mesh_fixture_gen"
if [ -x "$MESHBIN" ]; then
  "$MESHBIN" "$TMPW/mesh_bad.3dm" bad >/dev/null || { echo "FAIL: mesh_fixture_gen failed to write the bad-mesh fixture"; exit 1; }
  "$MESHBIN" "$TMPW/mesh_good.3dm" good >/dev/null || { echo "FAIL: mesh_fixture_gen failed to write the good-mesh fixture"; exit 1; }
  cat > "$TMPW/mesh_bad_script.txt" <<EOS
Open $TMPW/mesh_bad.3dm
@expect_objects 0
EOS
  cat > "$TMPW/mesh_good_script.txt" <<EOS
Open $TMPW/mesh_good.3dm
@expect_objects 1
EOS
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    MB="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/mesh_bad_script.txt" 2>&1)" || { echo "$MB"; echo "FAIL: bad-mesh script exited non-zero"; exit 1; }
    MG="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/mesh_good_script.txt" 2>&1)" || { echo "$MG"; echo "FAIL: good-mesh script exited non-zero"; exit 1; }
  else
    MB="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/mesh_bad_script.txt" 2>&1)" || { echo "$MB"; echo "FAIL: bad-mesh script exited non-zero"; exit 1; }
    MG="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/mesh_good_script.txt" 2>&1)" || { echo "$MG"; echo "FAIL: good-mesh script exited non-zero"; exit 1; }
  fi
  echo "$MB" | grep -E "^(ok|FAIL)"
  echo "$MG" | grep -E "^(ok|FAIL)"
  if echo "$MB" | grep -q "^FAIL"; then fail=1; fi
  if echo "$MG" | grep -q "^FAIL"; then fail=1; fi
  mcheck() { if echo "$1" | grep -qF "$2"; then echo "ok   $3"; else echo "FAIL $3"; fail=1; fi; }
  mcheck "$MB" "1 corrupt mesh(es) skipped (face vertex indices outside the mesh's own vertex array)" "the out-of-range mesh is reported and skipped, not silently kept (0 objects before the fix's own diagnostic existed - it silently loaded as 1 object with no error at all)"
  mcheck "$MG" "Opened $TMPW/mesh_good.3dm (1 objects)" "a mesh with only in-range faces - including a degenerate repeated-index one, which is legitimate - still loads (the check is a range check, not the stricter no-repeated-index rule)"
else
  echo "FAIL mesh_fixture_gen was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the corrupt-mesh fixture check"
  fail=1
fi

# Native .3dm ON_Hatch import: previously Load3dm had no ON_Hatch handling
# at all, so a hatch authored by a real, independent CAD tool (not Dino 8's
# own baked-geometry export) was silently skipped on open. hatch3dm_fixture_gen
# builds a real ON_Hatch (solid fill, 10x10 square boundary on the world XY
# plane, referencing a real "Solid" ON_HatchPattern table entry) directly
# through OpenNURBS' own API, independent of Dino 8's exporter - the same
# "real externally-authored file, not a round trip" proof mesh_fixture_gen
# and dwg_fixture_gen.c already give their own formats. The checks mirror
# the existing DXF HATCH import test exactly: same SelHatch/List/Area
# expectations, since Load3dm's new code path is the same BuildSolidHatch
# helper DxfImporter::Hatch already uses.
HATCHBIN="$(dirname "$BIN")/hatch3dm_fixture_gen"
if [ -x "$HATCHBIN" ]; then
  "$HATCHBIN" "$TMPW/hatch_fixture.3dm" >/dev/null || { echo "FAIL: hatch3dm_fixture_gen failed to write the hatch fixture"; exit 1; }
  cat > "$TMPW/hatch3dm_script.txt" <<EOS
Open $TMPW/hatch_fixture.3dm
SelHatch
List
Area
EOS
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    H3D="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/hatch3dm_script.txt" 2>&1)" || { echo "$H3D"; echo "FAIL: hatch .3dm script exited non-zero"; exit 1; }
  else
    H3D="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/hatch3dm_script.txt" 2>&1)" || { echo "$H3D"; echo "FAIL: hatch .3dm script exited non-zero"; exit 1; }
  fi
  h3check() { if echo "$H3D" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$H3D" "$1"; fail=1; fi; }
  h3check "Opened $TMPW/hatch_fixture.3dm (1 objects)" "Load3dm read the real ON_Hatch as one object, not zero (silently skipped, the old behaviour)"
  h3check "1 object(s) selected" "SelHatch found the imported hatch (real Hatch=Solid user_text, not just an ordinary object)"
  h3check "name 'Hatch Solid'" "the imported solid hatch is the same trimmed-planar-brep object BuildSolidHatch builds in-app / from DXF"
  h3check "1 faces, 1 edges, open" "the imported hatch is a single trimmed planar face"
  h3check "Area = 100 square" "the imported hatch's area is exactly the 10x10 boundary (not a sampled approximation)"
else
  echo "FAIL hatch3dm_fixture_gen was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the .3dm ON_Hatch fixture check"
  fail=1
fi

# Native .3dm solid-fill HATCH export: the test above only ever proves
# Load3dm's own ON_Hatch *reading*; Save3dm itself had no ON_Hatch writer at
# all until this change (see BuildOnHatchForGroup in File3dm.cpp) - a solid
# hatch made in-app (Hatch Pattern=Solid) round-tripped out through .3dm as
# a bare Brep plus Hatch=Solid user_text, never a real ON_Hatch a genuinely
# independent Rhino/OpenNURBS-based reader would recognize as one hatch -
# the same "Dino-written ... hatches ... still survive only as baked
# geometry" gap Load3dm's own ON_Hatch-reading pass above discloses. Makes a
# real solid hatch, saves it, and reopens the saved file in a fresh
# document: SelHatch/Area must find the exact same hatch back, proving the
# new writer and the existing reader agree on the wire format - and,
# independent of Dino 8's own reader entirely, hatch3dm_write_check (the
# write-side mirror of hatch3dm_fixture_gen above) parses the saved file
# directly through OpenNURBS' own API and confirms it holds one real
# ON_Hatch object referencing a real Solid-fill ON_HatchPattern table entry.
sed "s|@TMP@|$TMPW|g" "$HERE/hatch3dm_export_solid_script.txt" > "$TMPW/hatch3dm_export_solid_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  H3S="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/hatch3dm_export_solid_script.txt" 2>&1)" || { echo "$H3S"; echo "FAIL: .3dm solid HATCH export script exited non-zero"; exit 1; }
else
  H3S="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/hatch3dm_export_solid_script.txt" 2>&1)" || { echo "$H3S"; echo "FAIL: .3dm solid HATCH export script exited non-zero"; exit 1; }
fi
h3scheck() { if echo "$H3S" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$H3S" "$1"; fail=1; fi; }
h3scheck "Saved $TMPW/hatch3dm_export_solid.3dm" "Save3dm wrote a file"
h3scheck "Opened $TMPW/hatch3dm_export_solid.3dm (2 objects)" "the reopened file has the boundary rectangle plus the reconstructed hatch - the ON_Hatch round-tripped as a real hatch, not a bare Brep plus metadata"
h3scheck "1 object(s) selected" "SelHatch found the round-tripped hatch"
h3scheck "1 faces, 1 edges, open" "the round-tripped hatch is a single trimmed planar face"
h3scheck "Area = 100 square" "the round-tripped hatch's area is exactly the 10x10 boundary"
HWCBIN="$(dirname "$BIN")/hatch3dm_write_check"
if [ -x "$HWCBIN" ]; then
  HWC="$("$HWCBIN" "$TMPW/hatch3dm_export_solid.3dm" 2>&1)" || { echo "$HWC"; echo "FAIL: hatch3dm_write_check exited non-zero on the solid hatch file"; exit 1; }
  hwccheck() { if echo "$HWC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HWC" "$1"; fail=1; fi; }
  hwccheck "1 real ON_Hatch object(s) found" "independent of Dino 8's own Load3dm, a plain OpenNURBS reader sees exactly one real ON_Hatch object in the saved file"
  hwccheck "fill=Solid" "the saved hatch's pattern-table entry is really marked Solid fill, not just named 'Solid'"
else
  echo "FAIL hatch3dm_write_check was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the independent .3dm ON_Hatch write check"
  fail=1
fi

# Native .3dm pattern-fill HATCH export: the solid case above only ever
# covers Hatch=Solid; a pattern-fill hatch (Hatch Pattern=ANSI31,
# drafting::BuildPatternHatch's own already-clipped line-curve group) still
# round-tripped out through .3dm as its own N baked line-curve objects,
# never one real ON_Hatch, until BuildOnHatchForGroup's own HatchBoundary-tag
# lookup and ON_HatchPattern/ON_HatchLine construction (File3dm.cpp) closed
# it - the same "N already-clipped lines, no record it was ever one fill"
# gap the DXF/DWG pattern-HATCH writer already closed for those formats
# (WriteDxfHatchPattern). Makes a real ANSI31 hatch, saves it, and reopens
# the saved file in a fresh document: SelHatch must find the exact same
# number of real, Hatch=ANSI31-tagged line objects the original Hatch
# command built - and hatch3dm_write_check independently confirms the saved
# file holds exactly one real ON_Hatch (not 81 bare line objects) whose
# pattern table entry is really named ANSI31 with real HatchLine family data
# (not just a name a third-party reader may or may not recognize).
sed "s|@TMP@|$TMPW|g" "$HERE/hatch3dm_export_pattern_script.txt" > "$TMPW/hatch3dm_export_pattern_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  H3P="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/hatch3dm_export_pattern_script.txt" 2>&1)" || { echo "$H3P"; echo "FAIL: .3dm pattern HATCH export script exited non-zero"; exit 1; }
else
  H3P="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/hatch3dm_export_pattern_script.txt" 2>&1)" || { echo "$H3P"; echo "FAIL: .3dm pattern HATCH export script exited non-zero"; exit 1; }
fi
h3pcheck() { if echo "$H3P" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$H3P" "$1"; fail=1; fi; }
h3pcheck "Saved $TMPW/hatch3dm_export_pattern.3dm" "Save3dm wrote a file"
BEFORE_SEL3D="$(echo "$H3P" | grep -o "[0-9]* object(s) selected" | head -1 || true)"
AFTER_SEL3D="$(echo "$H3P" | grep -o "[0-9]* object(s) selected" | tail -1 || true)"
if [ -n "$BEFORE_SEL3D" ] && [ "$BEFORE_SEL3D" = "$AFTER_SEL3D" ]; then
  echo "ok   the round-tripped pattern hatch's line count matches exactly ($BEFORE_SEL3D)"
else
  echo "FAIL .3dm pattern hatch line count did not round-trip (before: '$BEFORE_SEL3D', after: '$AFTER_SEL3D')"
  fail=1
fi
if [ -x "$HWCBIN" ]; then
  HWCP="$("$HWCBIN" "$TMPW/hatch3dm_export_pattern.3dm" 2>&1)" || { echo "$HWCP"; echo "FAIL: hatch3dm_write_check exited non-zero on the pattern hatch file"; exit 1; }
  hwcpcheck() { if echo "$HWCP" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$HWCP" "$1"; fail=1; fi; }
  hwcpcheck "1 real ON_Hatch object(s) found" "the saved pattern-fill hatch is one real ON_Hatch object, not N bare line objects"
  hwcpcheck "fill=Lines" "the saved hatch's pattern-table entry is really marked Lines fill (a real pattern), not Solid"
  hwcpcheck "pattern_name=ANSI31" "the saved hatch really references an ANSI31-named pattern-table entry"
  echo "$HWCP" | grep -q "pattern_lines=[1-9]" && echo "ok   the saved ANSI31 pattern table entry carries real HatchLine family data (not an empty, name-only pattern)" || { echo "FAIL the saved pattern table entry has no real HatchLine data"; near "$HWCP" "pattern_lines="; fail=1; }
else
  echo "FAIL hatch3dm_write_check was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the independent .3dm pattern ON_Hatch write check"
  fail=1
fi

# Native .3dm Text export: Save3dm had no ON_Text writer at all before this
# change (see BuildOnTextForGroup in File3dm.cpp) - a Text annotation made
# in-app round-tripped out through .3dm as its own N baked glyph curves
# plus Text/TextHeight/TextOrigin/... user_text metadata, never a real
# ON_Text object a genuinely independent Rhino/OpenNURBS-based reader
# would recognize as one text object - the Text half of this bullet's own
# disclosed "Dim*/Leader/Text... still written exactly as before" gap
# (Hatch already closed the same way, above). Makes a real "Hi" text
# annotation, saves it, and reopens the saved file in a fresh document:
# SelText/List must find the exact same 3 glyph curves back, proving the
# new writer and the existing ON_Text reader (added for externally-
# authored files - see text3dm_fixture_gen.cpp, below) agree on the wire
# format - and, independent of Dino 8's own reader entirely,
# text3dm_write_check (the write-side mirror of text3dm_fixture_gen) parses
# the saved file directly through OpenNURBS' own API and confirms it holds
# one real ON_Text object with the exact string/height/plane, not bare
# glyph curves.
sed "s|@TMP@|$TMPW|g" "$HERE/text3dm_export_script.txt" > "$TMPW/text3dm_export_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  T3E="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/text3dm_export_script.txt" 2>&1)" || { echo "$T3E"; echo "FAIL: .3dm Text export script exited non-zero"; exit 1; }
else
  T3E="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/text3dm_export_script.txt" 2>&1)" || { echo "$T3E"; echo "FAIL: .3dm Text export script exited non-zero"; exit 1; }
fi
t3echeck() { if echo "$T3E" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$T3E" "$1"; fail=1; fi; }
t3echeck "Saved $TMPW/text3dm_export.3dm" "Save3dm wrote a file"
t3echeck "Opened $TMPW/text3dm_export.3dm (3 objects)" "the reopened file has the exact same 3 glyph curves (H, i-stem, i-dot) the original Text command built - the ON_Text round-tripped as a real text object, not bare geometry"
t3echeck "3 object(s) selected" "SelText found the round-tripped text's own 3 glyph curves"
TWCBIN="$(dirname "$BIN")/text3dm_write_check"
if [ -x "$TWCBIN" ]; then
  TWC="$("$TWCBIN" "$TMPW/text3dm_export.3dm" 2>&1)" || { echo "$TWC"; echo "FAIL: text3dm_write_check exited non-zero on the text file"; exit 1; }
  twccheck() { if echo "$TWC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$TWC" "$1"; fail=1; fi; }
  twccheck "1 real ON_Text object(s) found" "independent of Dino 8's own Load3dm, a plain OpenNURBS reader sees exactly one real ON_Text object in the saved file, not 3 bare glyph curves"
  twccheck "text=Hi" "the saved text object's own string content survived exactly"
  twccheck "height=2" "the saved text object's own real DimStyle table entry carries the exact requested text height (this document's own default annotation text height)"
  twccheck "origin=(0,0,0)" "the saved text object's own plane origin survived exactly"
else
  echo "FAIL text3dm_write_check was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the independent .3dm ON_Text write check"
  fail=1
fi

# Native .3dm Leader export: Save3dm had no ON_Leader writer at all before
# this change (see BuildOnLeaderForGroup in File3dm.cpp) - a Leader
# annotation made in-app round-tripped out through .3dm as its own baked
# polyline/arrowhead/glyph-text curves plus LeaderTip/LeaderRest/Text/...
# user_text metadata, never a real ON_Leader object a genuinely
# independent Rhino/OpenNURBS-based reader would recognize as one leader -
# the Leader half of this bullet's own disclosed "Dim*/Leader/Text... still
# written exactly as before" gap (Hatch and Text already closed the same
# way, above). Makes a real 3-point Leader with a "Hi" label, saves it, and
# reopens the saved file in a fresh document: SelLeader/List must find the
# exact same 5 member curves back (2 shape + 3 "Hi" glyph curves, the same
# count the live Leader command itself builds - proving the real ON_Leader's
# own internally-carried label did not ALSO leak out as separate baked
# glyph curves, a real bug caught and fixed while building this) - and,
# independent of Dino 8's own reader entirely, leader3dm_write_check parses
# the saved file directly through OpenNURBS' own API and confirms it holds
# exactly one real ON_Leader object with the exact label and points.
# Deliberately run as TWO separate process launches, not one combined
# script - see leader3dm_export_script.txt's own header comment: a live
# Leader object already present when Open runs in the SAME process hits a
# real, pre-existing, unrelated bug in UpdateAssociativeAnnotations' own
# cross-call static anchor cache (Application.cpp), inflating the reopened
# selection count. leader3dm_write_check (below) and a fresh-process-only
# reopen both independently confirm the saved file content itself is always
# exactly correct, so this split (matching dwg_script.txt/
# dwg_reopen_script.txt's own same-process-reuse workaround) sidesteps that
# unrelated bug rather than papering over it.
sed "s|@TMP@|$TMPW|g" "$HERE/leader3dm_export_script.txt" > "$TMPW/leader3dm_export_script.txt"
sed "s|@TMP@|$TMPW|g" "$HERE/leader3dm_reopen_script.txt" > "$TMPW/leader3dm_reopen_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  L3E="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/leader3dm_export_script.txt" 2>&1)" || { echo "$L3E"; echo "FAIL: .3dm Leader export script exited non-zero"; exit 1; }
  L3I="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/leader3dm_reopen_script.txt" 2>&1)" || { echo "$L3I"; echo "FAIL: .3dm Leader reopen script exited non-zero"; exit 1; }
else
  L3E="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/leader3dm_export_script.txt" 2>&1)" || { echo "$L3E"; echo "FAIL: .3dm Leader export script exited non-zero"; exit 1; }
  L3I="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/leader3dm_reopen_script.txt" 2>&1)" || { echo "$L3I"; echo "FAIL: .3dm Leader reopen script exited non-zero"; exit 1; }
fi
l3echeck() { if echo "$L3E" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$L3E" "$1"; fail=1; fi; }
l3icheck() { if echo "$L3I" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$L3I" "$1"; fail=1; fi; }
l3echeck "Saved $TMPW/leader3dm_export.3dm" "Save3dm wrote a file"
l3icheck "Opened $TMPW/leader3dm_export.3dm (5 objects)" "the reopened file has the exact same 5 member curves (2 shape + 3 'Hi' glyph curves) the original Leader command built - not 8 (which would mean the real ON_Leader's own label leaked out as separate baked glyph curves too)"
l3icheck "5 object(s) selected" "SelLeader found the round-tripped leader's own 5 member curves"
l3icheck "CV[0] 0,0,0" "the round-tripped leader's own shape polyline starts at the exact arrowhead point"
l3icheck "CV[1] 5,10,0" "the round-tripped leader's own shape polyline passes through its exact bend point"
l3icheck "CV[2] 20,10,0" "the round-tripped leader's own shape polyline ends at its exact tail point"
LWCBIN="$(dirname "$BIN")/leader3dm_write_check"
if [ -x "$LWCBIN" ]; then
  LWC="$("$LWCBIN" "$TMPW/leader3dm_export.3dm" 2>&1)" || { echo "$LWC"; echo "FAIL: leader3dm_write_check exited non-zero on the leader file"; exit 1; }
  lwccheck() { if echo "$LWC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$LWC" "$1"; fail=1; fi; }
  lwccheck "1 real ON_Leader object(s) found" "independent of Dino 8's own Load3dm, a plain OpenNURBS reader sees exactly one real ON_Leader object in the saved file, not 5 bare baked curves"
  lwccheck "text=Hi" "the saved leader's own label string survived exactly"
  lwccheck "pt[0]=(0,0,0)" "the saved leader's own arrowhead point survived exactly"
  lwccheck "pt[1]=(5,10,0)" "the saved leader's own bend point survived exactly"
  lwccheck "pt[2]=(20,10,0)" "the saved leader's own tail point survived exactly"
else
  echo "FAIL leader3dm_write_check was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the independent .3dm ON_Leader write check"
  fail=1
fi

# Native .3dm ON_InstanceRef import: previously Load3dm had no
# ON_InstanceRef/ON_InstanceDefinition handling at all, and no
# ON::idef_object check either, so a block instance authored by a real,
# independent CAD tool (Dino 8's own blocks persist through .3dm as tagged
# ordinary geometry plus a private "Dino8.BlocksMeta" document user string,
# never a real instance definition/reference pair - see File3dm.cpp's
# EncodeBlocksMeta/DecodeBlocksMeta) lost its placements entirely and kept
# only one un-transformed, ungrouped copy of the definition's own member
# geometry instead. instanceref3dm_fixture_gen builds a real
# ON_InstanceDefinition (one member: a unit-length line on the X axis) and
# two ON_InstanceRef placements of it - one plain translation, one a
# translation combined with a uniform 3x scale - directly through
# OpenNURBS' own API, independent of Dino 8's own exporter (which never
# writes this pair at all), the same "real externally-authored file, not a
# round trip" proof hatch3dm_fixture_gen already gives ON_Hatch. The scale
# placement's imported line must come back 3 units long (not 1), proving
# Load3dm applied the ref's full ON_Xform, not just an insertion-point
# translation. It also builds a second, outer ON_InstanceDefinition
# ("OuterBlock") whose own one member is a NESTED ON_InstanceRef placing
# TestBlock inside it (translated (0,5,0) within the definition itself) -
# a real Rhino feature (one block definition may place another block)
# BuildBlockDefinitionFromIdef (File3dm.cpp) previously silently dropped
# along with every other geometry kind it has no Dino8-side equivalent
# for, same as nested instance refs' own prior disclosed gap. Flattened
# rather than truly nested (Dino8's own BlockDefinition::objects is a flat
# geometry list - even a block authored live in Dino8 can never nest one
# inside another): the nested ref's own xform is baked into the member
# line before it's added to OuterBlock's own definition, so OuterBlock's
# placement at (100,0,0) must compose BOTH transforms, landing the line at
# (100,5,0)-(101,5,0), not (100,0,0)-(101,0,0) (nested xform dropped) or
# (0,5,0)-(1,5,0) (placement xform dropped).
IREFBIN="$(dirname "$BIN")/instanceref3dm_fixture_gen"
if [ -x "$IREFBIN" ]; then
  "$IREFBIN" "$TMPW/instanceref_fixture.3dm" >/dev/null || { echo "FAIL: instanceref3dm_fixture_gen failed to write the instance-ref fixture"; exit 1; }
  cat > "$TMPW/instanceref3dm_script.txt" <<EOS
Open $TMPW/instanceref_fixture.3dm
SelBlockInstanceOf TestBlock
What
SelNone
SelBlockInstanceOf OuterBlock
What
EOS
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    IRF="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/instanceref3dm_script.txt" 2>&1)" || { echo "$IRF"; echo "FAIL: instance-ref .3dm script exited non-zero"; exit 1; }
  else
    IRF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/instanceref3dm_script.txt" 2>&1)" || { echo "$IRF"; echo "FAIL: instance-ref .3dm script exited non-zero"; exit 1; }
  fi
  irfcheck() { if echo "$IRF" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$IRF" "$1"; fail=1; fi; }
  irfcheck "Opened $TMPW/instanceref_fixture.3dm (3 objects)" "Load3dm placed all 3 ON_InstanceRef instances (2 TestBlock + 1 OuterBlock) as 3 real objects (0 before the fix: all silently skipped), and did not also add either idef's own member geometry as extra, un-transformed objects (ON::idef_object skip)"
  irfcheck "SelBlockInstanceOf: selected 2 object(s) in instances of 'TestBlock'" "both direct placements landed as real Dino8 block instances, tagged and grouped under the idef's own name, not ordinary untagged objects"
  irfcheck "Length: 1" "the plain-translation placement's line kept its original unit length"
  irfcheck "Length: 3" "the scale+translate placement's line came back 3 units long - proof Load3dm applied the ref's full ON_Xform (scale included), not just a translation to the insertion point"
  irfcheck "BlockInsert = 2.000000,3.000000,0.000000" "the plain-translation placement's insertion point is exactly where it was placed"
  irfcheck "BlockInsert = 10.000000,0.000000,0.000000" "the scale+translate placement's insertion point is the translation component alone, not shifted by the scale (both ops shared a single ON_Xform, origin-fixed scale then translate)"
  irfcheck "SelBlockInstanceOf: selected 1 object(s) in instances of 'OuterBlock'" "the OuterBlock placement - whose own definition's one member is a NESTED ON_InstanceRef placing TestBlock, not ordinary geometry - was found by name, proving BuildBlockDefinitionFromIdef resolved the nested reference into real flattened geometry rather than silently dropping the whole member and leaving OuterBlock's own definition empty"
  irfcheck "Bounding box: (100, 5, 0) to (101, 5, 0)" "OuterBlock's placement at (100,0,0) composed with the nested member's own (0,5,0) translation baked into the definition - both transforms applied, not just one"
  irfcheck "Block = OuterBlock" "the flattened nested-block line carries the outer block's own name, not the inner TestBlock's"
  irfcheck "BlockInsert = 100.000000,0.000000,0.000000" "the OuterBlock placement's own insertion point survived exactly, independent of the nested member's own baked-in offset"
else
  echo "FAIL instanceref3dm_fixture_gen was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the .3dm ON_InstanceRef fixture check"
  fail=1
fi

# Native .3dm ON_Annotation (Text) import: previously Load3dm had no
# ON_Annotation handling at all, so a Text object authored by a real,
# independent CAD tool (Dino 8's own Text command bakes a group of
# glyph-outline curves plus Annotation/Text/... user_text instead - see
# commands/annotate_common.h) was silently skipped on open, same as
# ON_Hatch/ON_InstanceRef before their own passes above. text3dm_fixture_gen
# builds a real ON_Text ("Hi" at (3,4,0), referencing a real custom
# ON_DimStyle table entry with text height 2) directly through OpenNURBS'
# own API, independent of Dino 8's own exporter (which never writes a real
# ON_Annotation at all). The checks mirror the existing DXF TEXT import
# test's own "Hi" fixture exactly (same H/i-stem/i-dot = 3 glyph-curve
# count), except SelText/FindText DO apply here (unlike that DXF-reader
# gap) since this reader groups the glyph curves into a real
# Document::Group, so FindText's own group-membership lookup finds it.
TXTBIN="$(dirname "$BIN")/text3dm_fixture_gen"
if [ -x "$TXTBIN" ]; then
  "$TXTBIN" "$TMPW/text_fixture.3dm" >/dev/null || { echo "FAIL: text3dm_fixture_gen failed to write the text fixture"; exit 1; }
  cat > "$TMPW/text3dm_script.txt" <<EOS
Open $TMPW/text_fixture.3dm
SelText
FindText Hi
What
EOS
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    TXF="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/text3dm_script.txt" 2>&1)" || { echo "$TXF"; echo "FAIL: text .3dm script exited non-zero"; exit 1; }
  else
    TXF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/text3dm_script.txt" 2>&1)" || { echo "$TXF"; echo "FAIL: text .3dm script exited non-zero"; exit 1; }
  fi
  txfcheck() { if echo "$TXF" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$TXF" "$1"; fail=1; fi; }
  txfcheck "Opened $TMPW/text_fixture.3dm (3 objects)" "Load3dm read the real ON_Text as 3 real glyph curves (H, i-stem, i-dot - the same count a hand-written TEXT fixture already gets from the DXF reader), not 0 (silently skipped, the old behaviour)"
  txfcheck "3 object(s) selected" "SelText found all 3 imported glyph curves (real Annotation=Text user_text, not just ordinary curves)"
  txfcheck "FindText: 1 annotation(s) containing \"Hi\" selected" "FindText found exactly one annotation (its 3 glyph curves share one real Document::Group, unlike the pre-existing DXF/DWG MTEXT-reader gap of the same shape)"
  txfcheck "Text = Hi" "the imported glyph curves carry the exact source string"
  txfcheck "TextHeight = 2" "the text height came from the file's own referenced ON_DimStyle table entry (2), not a hardcoded default"
  txfcheck "TextOrigin = 3,4,0" "the text anchor is the real ON_Text's own plane origin"
else
  echo "FAIL text3dm_fixture_gen was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the .3dm ON_Annotation fixture check"
  fail=1
fi

# Native .3dm ON_DimLinear/ON_DimRadial import: previously Load3dm's
# ON_Annotation branch (added for Text just above) counted every real
# ON_DimLinear/ON_DimRadial/ON_Leader/ON_DimAngular dimension/leader
# authored by a real, independent CAD tool as skipped too (Dino 8's own
# Dim/DimAligned/DimRadius/DimDiameter/Leader/DimAngle commands bake a group
# of curves plus Annotation/Dim*/Leader* user_text instead - see
# commands/DimGeometry.h and cmd_annotate.cpp's own BuildLeaderGroup), same
# gap as ON_Hatch/ON_InstanceRef/Text before their own passes above.
# dimlinear3dm_fixture_gen builds eight real dimension/leader/centermark
# objects directly through OpenNURBS' own API (a rotated/horizontal linear
# 0,0,0-40,0,0 at offset 10; an aligned linear 0,0,0-30,30,0 at offset 5; a
# radius dimension on a center/radius-point/leader-tail of 100,0,0 /
# 105,0,0 / 110,0,0; a diameter dimension on 200,0,0 / 203,0,0 / 206,0,0; a
# leader with arrowhead tip 300,0,0, bend point 305,5,0 and tail/text
# landing 315,5,0; a 90-degree angular dimension with vertex 400,0,0 and
# extension points 410,0,0/400,10,0; an X-direction ordinate dimension with
# base point 500,0,0 and measured feature point 520,8,0; a centermark at
# 600,0,0 marking a radius-8 circle that was never itself written), all
# eight referencing a real custom ON_DimStyle table entry with text height
# 1.5 and centermark size 0.6 (deliberately not a quarter of that radius-8
# circle - 2 - so a reader deriving the drawn size from the radius instead
# of the file's own stored CenterMark field would be caught), independent
# of Dino 8's own exporter (which never writes any of these annotation
# kinds natively). Each dimension is rebuilt via
# BuildLinearDimensionGeometry/BuildRadiusDimensionGeometry/
# BuildAngleDimensionGeometry (commands/DimGeometry.h), the exact math a
# live Dim/DimAligned/DimRadius/DimDiameter/DimAngle command and DXF/DWG
# DIMENSION import already share; the leader is rebuilt via the same
# polyline+arrow+left-aligned-text shape BuildLeaderGroup (cmd_annotate.cpp)
# bakes for a live Leader command; the ordinate dimension is rebuilt via the
# same single-leader-line-plus-text shape BuildOrdinateDimGroup
# (cmd_annotate2.cpp) bakes for a live DimOrdinate command; the centermark
# is rebuilt via BuildCentermarkGeometry (commands/DimGeometry.h), the same
# two-crossing-lines shape a live Centermark command bakes via
# BuildCentermarkGroup - so the checks below mirror the DXF DIMENSION
# test's own tag checks exactly, plus new Leader/DimAngle/DimOrdinate/
# Centermark-specific ones. "70 objects"/arrow-curve Length values are this
# build's own FreeType glyph-contour counts for "40"/"42.43"/"R 5"/"D 3"/
# "LeaderText"/"90 deg"/"X 20" plus the 5/5/2/3/2/3/1/2 line+extension+
# arrow+centermark geometry curves per dimension/leader/centermark
# (9+12+5+7+17+13+5+2) - confirmed by first actually running this fixture
# through the app rather than hand-derived, same as text3dm_fixture_gen's
# own hardcoded "3 objects" for "Hi"'s H/i-stem/i-dot. The arrow-curve
# Length checks below (2.688x the text height, from AddArrow's own fixed
# 0.3x-width triangle) additionally prove the custom DimStyle's text height
# (1.5) was actually resolved via DimensionStyleId(), not
# ON_DimStyle::Default's own differing 1.0. The UpdateDimensions/
# UpdateMeasureDims passes confirm every one of the eight is genuinely
# live/rebuildable from its own tags, not just a one-shot baked import -
# DimOrdinate is rebuilt by UpdateMeasureDims specifically, not
# UpdateDimensions (the same split a live DimOrdinate already has, see
# cmd_annotate2.cpp's own UpdateMeasureDims kKinds list), so both commands
# are exercised here, each against the dimensions it actually owns (the
# centermark has no DimRefObj1 - no Dino8 circle object of its own to
# reference - so it falls back to ResolveCentermarkGeom's static-tag path,
# same as a live Fixed-size centermark whose source circle is gone, rather
# than being skipped outright).
DLFBIN="$(dirname "$BIN")/dimlinear3dm_fixture_gen"
if [ -x "$DLFBIN" ]; then
  "$DLFBIN" "$TMPW/dimlinear_fixture.3dm" >/dev/null || { echo "FAIL: dimlinear3dm_fixture_gen failed to write the dimension fixture"; exit 1; }
  cat > "$TMPW/dimlinear3dm_script.txt" <<EOS
Open $TMPW/dimlinear_fixture.3dm
SelDim
SelLeader
SelAll
What
UpdateDimensions
UpdateMeasureDims
EOS
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    DLF="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/dimlinear3dm_script.txt" 2>&1)" || { echo "$DLF"; echo "FAIL: dimlinear .3dm script exited non-zero"; exit 1; }
  else
    DLF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/dimlinear3dm_script.txt" 2>&1)" || { echo "$DLF"; echo "FAIL: dimlinear .3dm script exited non-zero"; exit 1; }
  fi
  dlfcheck() { if echo "$DLF" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$DLF" "$1"; fail=1; fi; }
  dlfcheck "Opened $TMPW/dimlinear_fixture.3dm (70 objects)" "Load3dm read all eight real ON_DimLinear/ON_DimRadial/ON_Leader/ON_DimAngular/ON_DimOrdinate/ON_Centermark dimensions/leaders/centermark as real dimension groups (9+12+5+7+17+13+5+2 curves), not 0 (silently skipped, the old behaviour)"
  dlfcheck "51 object(s) selected" "SelDim found every imported Dim* dimension's curves including the ordinate's own (its group list does include DimOrdinate) - 51, not all 70, since SelDim's own group list still doesn't include Leader or Centermark"
  dlfcheck "68 object(s) selected" "SelLeader (SelGroupNamed's own additive selection - see Document::SelectWhere's add=true) then added the imported leader's own remaining 17 curves on top of SelDim's 51, reaching 68 (not the full 70 - the centermark's own 2 curves are in neither group) with no overlap and no double-count between the two distinct groups"
  dlfcheck "Annotation = DimLinear" "the rotated linear dimension carries the same Annotation=DimLinear tag a live DimLinear command/DXF DIMENSION import already write"
  dlfcheck "DimAligned = 0" "the rotated dimension is still recognized as rotated, not aligned"
  dlfcheck "DimHorizontal = 1" "the rotated dimension's horizontal-vs-vertical rule (offset point farther outside the vertical span than the horizontal span) correctly recovered horizontal from the file's own DefPoint1/DefPoint2/DimlinePoint, matching cmd_annotate.cpp's own live-pick rule"
  dlfcheck "DimOffset = 10" "the rotated dimension's dimension-line offset (DimlinePoint's own y=10) survived exactly"
  dlfcheck "DimP0 = 0,0,0" "the rotated dimension's first measured point (DefPoint1) survived exactly"
  dlfcheck "DimP1 = 40,0,0" "the rotated dimension's second measured point (DefPoint2) survived exactly"
  dlfcheck "Length: 40" "the rotated dimension's own dimension line measures the exact hand-computed distance (40,0,0 - 0,0,0)"
  dlfcheck "Annotation = DimAligned" "the aligned dimension carries the same Annotation=DimAligned tag a live DimAligned command/DXF DIMENSION import already write"
  dlfcheck "DimAligned = 1" "the aligned dimension is still recognized as aligned, not rotated"
  dlfcheck "DimOffset = 5" "the aligned dimension's own perpendicular offset (5, projected from DimlinePoint onto the plane normal x measured direction) survived exactly"
  dlfcheck "DimP1 = 30,30,0" "the aligned dimension's second measured point (DefPoint2) survived exactly"
  dlfcheck "Length: 42.4264" "the aligned dimension's own dimension line measures the exact hand-computed diagonal distance (30*sqrt(2))"
  dlfcheck "Annotation = DimRadius" "the radius dimension carries the same Annotation=DimRadius tag a live DimRadius command/DXF DIMENSION import already write"
  dlfcheck "DimCenter = 100,0,0" "the radius dimension's own measured center (CenterPoint) survived exactly"
  dlfcheck "DimRadiusVal = 5" "the radius dimension's own measured radius (CenterPoint to RadiusPoint distance) survived exactly"
  dlfcheck "DimIsDiameter = 0" "the radius dimension is still recognized as a radius, not a diameter, dimension"
  dlfcheck "DimExtra = 5" "the radius dimension's own leader-tail overrun (DimlinePoint projected past RadiusPoint) survived exactly"
  dlfcheck "Annotation = DimDiameter" "the diameter dimension carries the same Annotation=DimDiameter tag a live DimDiameter command/DXF DIMENSION import already write"
  dlfcheck "DimCenter = 200,0,0" "the diameter dimension's own measured center survived exactly"
  dlfcheck "DimRadiusVal = 3" "the diameter dimension's own measured radius (half the true 6-unit diameter) survived exactly"
  dlfcheck "DimIsDiameter = 1" "the diameter dimension is still recognized as a diameter, not a radius, dimension"
  dlfcheck "Length: 4.02838" "an arrowhead curve measures 2.688 x 1.5 (AddArrow's fixed triangle shape x the file's own custom ON_DimStyle text height), proving that custom height - not ON_DimStyle::Default's differing 1.0 - was actually resolved via DimensionStyleId()"
  dlfcheck "Annotation = Leader" "the leader carries the same Annotation=Leader tag a live Leader command/BuildLeaderGroup already write"
  dlfcheck "LeaderTip = 300,0,0" "the leader's own arrowhead point (ON_Leader's first point) survived exactly"
  dlfcheck "LeaderRest = 5,5,0;15,5,0" "the leader's bend point (305,5,0) and tail/text-landing point (315,5,0), recorded as fixed offsets from the tip per BuildLeaderGroup's own convention, survived exactly"
  dlfcheck "Annotation = DimAngle" "the angular dimension carries the same Annotation=DimAngle tag a live DimAngle command/DXF-DWG DIMENSION_ANG3PT import already write"
  dlfcheck "DimP0 = 400,0,0" "the angular dimension's own vertex (CenterPoint) survived exactly"
  dlfcheck "DimP1 = 410,0,0" "the angular dimension's own first extension point (DefPoint1) survived exactly"
  dlfcheck "DimP2 = 400,10,0" "the angular dimension's own second extension point (DefPoint2) survived exactly"
  dlfcheck "UpdateDimensions:   Leader now points at 300,0,0" "UpdateDimensions re-derived the leader's own tip from its tags alone, proving it round-trips as a genuinely live, rebuildable leader exactly like one made in-app, not just a one-shot baked import"
  dlfcheck "UpdateDimensions:   DimAngle now measures 90 deg" "UpdateDimensions re-derived the exact hand-computed 90-degree angle between DefPoint1/DefPoint2 from the angular dimension's own tags alone"
  dlfcheck "Annotation = Centermark" "the centermark carries the same Annotation=Centermark tag a live Centermark command/BuildCentermarkGroup already write"
  dlfcheck "CenterCenter = 600,0,0" "the centermark's own center point (CenterPoint, resolved through its plane) survived exactly"
  dlfcheck "CenterSize = 0.6" "the centermark's own drawn size came from the file's real stored CenterMark dimstyle field (0.6), not a quarter of the marked circle's radius (8/4=2) which this fixture deliberately set apart to catch that mistake"
  dlfcheck "CenterSizeMode = Fixed" "the imported centermark records Fixed mode (no live Dino8 circle object of its own to derive an Auto quarter-radius size from, same as every other imported annotation's own \"no Dino8 object to reference\" fallback)"
  dlfcheck "UpdateDimensions:   Centermark now at 600,0,0" "UpdateDimensions re-derived the centermark's own center from its tags alone (ResolveCentermarkGeom's static-tag fallback path, since there is no DimRefObj1), proving it round-trips as a genuinely live, rebuildable centermark exactly like one made in-app, not just a one-shot baked import"
  dlfcheck "UpdateDimensions: 7 dimension(s) regenerated" "all seven UpdateDimensions-owned imported dimensions/leaders/centermark (2 linear, 2 radial, 1 leader, 1 angular, 1 centermark) are genuinely live and rebuildable, not just baked geometry with no record of their own kind - the ordinate is deliberately not among these 7 (see the UpdateMeasureDims check below)"
  dlfcheck "Annotation = DimOrdinate" "the ordinate dimension carries the same Annotation=DimOrdinate tag a live DimOrdinate command/BuildOrdinateDimGroup already write"
  dlfcheck "DimOrdinateDir = X" "the ordinate dimension's own measured direction (ON_DimOrdinate::MeasuredDirection::Xaxis) survived exactly"
  dlfcheck "DimP0 = 500,0,0" "the ordinate dimension's own base/reference point (Get3dBasePoint) survived exactly"
  dlfcheck "DimP1 = 520,8,0" "the ordinate dimension's own measured feature point (Get3dDefPt) survived exactly"
  dlfcheck "UpdateMeasureDims:   DimOrdinate now X 20" "UpdateMeasureDims (not UpdateDimensions - DimOrdinate is one of its own owned kinds, same split a live DimOrdinate already has) re-derived the exact hand-computed value (520 - 500 = 20 along the plane's own X axis) from the ordinate dimension's own tags alone, proving it round-trips exactly like a live DimOrdinate"
  dlfcheck "UpdateMeasureDims: 1 updated, 0 skipped" "the single imported ordinate dimension updated cleanly, with nothing skipped"
else
  echo "FAIL dimlinear3dm_fixture_gen was not built next to $BIN (DINO8_BUILD_TESTS off?) - skipping the .3dm ON_DimLinear/ON_DimRadial/ON_Leader/ON_DimAngular/ON_DimOrdinate/ON_Centermark fixture check"
  fail=1
fi

# Plug-in Marketplace, end to end through the real in-app command flow (see
# plugin-index/SCHEMA.md, src/plugins/Marketplace.cpp,
# src/commands/cmd_flow.cpp's PluginMarketplace* commands): load the real
# reference index shipped at plugin-index/index.json, list what it found,
# install HelloDino from it, and prove the install was a real, independent
# second load (not just a print statement) - GrasshopperPluginList must
# show exactly one more "HelloDino" entry after the install than before
# (the first is HelloDino auto-loaded from next to the executable, same as
# every other sample plug-in; the second is the copy PluginMarketplaceInstall
# just fetched into <config>/plugins and loaded) - and then that the
# installed copy's own registered command actually runs (a fresh point
# object appears, so the final smoke line reports objects=1).
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_script.txt" > "$TMPW/plugin_marketplace_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PM="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_script.txt" 2>&1)" || { echo "$PM"; echo "FAIL: plugin marketplace script exited non-zero"; exit 1; }
else
  PM="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_script.txt" 2>&1)" || { echo "$PM"; echo "FAIL: plugin marketplace script exited non-zero"; exit 1; }
fi
pmcheck() { if echo "$PM" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PM" "$1"; fail=1; fi; }
pmcheck "PluginMarketplaceIndex: loaded \"Dino 8 Reference Plugin Index\" - 4 plug-in(s)" "PluginMarketplaceIndex loaded the real reference index"
pmcheck "PluginMarketplaceList: 4 plug-in(s) in the loaded index" "PluginMarketplaceList reports all 4 entries"
pmcheck "  hellodino: HelloDino 1.0.0 by Dino 8 Project (api v2, compatible)" "PluginMarketplaceList reports HelloDino as compatible"
# PluginMarketplaceList's filter (MatchesFilter in src/plugins/MarketplaceIndex.cpp,
# shared with the panel's own filter box): "mesh" matches only meshtools (its
# id, name, description and "mesh" tag all contain it), "sample" is a tag
# every one of the 4 sample entries carries, and a filter matching nothing
# reports 0 rather than silently falling back to the unfiltered list.
pmcheck "PluginMarketplaceList: 1 of 4 plug-in(s) match \"mesh\"" "PluginMarketplaceList's filter narrows to the one entry mentioning \"mesh\""
pmcheck "  meshtools: MeshTools 1.0.0 by Dino 8 Project (api v2, compatible)" "the \"mesh\" filter's one match is meshtools itself"
pmcheck "PluginMarketplaceList: 4 of 4 plug-in(s) match \"sample\"" "PluginMarketplaceList's filter matches all 4 entries on their shared \"sample\" tag"
pmcheck "PluginMarketplaceList: 0 of 4 plug-in(s) match \"doesnotexist123\"" "PluginMarketplaceList's filter reports 0 matches for text nothing contains, not the full list"
pmcheck "PluginMarketplaceInstall: installed hellodino - 1 command(s), 1 flow node(s) registered" "PluginMarketplaceInstall installed HelloDino and reports what it registered"
pmcheck "HelloDino: hello, MarketplaceTest! (from the sample plug-in)" "the freshly marketplace-installed HelloDino copy's own command actually runs"
pmcheck "objects=1 " "HelloDino's command added exactly the one point object it always adds"
PM_BEFORE="$(echo "$PM" | sed -n '1,/PluginMarketplaceInstall:/p' | grep -c '  HelloDino 1.0.0 -' || true)"
PM_AFTER="$(echo "$PM" | sed -n '/PluginMarketplaceInstall:/,$p' | grep -c '  HelloDino 1.0.0 -' || true)"
if [ "$PM_BEFORE" = "1" ] && [ "$PM_AFTER" = "2" ]; then
  echo "ok   PluginMarketplaceInstall added a genuine second, independent load of HelloDino (1 auto-loaded from next to the executable, 2 after installing the marketplace's copy into <config>/plugins) - not just a print statement"
else
  echo "FAIL PluginMarketplaceInstall did not produce a second independently-loaded HelloDino (saw $PM_BEFORE before, $PM_AFTER after)"; fail=1
fi

# Plug-in Marketplace: a crafted index entry cannot use library_filename to
# escape <config>/plugins (see IsPlainFilename in src/plugins/Marketplace.cpp).
# Regression for a path-traversal bug: InstallEntry used to copy the plug-in
# to fs::path(dest_dir) / entry.library_filename with no check at all, so an
# index entry (loadable from an arbitrary http(s) URL via
# PluginMarketplaceIndex/the marketplace panel) with library_filename
# "../../escaped_canary.so" would write that file two directories above
# <config>/plugins - i.e. straight into <config>, outside the plugins
# sandbox entirely - rather than being refused.
CANARY="$XDG_CONFIG_HOME/escaped_canary.so"
rm -f "$CANARY"
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_traversal_script.txt" > "$TMPW/plugin_marketplace_traversal_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMT="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_traversal_script.txt" 2>&1)" || { echo "$PMT"; echo "FAIL: plugin marketplace traversal script exited non-zero"; exit 1; }
else
  PMT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_traversal_script.txt" 2>&1)" || { echo "$PMT"; echo "FAIL: plugin marketplace traversal script exited non-zero"; exit 1; }
fi
pmtcheck() { if echo "$PMT" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMT" "$1"; fail=1; fi; }
pmtcheck "PluginMarketplaceIndex: loaded \"Malicious Test Index (path traversal regression fixture)\" - 1 plug-in(s)" "PluginMarketplaceIndex loaded the crafted traversal-attempt index"
pmtcheck "! PluginMarketplaceInstall: EvilFilename: library_filename \"../../escaped_canary.so\" is not a plain filename - refusing to install outside <config>/plugins" "PluginMarketplaceInstall refuses a library_filename that tries to escape <config>/plugins"
if [ -e "$CANARY" ]; then
  echo "FAIL PluginMarketplaceInstall's library_filename check did not stop a path-traversal write - $CANARY was created outside <config>/plugins"; fail=1
else
  echo "ok   PluginMarketplaceInstall's crafted library_filename left no file outside <config>/plugins ($CANARY was never created)"
fi

# Plug-in Marketplace: min_app_version is enforced, not just informational
# (CheckCompatibility in src/plugins/MarketplaceIndex.cpp takes the running
# DINO8_VERSION and reports AppTooOld when an entry requires a newer one;
# InstallEntry in src/plugins/Marketplace.cpp refuses to install such an
# entry, the same way it already refused an api_version that's too new).
# tests/plugin_marketplace_appversion_index.json's futureplugin declares
# min_app_version 99.0.0, far ahead of any real release, so both
# PluginMarketplaceList's compatibility label and PluginMarketplaceInstall's
# refusal must reflect it.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_appversion_script.txt" > "$TMPW/plugin_marketplace_appversion_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMV="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_appversion_script.txt" 2>&1)" || { echo "$PMV"; echo "FAIL: plugin marketplace app-version script exited non-zero"; exit 1; }
else
  PMV="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_appversion_script.txt" 2>&1)" || { echo "$PMV"; echo "FAIL: plugin marketplace app-version script exited non-zero"; exit 1; }
fi
pmvcheck() { if echo "$PMV" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMV" "$1"; fail=1; fi; }
pmvcheck "PluginMarketplaceIndex: loaded \"App Version Test Index (min_app_version enforcement fixture)\" - 1 plug-in(s)" "PluginMarketplaceIndex loaded the app-version-fixture index"
pmvcheck "  futureplugin: FuturePlugin 1.0.0 by Dino 8 Project (api v1, needs Dino 8 99.0.0 or newer, this build is" "PluginMarketplaceList shows the specific min_app_version a too-high entry requires (CompatibilityReason), not just a generic \"needs newer Dino 8\""
pmvcheck "! PluginMarketplaceInstall: FuturePlugin needs Dino 8 99.0.0 or newer, this build is" "PluginMarketplaceInstall refuses to install an entry whose min_app_version exceeds this build's own version"

# Plug-in Marketplace: version checking/update notifications
# (Marketplace::CheckForUpdates, PluginMarketplaceCheckUpdates - see
# src/plugins/MarketplaceIndex.cpp's CompareVersions/CheckForUpdate and
# src/plugins/Marketplace.cpp's FindInstalled/CheckForUpdates). HelloDino is
# already loaded (auto-loaded from next to the executable at 1.0.0, same as
# every other sample plug-in - see the marketplace install check above)
# before any index is loaded, so the first PluginMarketplaceCheckUpdates has
# nothing to compare against; loading an index whose hellodino entry claims
# version 1.1.0 must then flag that same installed 1.0.0 copy as out of date.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_update_script.txt" > "$TMPW/plugin_marketplace_update_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMU="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_update_script.txt" 2>&1)" || { echo "$PMU"; echo "FAIL: plugin marketplace update script exited non-zero"; exit 1; }
else
  PMU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_update_script.txt" 2>&1)" || { echo "$PMU"; echo "FAIL: plugin marketplace update script exited non-zero"; exit 1; }
fi
pmucheck() { if echo "$PMU" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMU" "$1"; fail=1; fi; }
pmucheck "PluginMarketplaceCheckUpdates: all installed plug-ins are up to date with the loaded index" "PluginMarketplaceCheckUpdates reports no updates before any index is loaded (nothing to compare against)"
pmucheck "PluginMarketplaceCheckUpdates: 1 update(s) available" "PluginMarketplaceCheckUpdates finds exactly one update once the bumped-version index is loaded"
pmucheck "  hellodino: HelloDino 1.0.0 -> 1.1.0" "PluginMarketplaceCheckUpdates reports the installed and available versions for the out-of-date plug-in"

# Plug-in Marketplace: loading the bundled reference index with no path or
# URL typed in (Application::DefaultMarketplaceIndexPath,
# PluginMarketplaceIndex with no argument - see plugin-index/SCHEMA.md's
# "Loading the bundled reference index without a path" section).
# CMakeLists.txt's POST_BUILD step copies plugin-index/index.json to
# data/plugin-index/index.json right next to this very $BIN, so
# DefaultMarketplaceIndexPath's first candidate (<exe_dir>/data/plugin-index/index.json)
# is exactly where it lands - this only works end to end through the real
# built binary, not the standalone dino8_test_plugin_marketplace unit test.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_default_script.txt" > "$TMPW/plugin_marketplace_default_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMDEF="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_default_script.txt" 2>&1)" || { echo "$PMDEF"; echo "FAIL: plugin marketplace default-index script exited non-zero"; exit 1; }
else
  PMDEF="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_default_script.txt" 2>&1)" || { echo "$PMDEF"; echo "FAIL: plugin marketplace default-index script exited non-zero"; exit 1; }
fi
pmdefcheck() { if echo "$PMDEF" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMDEF" "$1"; fail=1; fi; }
pmdefcheck "PluginMarketplaceIndex: loaded \"Dino 8 Reference Plugin Index\" - 4 plug-in(s) from" "PluginMarketplaceIndex with no argument falls back to the bundled reference index"
pmdefcheck "PluginMarketplaceList: 4 plug-in(s) in the loaded index" "the bundled default index loaded is the real one (all 4 reference entries), not an empty placeholder"

# Plug-in Marketplace: PluginMarketplaceInstallAll/Marketplace::InstallAll -
# installs every entry FindInstalled doesn't already match to a loaded
# plug-in, in one call, reusing the same InstallById a single row's Install
# button already goes through - the batch counterpart to
# PluginMarketplaceUpdateAll (which only ever handles what's already
# installed). With no index loaded there is nothing to install
# (mirrors PluginMarketplaceUpdateAll's own "up to date"/"nothing to do"
# wording for the same 0-entries case). tests/plugin_marketplace_installall_index.json
# has three entries: alpha and beta, each declaring a library_filename no
# other tests/*.json fixture writes to (so neither can already be sitting
# installed from an earlier smoke.sh section sharing this same
# $XDG_CONFIG_HOME), and futuregamma, whose min_app_version is far ahead of
# any real Dino 8 release - proving one incompatible entry in the batch
# doesn't stop the other two from installing.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_installall_script.txt" > "$TMPW/plugin_marketplace_installall_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMIA="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_installall_script.txt" 2>&1)" || { echo "$PMIA"; echo "FAIL: plugin marketplace install-all script exited non-zero"; exit 1; }
else
  PMIA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_installall_script.txt" 2>&1)" || { echo "$PMIA"; echo "FAIL: plugin marketplace install-all script exited non-zero"; exit 1; }
fi
pmiacheck() { if echo "$PMIA" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMIA" "$1"; fail=1; fi; }
pmiacheck "PluginMarketplaceInstallAll: everything in the loaded index is already installed" "PluginMarketplaceInstallAll reports nothing to do before any index is loaded"
pmiacheck "PluginMarketplaceIndex: loaded \"Install-All Test Index (batch install fixture)\" - 3 plug-in(s)" "PluginMarketplaceIndex loaded the install-all fixture"
pmiacheck "PluginMarketplaceInstallAll: installed 2 plug-in(s) (alpha, beta)" "PluginMarketplaceInstallAll installs both alpha and beta in one call, in the loaded index's own order"
pmiacheck "! PluginMarketplaceInstallAll: futuregamma: FutureGamma needs Dino 8 99.0.0 or newer, this build is" "PluginMarketplaceInstallAll reports futuregamma's compatibility failure without stopping alpha/beta from installing"
# alpha/beta's own library_filename destinations are never written by any
# other fixture in this suite, so neither can already be loaded from a
# leftover install before this script's own PluginMarketplaceInstallAll
# runs; the first GrasshopperPluginList (before the fixture is even loaded)
# establishes whatever baseline count of HelloDino/CurveTools loads earlier
# smoke.sh sections already left behind at their OWN (different) leftover
# destinations (the exact number isn't asserted, only that PluginMarketplaceInstallAll
# adds exactly one more of each) - the same "genuine second, independent
# load, not just a print statement" proof the very first marketplace
# install test above uses, expressed as a delta rather than an absolute
# count so it isn't coupled to exactly what state earlier sections leave
# behind. The script's own trailing PluginMarketplaceUninstall alpha/beta
# then removes both again, so later sections' own absolute HelloDino/
# CurveTools counts aren't shifted by this section having run.
IA_BEFORE_HELLO="$(echo "$PMIA" | sed -n '1,/PluginMarketplaceIndex: loaded/p' | grep -c '  HelloDino 1.0.0 -' || true)"
IA_AFTER_HELLO="$(echo "$PMIA" | sed -n '/PluginMarketplaceInstallAll: installed 2/,$p' | grep -c '  HelloDino 1.0.0 -' || true)"
if [ "$IA_AFTER_HELLO" = "$((IA_BEFORE_HELLO + 1))" ]; then
  echo "ok   PluginMarketplaceInstallAll genuinely installed and loaded alpha's HelloDino copy ($IA_BEFORE_HELLO before, $IA_AFTER_HELLO after), not just a print statement"
else
  echo "FAIL PluginMarketplaceInstallAll did not produce exactly one more independently-loaded HelloDino for alpha (saw $IA_BEFORE_HELLO before, $IA_AFTER_HELLO after)"; fail=1
fi
IA_BEFORE_CURVE="$(echo "$PMIA" | sed -n '1,/PluginMarketplaceIndex: loaded/p' | grep -c '  CurveTools 1.0.0 -' || true)"
IA_AFTER_CURVE="$(echo "$PMIA" | sed -n '/PluginMarketplaceInstallAll: installed 2/,$p' | grep -c '  CurveTools 1.0.0 -' || true)"
if [ "$IA_AFTER_CURVE" = "$((IA_BEFORE_CURVE + 1))" ]; then
  echo "ok   PluginMarketplaceInstallAll genuinely installed and loaded beta's CurveTools copy ($IA_BEFORE_CURVE before, $IA_AFTER_CURVE after), not just a print statement"
else
  echo "FAIL PluginMarketplaceInstallAll did not produce exactly one more independently-loaded CurveTools for beta (saw $IA_BEFORE_CURVE before, $IA_AFTER_CURVE after)"; fail=1
fi
pmiacheck "PluginMarketplaceUninstall: uninstalled alpha" "the script cleans up its own alpha install afterward, so later sections' own HelloDino/CurveTools counts aren't shifted by this section having run"
pmiacheck "PluginMarketplaceUninstall: uninstalled beta" "the script cleans up its own beta install afterward too"

# Plug-in Marketplace: PluginMarketplaceUpdateAll/Marketplace::UpdateAll -
# installs every out-of-date entry PluginMarketplaceCheckUpdates would report,
# in one call, reusing the same InstallById a single row's Update button
# already goes through. With no index loaded there is nothing to update
# (mirrors PluginMarketplaceCheckUpdates' own "up to date" wording); loading
# tests/plugin_marketplace_update_index.json's bumped hellodino entry (same
# fixture the update-notification check above uses) gives it exactly one
# real update to apply.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_updateall_script.txt" > "$TMPW/plugin_marketplace_updateall_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMUA="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_updateall_script.txt" 2>&1)" || { echo "$PMUA"; echo "FAIL: plugin marketplace update-all script exited non-zero"; exit 1; }
else
  PMUA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_updateall_script.txt" 2>&1)" || { echo "$PMUA"; echo "FAIL: plugin marketplace update-all script exited non-zero"; exit 1; }
fi
pmuacheck() { if echo "$PMUA" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMUA" "$1"; fail=1; fi; }
pmuacheck "PluginMarketplaceUpdateAll: all installed plug-ins are up to date with the loaded index" "PluginMarketplaceUpdateAll reports nothing to do before any index is loaded"
pmuacheck "PluginMarketplaceCheckUpdates: 1 update(s) available" "the bumped-version index flags hellodino as out of date, same as the plain CheckUpdates test above"
pmuacheck "PluginMarketplaceUpdateAll: updated 1 plug-in(s) (hellodino)" "PluginMarketplaceUpdateAll installs the one out-of-date entry it found and reports its id"
# Not re-checked here: a load-count "genuine install, not just a print
# statement" proof like the plain install test above uses. hellodino's own
# <config>/plugins destination was already installed once and never
# uninstalled by the very first marketplace section above, and XDG_CONFIG_HOME
# (set once at the top of this script) is shared for this whole smoke.sh run -
# ScanDefaultFolders (src/plugins/PluginManager.cpp) scans that folder on
# every fresh process, so hellodino is already loaded twice (sample
# auto-load + that leftover marketplace copy) before this section's process
# even starts. InstallEntry's own Unload-then-copy-then-load (Marketplace.cpp)
# means UpdateAll genuinely replaces that leftover copy in place rather than
# adding a third load, so a load-count delta isn't a meaningful signal here
# specifically - InstallById's own "not just a print statement" proof is
# already covered independently by the plain install/dependency/deepchain
# tests above, each running before any prior section has touched their own
# ids' destinations.

# Plug-in Marketplace: PluginMarketplaceVerify/Marketplace::VerifyInstalled -
# re-hashes the file currently installed at an id's own marketplace
# destination and compares it against the loaded index entry's sha256, on
# demand (see plugin-index/SCHEMA.md's "Verifying an installed copy"
# section). Exercises every branch that doesn't require knowing the real
# built library's own hash ahead of time: an id missing from the loaded
# index (both with no index loaded at all and with the real reference index
# loaded), an id that's only auto-loaded as a sample (never installed via
# the marketplace), an installed entry with no sha256 in the index to check
# (plugin-index/index.json's real hellodino entry - a bundled_path entry is
# never sha256-checked at install time either), and a deliberately wrong
# sha256 (tests/plugin_marketplace_verify_index.json) against the real
# installed file, which can only ever mismatch. The exact-match "Verified"
# branch - which needs the real build's own sha256 hard-coded into a fixture
# - is left untested here for the same reason download_url's own sha256
# check is (see plugin-index/SCHEMA.md's "download_url vs bundled_path"
# section): both call the identical util::Sha256HexOfFile/EqualsIgnoreCase
# primitives already exercised by the mismatch case below.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_verify_script.txt" > "$TMPW/plugin_marketplace_verify_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMVER="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_verify_script.txt" 2>&1)" || { echo "$PMVER"; echo "FAIL: plugin marketplace verify script exited non-zero"; exit 1; }
else
  PMVER="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_verify_script.txt" 2>&1)" || { echo "$PMVER"; echo "FAIL: plugin marketplace verify script exited non-zero"; exit 1; }
fi
pmvercheck() { if echo "$PMVER" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMVER" "$1"; fail=1; fi; }
pmvercheck "! PluginMarketplaceVerify: no plugin with id \"doesnotexist\" in the loaded index (0 entries)" "PluginMarketplaceVerify refuses an unknown id with no index loaded"
pmvercheck "! PluginMarketplaceVerify: no plugin with id \"doesnotexist2\" in the loaded index (4 entries)" "PluginMarketplaceVerify refuses an unknown id once the real reference index is loaded"
pmvercheck "! PluginMarketplaceVerify: MeshTools (meshtools) is not currently installed via the marketplace" "PluginMarketplaceVerify reports a sample-auto-loaded-only plug-in as not installed via the marketplace"
pmvercheck "PluginMarketplaceVerify: HelloDino (hellodino) has no sha256 in the loaded index to verify against (bundled_path entries aren't hash-checked)" "PluginMarketplaceVerify reports NoHashToCheck (not a failure) for the real reference index's hellodino entry, once installed"
pmvercheck "! PluginMarketplaceVerify: HelloDino (hellodino): sha256 mismatch - index says 0000000000000000000000000000000000000000000000000000000000000000, installed file at" "PluginMarketplaceVerify catches a deliberately wrong sha256 against the real installed file"
pmvercheck "(corrupted, tampered with, or replaced outside the marketplace)" "PluginMarketplaceVerify's mismatch message explains what a mismatch could mean"

# Plug-in Marketplace: PluginMarketplaceVerifyAll/Marketplace::VerifyAll -
# VerifyInstalled run once for every entry actually installed via the
# marketplace, the batch counterpart to the single-id PluginMarketplaceVerify
# tested just above (and to PluginMarketplaceUpdateAll's own batching of
# per-id Update). tests/plugin_marketplace_verifyall_index.json has three
# entries: hellodino (no sha256 - NoHashToCheck once installed), meshtools (a
# deliberately wrong sha256 - Mismatch once installed), and curvetools (never
# installed by this script - proving VerifyAll only reports on what's
# actually installed, not every entry in the loaded index).
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_verifyall_script.txt" > "$TMPW/plugin_marketplace_verifyall_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMVA="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_verifyall_script.txt" 2>&1)" || { echo "$PMVA"; echo "FAIL: plugin marketplace verify-all script exited non-zero"; exit 1; }
else
  PMVA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_verifyall_script.txt" 2>&1)" || { echo "$PMVA"; echo "FAIL: plugin marketplace verify-all script exited non-zero"; exit 1; }
fi
pmvacheck() { if echo "$PMVA" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMVA" "$1"; fail=1; fi; }
pmvacheck "PluginMarketplaceVerifyAll: nothing installed via the marketplace to verify" "PluginMarketplaceVerifyAll reports nothing to check before any index is loaded"
pmvacheck "PluginMarketplaceIndex: loaded \"Verify-All Test Index (batch sha256 integrity-check fixture)\" - 3 plug-in(s)" "PluginMarketplaceIndex loaded the verify-all fixture"
# Not asserted here: that VerifyAll still reports "nothing installed" right
# after loading the index but before this script's own two installs below.
# hellodino is this same shared XDG_CONFIG_HOME's very first marketplace
# test's own leftover install (never uninstalled since, by design - see that
# section's own comments) and this fixture also names a "hellodino" entry,
# so that intermediate call may legitimately already see it as installed -
# which this script's own explicit PluginMarketplaceInstall hellodino below
# then simply reinstalls in place either way, so the final assertions below
# hold regardless of that leftover state.
pmvacheck "PluginMarketplaceVerifyAll: HelloDino (hellodino) has no sha256 in the loaded index to verify against (bundled_path entries aren't hash-checked)" "PluginMarketplaceVerifyAll reports NoHashToCheck for hellodino once installed, in the same batch as meshtools' mismatch"
pmvacheck "! PluginMarketplaceVerifyAll: MeshTools (meshtools): sha256 mismatch - index says 1111111111111111111111111111111111111111111111111111111111111111, installed file at" "PluginMarketplaceVerifyAll catches meshtools' deliberately wrong sha256 in the same batch"
pmvacheck "PluginMarketplaceVerifyAll: checked 2 installed plug-in(s) - 1 mismatch(es)" "PluginMarketplaceVerifyAll's summary line counts exactly the 2 installed entries (not curvetools, never installed) and the 1 mismatch among them"

# Plug-in Marketplace: local ratings/reviews (src/plugins/PluginReviews.cpp,
# PluginMarketplaceRate/PluginMarketplaceReviews in src/commands/cmd_flow.cpp)
# - stored in <config>/plugin_reviews.json, not fetched from anywhere, so a
# fresh $XDG_CONFIG_HOME (set once at the top of this script) starts with
# nothing rated. Two valid ratings for hellodino must average to 4/5, an
# out-of-range rating (12) must be refused and must not get counted, and the
# ratings must show up in the Marketplace panel's own "Rating" column data
# (RatingSummary in MarketplacePanel.cpp) the same way PluginMarketplaceList
# already proves the table's other columns.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_reviews_script.txt" > "$TMPW/plugin_marketplace_reviews_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMR="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_reviews_script.txt" 2>&1)" || { echo "$PMR"; echo "FAIL: plugin marketplace reviews script exited non-zero"; exit 1; }
else
  PMR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_reviews_script.txt" 2>&1)" || { echo "$PMR"; echo "FAIL: plugin marketplace reviews script exited non-zero"; exit 1; }
fi
pmrcheck() { if echo "$PMR" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMR" "$1"; fail=1; fi; }
pmrcheck "PluginMarketplaceReviews: hellodino has no reviews yet" "PluginMarketplaceReviews reports no reviews before any rating is added"
pmrcheck "PluginMarketplaceRate: recorded a 5/5 rating for hellodino" "PluginMarketplaceRate records Alice's 5/5 rating"
pmrcheck "PluginMarketplaceRate: recorded a 3/5 rating for hellodino" "PluginMarketplaceRate records the second, anonymous 3/5 rating"
pmrcheck "! PluginMarketplaceRate: rating must be between 1 and 5, got 12" "PluginMarketplaceRate refuses an out-of-range rating (12)"
pmrcheck "PluginMarketplaceReviews: hellodino - 2 review(s), average 4" "PluginMarketplaceReviews averages only the 2 valid ratings ((5+3)/2 == 4), not the rejected one"
pmrcheck "  [0] Alice: 5/5 - Works great" "PluginMarketplaceReviews lists Alice's named review with its comment, tagged with its [index] for PluginMarketplaceDeleteReview"
pmrcheck "  [1] Anonymous: 3/5 - A bit slow on big meshes" "PluginMarketplaceReviews lists the second review as Anonymous (no Reviewer= given) at index [1]"
REVIEWS_FILE="$CONFIG_DIR/plugin_reviews.json"
if [ -f "$REVIEWS_FILE" ] && grep -q "hellodino" "$REVIEWS_FILE" && grep -q "Alice" "$REVIEWS_FILE"; then
  echo "ok   ratings persisted to $REVIEWS_FILE, not just kept in memory"
else
  echo "FAIL $REVIEWS_FILE was not written with hellodino's ratings"; fail=1
fi

# Plug-in Marketplace: PluginMarketplaceDeleteReview/PluginReviewStore::DeleteReview
# - a separate script/process from the ratings one just above (rather than
# appended to it) so that section's own "ratings persisted to disk" check
# still finds hellodino/Alice on disk afterward instead of racing against
# this section's own deletions of that same file. Picks up the Alice/
# Anonymous reviews the script above just persisted to this same shared
# $XDG_CONFIG_HOME: an out-of-range index (5, only 0 and 1 exist) is refused
# and changes nothing; deleting index 0 (Alice's review) leaves just the
# Anonymous one, reindexed down to [0]; deleting that last remaining review
# empties hellodino out entirely, back to "has no reviews yet" - proving the
# delete actually mutates (and re-persists) the store, not just prints a
# claim.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_delete_review_script.txt" > "$TMPW/plugin_marketplace_delete_review_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMDR="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_delete_review_script.txt" 2>&1)" || { echo "$PMDR"; echo "FAIL: plugin marketplace delete-review script exited non-zero"; exit 1; }
else
  PMDR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_delete_review_script.txt" 2>&1)" || { echo "$PMDR"; echo "FAIL: plugin marketplace delete-review script exited non-zero"; exit 1; }
fi
pmdrcheck() { if echo "$PMDR" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMDR" "$1"; fail=1; fi; }
pmdrcheck "PluginMarketplaceReviews: hellodino - 2 review(s), average 4" "the delete-review script starts from the same 2 persisted reviews the ratings script above just wrote to disk"
pmdrcheck "! PluginMarketplaceDeleteReview: no review at index 5 for \"hellodino\" (2 review(s) on file)" "PluginMarketplaceDeleteReview refuses an out-of-range index and reports how many reviews actually exist"
pmdrcheck "PluginMarketplaceReviews: hellodino - 1 review(s), average 3" "only the Anonymous 3/5 review remains after deleting Alice's"
pmdrcheck "  [0] Anonymous: 3/5 - A bit slow on big meshes" "the surviving review shifted down to index [0] after the deletion"
pmdrcheck "PluginMarketplaceReviews: hellodino has no reviews yet" "deleting the last remaining review empties hellodino out, same wording as before anything was ever rated"
PMDR_REMOVED_COUNT="$(echo "$PMDR" | grep -c 'PluginMarketplaceDeleteReview: removed review \[0\] from hellodino' || true)"
if [ "$PMDR_REMOVED_COUNT" = "2" ]; then
  echo "ok   PluginMarketplaceDeleteReview genuinely removed both reviews, one call each (Alice, then the reindexed Anonymous), not just one claim repeated"
else
  echo "FAIL expected PluginMarketplaceDeleteReview to report 2 successful removals, saw $PMDR_REMOVED_COUNT"; fail=1
fi
if grep -q "hellodino" "$REVIEWS_FILE" 2>/dev/null; then
  echo "FAIL $REVIEWS_FILE still mentions hellodino after its last review was deleted"; fail=1
else
  echo "ok   deleting hellodino's last review dropped it from $REVIEWS_FILE entirely, not just in memory"
fi

# Plug-in Marketplace: dependency resolution (src/plugins/MarketplaceIndex.h's
# MarketplaceEntry::dependencies, resolved by Marketplace::InstallByIdChecked
# in src/plugins/Marketplace.cpp before the requested entry is installed).
# tests/plugin_marketplace_dependency_index.json's curvetools entry depends
# on meshtools, which - like every sample plug-in - is already auto-loaded
# from next to the executable, so installing curvetools must succeed without
# installing a second copy of meshtools (an already-satisfied dependency);
# its analysistools entry depends on an id absent from the index, so
# installing it must fail cleanly and install nothing (a missing
# dependency).
mkdir -p "$TMPW/plugindep"
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_dependency_script.txt" > "$TMPW/plugin_marketplace_dependency_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMD="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_dependency_script.txt" 2>&1)" || { echo "$PMD"; echo "FAIL: plugin marketplace dependency script exited non-zero"; exit 1; }
else
  PMD="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_dependency_script.txt" 2>&1)" || { echo "$PMD"; echo "FAIL: plugin marketplace dependency script exited non-zero"; exit 1; }
fi
pmdcheck() { if echo "$PMD" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMD" "$1"; fail=1; fi; }
pmdcheck "PluginMarketplaceIndex: loaded \"Dependency Test Index (plugin dependency resolution fixture)\" - 3 plug-in(s)" "PluginMarketplaceIndex loaded the dependency-fixture index"
pmdcheck "  curvetools: CurveTools 1.0.0 by Dino 8 Project (api v2, compatible) - requires meshtools" "PluginMarketplaceList shows curvetools' dependency on meshtools, not just its install-time resolution"
pmdcheck "  analysistools: AnalysisTools 1.0.0 by Dino 8 Project (api v2, compatible) - requires doesnotexist" "PluginMarketplaceList shows analysistools' dependency even though doesnotexist isn't in the index"
pmdcheck "! PluginMarketplaceInstall: AnalysisTools (analysistools) requires plug-in \"doesnotexist\", which is not in the loaded index" "PluginMarketplaceInstall refuses to install a plug-in whose dependency is missing from the index"
pmdcheck "PluginMarketplaceInstall: installed curvetools - 1 command(s), 3 flow node(s) registered" "PluginMarketplaceInstall installs a plug-in whose dependency is already satisfied"
# Split the transcript at each GrasshopperPluginList's own output: PMD_S1 is
# the baseline (before any marketplace action), PMD_S2 is after the failed
# analysistools install, PMD_S3 is after the successful curvetools install.
awk '/^history: GrasshopperPluginList: /{n++} {print > ("'"$TMPW"'/plugindep/sec" n ".txt")}' <<<"$PMD"
PMD_S1="$(cat "$TMPW/plugindep/sec1.txt" 2>/dev/null)"
PMD_S2="$(cat "$TMPW/plugindep/sec2.txt" 2>/dev/null)"
PMD_S3="$(cat "$TMPW/plugindep/sec3.txt" 2>/dev/null)"
AT1="$(echo "$PMD_S1" | grep -c 'AnalysisTools 1.0.0 -' || true)"
AT2="$(echo "$PMD_S2" | grep -c 'AnalysisTools 1.0.0 -' || true)"
if [ "$AT1" = "$AT2" ]; then
  echo "ok   the missing-dependency install left AnalysisTools's loaded-copy count unchanged ($AT1 -> $AT2) - nothing was installed"
else
  echo "FAIL AnalysisTools's loaded-copy count changed on a failed install ($AT1 -> $AT2)"; fail=1
fi
MT2="$(echo "$PMD_S2" | grep -c 'MeshTools 1.0.0 -' || true)"
MT3="$(echo "$PMD_S3" | grep -c 'MeshTools 1.0.0 -' || true)"
if [ "$MT2" = "$MT3" ]; then
  echo "ok   installing curvetools left MeshTools's loaded-copy count unchanged ($MT2 -> $MT3) - the already-satisfied dependency was not reinstalled"
else
  echo "FAIL installing curvetools changed MeshTools's loaded-copy count ($MT2 -> $MT3) - an already-satisfied dependency was reinstalled"; fail=1
fi
CT2="$(echo "$PMD_S2" | grep -c 'CurveTools 1.0.0 -' || true)"
CT3="$(echo "$PMD_S3" | grep -c 'CurveTools 1.0.0 -' || true)"
if [ "$CT2" = "1" ] && [ "$CT3" = "2" ]; then
  echo "ok   installing curvetools added its own genuine second, independent load (1 auto-loaded from next to the executable, 2 after the marketplace install) - not just skipped as already satisfied"
else
  echo "FAIL installing curvetools did not add its own independently-loaded copy (saw $CT2 before, $CT3 after)"; fail=1
fi

# Plug-in Marketplace: circular dependency detection (Marketplace::InstallByIdChecked's
# `chain` argument tracks the ids currently being resolved, so a dependency
# graph that cycles back on itself is caught as soon as it repeats an id,
# instead of recursing forever). tests/plugin_marketplace_circular_index.json's
# three entries form a cycle that isn't just a direct mutual pair
# (loopa -> loopb -> loopc -> loopa); installing loopa must fail cleanly,
# with nothing installed, rather than looping or crashing.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_circular_script.txt" > "$TMPW/plugin_marketplace_circular_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMC="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_circular_script.txt" 2>&1)" || { echo "$PMC"; echo "FAIL: plugin marketplace circular script exited non-zero"; exit 1; }
else
  PMC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_circular_script.txt" 2>&1)" || { echo "$PMC"; echo "FAIL: plugin marketplace circular script exited non-zero"; exit 1; }
fi
pmccheck() { if echo "$PMC" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMC" "$1"; fail=1; fi; }
pmccheck "PluginMarketplaceIndex: loaded \"Circular Dependency Test Index (plugin dependency resolution fixture)\" - 3 plug-in(s)" "PluginMarketplaceIndex loaded the circular-fixture index"
pmccheck "! PluginMarketplaceInstall: LoopA (loopa) is part of a circular dependency chain" "PluginMarketplaceInstall refuses to install a plug-in whose dependency graph cycles back on itself"
mkdir -p "$TMPW/plugincirc"
awk '/^history: GrasshopperPluginList: /{n++} {print > ("'"$TMPW"'/plugincirc/sec" n ".txt")}' <<<"$PMC"
PMC_S1="$(cat "$TMPW/plugincirc/sec1.txt" 2>/dev/null)"
PMC_S2="$(cat "$TMPW/plugincirc/sec2.txt" 2>/dev/null)"
for name in HelloDino MeshTools CurveTools; do
  c1="$(echo "$PMC_S1" | grep -c "$name 1.0.0 -" || true)"
  c2="$(echo "$PMC_S2" | grep -c "$name 1.0.0 -" || true)"
  if [ "$c1" = "$c2" ]; then
    echo "ok   the refused circular install left $name's loaded-copy count unchanged ($c1 -> $c2) - nothing was installed"
  else
    echo "FAIL $name's loaded-copy count changed on a refused circular install ($c1 -> $c2)"; fail=1
  fi
done

# Plug-in Marketplace: a valid multi-level dependency chain
# (tests/plugin_marketplace_deepchain_index.json's gadgettools -> gizmotools
# -> widgettools, none already satisfied) must resolve and install every
# link, in order, before the requested entry itself - not stop after just
# its immediate dependency.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_deepchain_script.txt" > "$TMPW/plugin_marketplace_deepchain_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMX="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_deepchain_script.txt" 2>&1)" || { echo "$PMX"; echo "FAIL: plugin marketplace deep-chain script exited non-zero"; exit 1; }
else
  PMX="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_deepchain_script.txt" 2>&1)" || { echo "$PMX"; echo "FAIL: plugin marketplace deep-chain script exited non-zero"; exit 1; }
fi
pmxcheck() { if echo "$PMX" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMX" "$1"; fail=1; fi; }
pmxcheck "PluginMarketplaceIndex: loaded \"Deep Chain Test Index (plugin dependency resolution fixture)\" - 3 plug-in(s)" "PluginMarketplaceIndex loaded the deep-chain-fixture index"
pmxcheck "PluginMarketplaceInstall: installed gadgettools" "PluginMarketplaceInstall installs the top of a 3-level dependency chain"
# Which of widgettools/gizmotools/gadgettools' own underlying sample plug-ins
# (hello_dino/mesh_tools/curve_tools) were already sitting in <config>/plugins
# from some earlier, unrelated smoke.sh section - and so already auto-loaded
# a second time before this script's own install even runs - varies with
# everything else this suite has done by this point; a loaded-copy *count*
# before/after isn't a stable signal here (installing over an
# already-config-installed path unloads and replaces it in place, a net-zero
# change - see Marketplace::InstallEntry's fix for the crash that used to
# happen here instead). What's stable regardless of that history is each
# sample plug-in's own one-line init banner, printed exactly once per real
# load: grep for it specifically between the install command and its own
# success line, proving all three chain levels actually loaded during BUT
# resolution, not just the top one.
PMX_INSTALL_SLICE="$(sed -n '/^history: Command: PluginMarketplaceInstall gadgettools$/,/^history: PluginMarketplaceInstall: installed gadgettools/p' <<<"$PMX")"
pmxdeepcheck() { if echo "$PMX_INSTALL_SLICE" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMX" "$1"; fail=1; fi; }
pmxdeepcheck "HelloDino sample plug-in loaded." "installing gadgettools resolved all the way down to widgettools (HelloDino) - the bottom of the chain"
pmxdeepcheck "MeshTools sample plug-in loaded (TerrainMesh command" "installing gadgettools resolved through gizmotools (MeshTools), the middle of the chain"
pmxdeepcheck "CurveTools sample plug-in loaded (SpiralPolyline command" "installing gadgettools loaded its own entry (CurveTools) after both dependencies"

# Plug-in Marketplace: uninstall, including cascading removal of a
# now-orphaned dependency (Marketplace::UninstallById/UninstallByIdChecked in
# src/plugins/Marketplace.cpp). tests/plugin_marketplace_uninstall_index.json
# sets up toolboxpro depending on both shareddeps and orphanlib, and
# othersuite depending on shareddeps too: uninstalling toolboxpro must remove
# orphanlib (nothing else needs it) but leave shareddeps in place (othersuite
# still does) - proving the cascade actually checks for other consumers
# rather than either never cascading or always cascading everything.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_uninstall_script.txt" > "$TMPW/plugin_marketplace_uninstall_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMUN="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_uninstall_script.txt" 2>&1)" || { echo "$PMUN"; echo "FAIL: plugin marketplace uninstall script exited non-zero"; exit 1; }
else
  PMUN="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_uninstall_script.txt" 2>&1)" || { echo "$PMUN"; echo "FAIL: plugin marketplace uninstall script exited non-zero"; exit 1; }
fi
pmuncheck() { if echo "$PMUN" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMUN" "$1"; fail=1; fi; }
pmuncheck "PluginMarketplaceIndex: loaded \"Uninstall Test Index (plugin dependency resolution fixture)\" - 4 plug-in(s)" "PluginMarketplaceIndex loaded the uninstall-fixture index"
pmuncheck "PluginMarketplaceInstall: installed othersuite" "PluginMarketplaceInstall installs othersuite (and, along the way, its shareddeps dependency)"
pmuncheck "PluginMarketplaceInstall: installed toolboxpro" "PluginMarketplaceInstall installs toolboxpro (and its orphanlib dependency; shareddeps is already installed)"
pmuncheck "PluginMarketplaceUninstall: uninstalled toolboxpro - also removed 1 now-orphaned dependency (orphanlib)" "PluginMarketplaceUninstall removes toolboxpro and cascades to orphanlib, by name, in one reported call"
pmuncheck "! PluginMarketplaceUninstall: OrphanLib (orphanlib) is not currently installed via the marketplace" "orphanlib is genuinely gone after the cascade - uninstalling it again fails, not just a printed claim"
pmuncheck "PluginMarketplaceUninstall: uninstalled shareddeps" "shareddeps genuinely survived toolboxpro's cascade (othersuite still needs it) - it can still be uninstalled on its own"
# Marketplace::UninstallById's own still_needed_by out-param (Marketplace.h/
# .cpp): a *direct* uninstall of a dependency (as opposed to one falling out
# of a cascade) is still allowed - the marketplace doesn't lock a shared
# dependency in place - but must now warn, since IsDependencyStillNeeded's
# cascade check never protects the id actually requested. othersuite is
# still installed and still declares shareddeps as a dependency at the
# moment shareddeps is uninstalled directly above, so that warning must
# name it.
pmuncheck "! PluginMarketplaceUninstall: OtherSuite still lists shareddeps as a dependency and may now be broken" "PluginMarketplaceUninstall warns that OtherSuite still depends on the plug-in just uninstalled directly"

# Plug-in Marketplace: PluginMarketplaceUninstallAll/Marketplace::UninstallAll -
# the batch counterpart to the single-id PluginMarketplaceUninstall tested
# just above (and to PluginMarketplaceUpdateAll's own batching of Install).
# Reuses the same tests/plugin_marketplace_uninstall_index.json fixture and
# its othersuite/toolboxpro/shareddeps/orphanlib dependency graph: installing
# both othersuite and toolboxpro leaves all four entries installed (shareddeps
# and orphanlib pulled in as dependencies), and a single UninstallAll must
# remove all four in one call - proving it dedupes an id an earlier target's
# own cascade already removed (shareddeps/orphanlib) rather than reattempting
# it and reporting a spurious failure.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_uninstallall_script.txt" > "$TMPW/plugin_marketplace_uninstallall_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMUNA="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_uninstallall_script.txt" 2>&1)" || { echo "$PMUNA"; echo "FAIL: plugin marketplace uninstall-all script exited non-zero"; exit 1; }
else
  PMUNA="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_uninstallall_script.txt" 2>&1)" || { echo "$PMUNA"; echo "FAIL: plugin marketplace uninstall-all script exited non-zero"; exit 1; }
fi
pmunacheck() { if echo "$PMUNA" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMUNA" "$1"; fail=1; fi; }
pmunacheck "PluginMarketplaceUninstallAll: nothing installed via the marketplace to uninstall" "PluginMarketplaceUninstallAll reports nothing to do before any index is loaded"
pmunacheck "PluginMarketplaceIndex: loaded \"Uninstall Test Index (plugin dependency resolution fixture)\" - 4 plug-in(s)" "PluginMarketplaceIndex loaded the uninstall-fixture index for the uninstall-all script"
pmunacheck "PluginMarketplaceInstall: installed othersuite" "PluginMarketplaceUninstallAll script installs othersuite (and shareddeps) first"
pmunacheck "PluginMarketplaceInstall: installed toolboxpro" "PluginMarketplaceUninstallAll script installs toolboxpro (and orphanlib) too"
# The script's own two installs above leave exactly othersuite/shareddeps/
# orphanlib/toolboxpro installed, regardless of whatever this same shared
# XDG_CONFIG_HOME's earlier smoke.sh sections left lying around (e.g. this
# same fixture's own "existing Uninstall test" section, just above, leaves
# othersuite installed and never removes it - the very first UninstallAll
# call below, before either install, may itself report cleaning that up
# rather than "nothing installed"; either way, state is clean again before
# the two installs run). The LAST "uninstalled ..." report in the whole
# transcript is therefore always this script's own final, full-removal
# call - the one right before the closing idempotency check - never an
# earlier, possibly-partial cleanup call.
UNINSTALLALL_LINE="$(echo "$PMUNA" | grep -F 'PluginMarketplaceUninstallAll: uninstalled' | tail -n1)"
if echo "$UNINSTALLALL_LINE" | grep -qF "uninstalled 4 plug-in(s)"; then
  echo "ok   PluginMarketplaceUninstallAll removed all 4 installed entries (targets + cascaded dependencies) in one call"
else
  echo "FAIL PluginMarketplaceUninstallAll did not report removing exactly 4 plug-ins: $UNINSTALLALL_LINE"; fail=1
fi
for id in shareddeps orphanlib toolboxpro othersuite; do
  if echo "$UNINSTALLALL_LINE" | grep -qF "$id"; then
    echo "ok   PluginMarketplaceUninstallAll's report names $id"
  else
    echo "FAIL PluginMarketplaceUninstallAll's report is missing $id: $UNINSTALLALL_LINE"; fail=1
  fi
done
echo "$PMUNA" | grep -qF "! PluginMarketplaceUninstallAll:" \
  && { echo "FAIL PluginMarketplaceUninstallAll reported a failure - the cascade dedupe should leave none"; fail=1; } \
  || echo "ok   PluginMarketplaceUninstallAll reported no failures - the cascade dedupe left nothing to reattempt"
pmunacheck "PluginMarketplaceUninstallAll: nothing installed via the marketplace to uninstall" "a second PluginMarketplaceUninstallAll right after the first reports nothing left to do - everything genuinely uninstalled, not just claimed"

# Plug-in Marketplace: version-constrained dependencies ("id@min_version" in
# MarketplaceEntry::dependencies, split by SplitDependencySpec and resolved
# in Marketplace::InstallByIdChecked, src/plugins/Marketplace.cpp).
# tests/plugin_marketplace_verdep_index.json's meshtools is auto-loaded from
# next to the executable reporting version 1.0.0, but the index itself
# advertises 2.0.0: analysistools requires meshtools>=9.9.9, which the index
# can never satisfy (a real version conflict - even installing the index's
# own 2.0.0 isn't enough) and must fail installing nothing; curvetools
# requires meshtools>=1.5.0, which the stale auto-loaded 1.0.0 copy does not
# satisfy, so installing curvetools must (re)install meshtools fresh from
# the index - a genuine second, independent MeshTools load - rather than
# wrongly treating the auto-loaded copy as already satisfying it.
sed "s|@DINO8ROOT@|$HEREW/..|g" "$HERE/plugin_marketplace_verdep_script.txt" > "$TMPW/plugin_marketplace_verdep_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PMVD="$(timeout 900 "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_verdep_script.txt" 2>&1)" || { echo "$PMVD"; echo "FAIL: plugin marketplace version-constrained dependency script exited non-zero"; exit 1; }
else
  PMVD="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$TMPW/plugin_marketplace_verdep_script.txt" 2>&1)" || { echo "$PMVD"; echo "FAIL: plugin marketplace version-constrained dependency script exited non-zero"; exit 1; }
fi
pmvdcheck() { if echo "$PMVD" | grep -qF "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$PMVD" "$1"; fail=1; fi; }
pmvdcheck "PluginMarketplaceIndex: loaded \"Version-Constrained Dependency Test Index (min-version dependency resolution fixture)\" - 3 plug-in(s)" "PluginMarketplaceIndex loaded the version-constrained-dependency fixture index"
pmvdcheck "! PluginMarketplaceInstall: AnalysisTools (analysistools) requires MeshTools >= 9.9.9, but the loaded index only offers 2.0.0 - version conflict, cannot resolve" "PluginMarketplaceInstall refuses a dependency version the loaded index can never satisfy"
pmvdcheck "PluginMarketplaceInstall: installed curvetools - 1 command(s), 3 flow node(s) registered" "PluginMarketplaceInstall installs curvetools once its stale meshtools dependency is upgraded"
awk '/^history: GrasshopperPluginList: /{n++} {print > ("'"$TMPW"'/plugindep/verdepsec" n ".txt")}' <<<"$PMVD"
PMVD_S1="$(cat "$TMPW/plugindep/verdepsec1.txt" 2>/dev/null)"
PMVD_S2="$(cat "$TMPW/plugindep/verdepsec2.txt" 2>/dev/null)"
PMVD_S3="$(cat "$TMPW/plugindep/verdepsec3.txt" 2>/dev/null)"
MT1="$(echo "$PMVD_S1" | grep -c 'MeshTools 1.0.0 -' || true)"
MT2="$(echo "$PMVD_S2" | grep -c 'MeshTools 1.0.0 -' || true)"
if [ "$MT1" = "1" ] && [ "$MT2" = "1" ]; then
  echo "ok   the version-conflicting analysistools install left MeshTools's loaded-copy count unchanged ($MT1 -> $MT2) - nothing was installed"
else
  echo "FAIL analysistools's version-conflict install changed MeshTools's loaded-copy count ($MT1 -> $MT2), should have installed nothing"; fail=1
fi
MT3="$(echo "$PMVD_S3" | grep -c 'MeshTools 1.0.0 -' || true)"
if [ "$MT2" = "1" ] && [ "$MT3" = "2" ]; then
  echo "ok   installing curvetools upgraded its stale meshtools dependency with a genuine second, independent load (1 auto-loaded reporting 1.0.0, 2 after the marketplace install) - not wrongly treated as already satisfied"
else
  echo "FAIL installing curvetools did not add a second independently-loaded MeshTools copy for its unmet >=1.5.0 requirement (saw $MT2 before, $MT3 after)"; fail=1
fi
CT2="$(echo "$PMVD_S2" | grep -c 'CurveTools 1.0.0 -' || true)"
CT3="$(echo "$PMVD_S3" | grep -c 'CurveTools 1.0.0 -' || true)"
if [ "$CT2" = "1" ] && [ "$CT3" = "2" ]; then
  echo "ok   installing curvetools added its own genuine second, independent load (1 auto-loaded from next to the executable, 2 after the marketplace install) once its version-constrained dependency was resolved"
else
  echo "FAIL installing curvetools did not add its own independently-loaded copy (saw $CT2 before, $CT3 after)"; fail=1
fi

# Batch scripting mode: `--script FILE` given WITHOUT `--smoke` (see
# docs/BATCH_SCRIPTING.md and main.cpp's own header comment). Before this
# was made a real, supported mode, this exact combination opened a
# *visible* window and never exited on its own - main.cpp's own
# script-finished exit check only ever fired when --smoke was also given,
# so the process just sat in the normal interactive loop forever, waiting
# for a human to close a window nothing could see under Xvfb. `timeout`
# below is the actual regression guard for that: if the old hang ever
# comes back, this fails on its own (exit 124) instead of wedging the rest
# of this script indefinitely.
cat > "$TMPW/batch_script.txt" <<'EOF'
Box 0,0,0 5,5,0 5
Sphere 30,0,0 5
@expect_objects 2
EOF
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  set +e; BS_OUT="$(timeout 30 "$BIN" --script "$TMPW/batch_script.txt" 2>&1)"; BS_EC=$?; set -e
else
  set +e; BS_OUT="$(timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --script "$TMPW/batch_script.txt" 2>&1)"; BS_EC=$?; set -e
fi
if [ "$BS_EC" -eq 124 ]; then
  echo "$BS_OUT"; echo "FAIL: --script without --smoke hung instead of exiting on its own (batch scripting mode regression)"; fail=1
elif [ "$BS_EC" -ne 0 ]; then
  echo "$BS_OUT"; echo "FAIL: batch --script run exited $BS_EC, expected 0"; fail=1
else
  echo "$BS_OUT" | grep -E "^(ok|FAIL|script:)"
  bscheck() { if echo "$BS_OUT" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$BS_OUT" "$1"; fail=1; fi; }
  bscheck "^ok   expect_objects 2" "batch script's own @expect_objects check saw both objects it built"
  bscheck "^script: done objects=2" "batch mode's own done-summary line reported the right object count and printed itself instead of falling into the interactive loop"
fi

# A failing @expect_* check in batch mode must still exit (not hang), with
# the same exit code 2 --smoke already uses for one.
cat > "$TMPW/batch_script_fail.txt" <<'EOF'
Box 0,0,0 5,5,0 5
@expect_objects 99
EOF
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  set +e; BSF_OUT="$(timeout 30 "$BIN" --script "$TMPW/batch_script_fail.txt" 2>&1)"; BSF_EC=$?; set -e
else
  set +e; BSF_OUT="$(timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --script "$TMPW/batch_script_fail.txt" 2>&1)"; BSF_EC=$?; set -e
fi
if [ "$BSF_EC" -eq 124 ]; then
  echo "$BSF_OUT"; echo "FAIL: a failing @expect_objects in batch mode hung instead of exiting"; fail=1
elif [ "$BSF_EC" -eq 2 ] && echo "$BSF_OUT" | grep -q "^FAIL expect_objects 99"; then
  echo "ok   batch mode exits 2 (not 0, not a hang) when the script's own @expect_objects check fails"
else
  echo "$BSF_OUT"; echo "FAIL: batch mode with a failing @expect_objects exited $BSF_EC, expected 2"; fail=1
fi

# --serve: the minimal compute server (net/ComputeServer.h, docs/
# COMPUTE_SERVER.md) - see PARITY_MAP.md's "Cloud/network compute service"
# item, which had no server/socket/HTTP code anywhere before this. Starts
# the real app with --serve 0 (an OS-assigned ephemeral port, so this can
# never collide with another process on a fixed port) and
# --serve-max-requests 6 so the process is self-terminating like batch
# --script mode above, backgrounds it, waits (bounded, not an unbounded
# sleep loop) for its own "serve: listening on port N" line, then drives it
# over a real loopback HTTP connection with curl: a POST that builds
# geometry and reads back its printed output, a GET that must be rejected
# with 405, a POST calling an interactive rs.Get* prompt that must be
# rejected instead of hanging the connection, a POST /run/python that
# builds and queries geometry through the embedded Python module, a second
# POST /run/python calling the now-real dino8.GetPoint() that must likewise
# be rejected instead of hanging, a third POST /run/python calling the new
# dino8.GetInteger() that must be rejected the same way (or all three
# /run/python checks are skipped gracefully on a build with no Python
# support), and a POST to an unknown path that must come back 404 - see
# tests/test_compute_server.cpp for the lower-level, no-app unit coverage
# of the request parsing/response formatting this end-to-end check builds
# on top of. A second, separate
# server instance below covers --serve-token bearer-auth.
if ! command -v curl >/dev/null 2>&1; then
  echo "skip --serve compute-server checks (curl not available)"
else
  SERVE_LOG="$TMPW/serve.log"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-max-requests 24 > "$SERVE_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-max-requests 24 > "$SERVE_LOG" 2>&1 &
  fi
  SERVE_PID=$!

  SERVE_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$SERVE_LOG" 2>/dev/null; then
      SERVE_PORT="$(grep "^serve: listening on port " "$SERVE_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$SERVE_PORT" ]; then
    cat "$SERVE_LOG"; echo "FAIL: --serve never printed its listening port within 10s"; fail=1
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  else
    echo "ok   --serve started headless and printed its bound port ($SERVE_PORT)"

    set +e
    RESP1="$(curl -s --max-time 10 -X POST --data 'rs.Command("Box 0,0,0 5,5,0 5")
print("objects: " .. #rs.AllObjects())' "http://127.0.0.1:$SERVE_PORT/run")"
    # A real, if minimal, structured geometry wire format: narrows
    # PARITY_MAP.md's own disclosed "no geometry (de)serialization format
    # at all - a script gets and returns plain text" gap on both the
    # response side (/run[/python]'s new Accept: application/json form)
    # and the request/read side (GET /objects below) - taken right after
    # RESP1 so the document holds exactly the one box it just built, with
    # a known id/bounding box to check against.
    RESP9="$(curl -s --max-time 10 -X POST -H 'Accept: application/json' --data 'print("hi")' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP10="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/objects")"
    # GET /objects?geometry=1: the actual point/vertex/curve data for the
    # three object kinds simple enough to serialize honestly as plain JSON
    # right now (point, mesh, and now a NURBS curve's own degree/control
    # points/weights/knots) - narrows PARITY_MAP.md's own disclosed "no
    # geometry (de)serialization format" gap a step further than the bare
    # metadata listing above. Adds one point, one triangle mesh and one
    # straight (degree-1, non-rational) line so all three real payloads can
    # be checked in the same request, plus confirms the pre-existing box (a
    # polysurface, none of the three) reports "geometry":null rather than
    # silently omitting the key or guessing at a payload.
    RESP11="$(curl -s --max-time 10 -X POST --data 'rs.AddPoint(20,20,20)
rs.AddMesh({{0,0,0},{1,0,0},{0,1,0}}, {{1,2,3}})
rs.AddLine({0,0,0},{10,0,0})' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP12="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/objects?geometry=1")"
    # POST /objects: the other half of the geometry wire format - sends
    # the same three shapes GET /objects?geometry=1 reads back in as a
    # JSON request body, closing PARITY_MAP.md's own disclosed "no way to
    # POST geometry in as structured data" gap. Document already holds 4
    # objects (box=1, point=2, mesh=3, line=4 from RESP1/RESP11 above), so
    # these three real adds land at the exact predictable ids 5/6/7 -
    # using different coordinates than RESP11's own point/mesh/line so the
    # follow-up GET below can tell the two apart, not just confirm *something*
    # landed at those ids.
    RESP13="$(curl -s --max-time 10 -X POST --data '{"type":"point","point":[7,8,9]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    RESP14="$(curl -s --max-time 10 -X POST --data '{"type":"mesh","vertices":[[0,0,0],[2,0,0],[0,2,0]],"faces":[[0,1,2]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    RESP15="$(curl -s --max-time 10 -X POST --data '{"type":"curve","degree":1,"control_points":[[0,0,5],[20,0,5]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    # The fourth geometry kind (surface, alongside point/mesh/curve above):
    # a degree-(1,1) bilinear patch, posted with no explicit "knots_u"/
    # "knots_v" so FromControlGrid's own clamped knot vectors get checked
    # the same way RESP15's curve already checks FromControlPoints' own
    # filled-in knots. Lands at the next predictable id (8) right alongside
    # RESP13/14/15, so the one RESP16 GET just below reads all five kinds
    # back in a single request.
    RESP18="$(curl -s --max-time 10 -X POST --data '{"type":"surface","degree_u":1,"degree_v":1,"u_count":2,"v_count":2,"control_points":[[0,0,0],[0,5,1],[9,0,0],[9,5,1]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    # The fifth geometry kind (point cloud): a point cloud has no topology
    # to lose, so this closes that gap outright. Posts both optional
    # per-point channels (colors, normals) alongside the required positions
    # so the round trip below actually exercises
    # PointCloud::SetColors()/SetNormals(), not just the bare-position path.
    # Lands at id 9, right alongside RESP13/14/15/18, so the same RESP16 GET
    # below reads it back too.
    RESP19="$(curl -s --max-time 10 -X POST --data '{"type":"point_cloud","points":[[1,2,3],[4,5,6],[7,8,9]],"colors":[[255,0,0],[0,255,0],[0,0,255]],"normals":[[1,0,0],[0,1,0],[0,0,1]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    # The remaining two kinds (polysurface, SubD) no longer get a bare
    # "geometry":null either, narrowing PARITY_MAP.md's own disclosed gap
    # further: both now carry a real tessellated-mesh approximation (same
    # vertices/faces shape as ObjectKind::Mesh, under a nested "mesh" key,
    # with "tessellated":true alongside it to disclose plainly that it is
    # an approximation, not the real trimmed-surface/control-cage topology
    # - still genuinely unserialized, and still a separately-disclosed,
    # substantially larger undertaking). The box built by RESP1 at the very
    # top (id 1, a polysurface) is already in the document for RESP16's GET
    # below to re-check; this one new request adds a second SubD box (lands
    # at the next predictable id, 10) so the same GET also exercises the
    # SubD half - no separate GET needed, RESP16 hasn't been issued yet.
    RESP20="$(curl -s --max-time 10 -X POST --data 'rs.Command("SubDBox 100,0,0 105,5,0 5")' "http://127.0.0.1:$SERVE_PORT/run")"
    # The sixth POST /objects type, "subd": a SubD control cage at level 0
    # IS exactly a mesh, so this is the identical {"vertices","faces"}
    # shape "mesh" already takes - one flat quad face, the simplest valid
    # control cage FromControlMesh accepts. Lands at the next predictable
    # id (11, right after RESP20's own SubDBox at 10), so the same RESP16
    # GET just below reads this one back too, as a real SubD (not a mesh).
    RESP_SUBD="$(curl -s --max-time 10 -X POST --data '{"type":"subd","vertices":[[20,0,0],[21,0,0],[21,1,0],[20,1,0]],"faces":[[0,1,2,3]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    RESP16="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/objects?geometry=1")"
    RESP17="$(curl -s --max-time 10 -X POST --data '{"type":"bogus"}' "http://127.0.0.1:$SERVE_PORT/objects")"
    CODE14="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'not json' "http://127.0.0.1:$SERVE_PORT/objects")"
    CODE2="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP3="$(curl -s --max-time 10 -X POST --data 'rs.GetPoint()' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP4="$(curl -s --max-time 10 -X POST --data 'import dino8
id = dino8.doc.Objects.AddBox(dino8.Point3d(0,0,0), dino8.Vector3d(5,5,5))
print("volume: %.1f" % dino8.doc.Objects.SurfaceVolume(id))' "http://127.0.0.1:$SERVE_PORT/run/python")"
    RESP6="$(curl -s --max-time 10 -X POST --data 'import dino8
dino8.GetPoint()' "http://127.0.0.1:$SERVE_PORT/run/python")"
    # A script that catches the "cancelled" exception compute_handler's own
    # Abort() raises out of the first dino8.GetPoint() and simply calls
    # GetPoint() again (an easy bare-except pattern, not a deliberately
    # adversarial one) used to re-suspend PythonEngine's worker thread on a
    # resume that would never come, deadlocking it together with this very
    # Abort() call - which runs synchronously on the main loop that also
    # drives this whole --serve process, so the hang wasn't scoped to one
    # connection, it froze the entire server. This request must still get
    # an ordinary response within the --max-time below, not hang until the
    # outer `timeout 30` kills the whole process.
    RESP7="$(curl -s --max-time 10 -X POST --data 'import dino8
try:
    dino8.GetPoint()
except Exception:
    pass
dino8.GetPoint()' "http://127.0.0.1:$SERVE_PORT/run/python")"
    # dino8.GetInteger()/GetReal() (new this pass - PythonEngine.h/.cpp)
    # share WaitForPoint/WaitForText's own suspend-and-abort machinery, so
    # this must be rejected the same way RESP6's GetPoint() is, not hang.
    RESP8="$(curl -s --max-time 10 -X POST --data 'import dino8
dino8.GetInteger("how many")' "http://127.0.0.1:$SERVE_PORT/run/python")"
    CODE5="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'x' "http://127.0.0.1:$SERVE_PORT/run/nosuchroute")"
    # GET /plugins: narrows PARITY_MAP.md's own disclosed "Plugin
    # marketplace / discovery mechanism" gap - this same compute server can
    # now serve the bundled plugin index as real JSON over real HTTP,
    # giving PluginMarketplaceIndex's own existing arbitrary-http(s)-URL
    # path a genuine server to point at instead of only ever a file
    # someone else hosted by hand.
    RESP21="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/plugins")"
    CODE6="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'x' "http://127.0.0.1:$SERVE_PORT/plugins")"
    set -e
    echo "$RESP1" | grep -q "^objects: 1$" && echo "ok   POST /run built a box over HTTP and read back its printed object count" || { echo "$RESP1"; echo "FAIL --serve POST /run did not report objects: 1"; fail=1; }
    [ "$RESP9" = '{"ok":true,"output":["hi"]}' ] && echo "ok   POST /run with Accept: application/json returns a real structured {ok,output} response instead of plain print() text" || { echo "$RESP9"; echo "FAIL --serve POST /run Accept: application/json did not return the expected JSON body"; fail=1; }
    echo "$RESP10" | grep -q '"type":"polysurface"' && echo "ok   GET /objects reports the box RESP1 just built as a real JSON object (type polysurface)" || { echo "$RESP10"; echo "FAIL --serve GET /objects did not report the box as a polysurface"; fail=1; }
    echo "$RESP10" | grep -q '"min":\[0.000000,0.000000,0.000000\],"max":\[5.000000,5.000000,5.000000\]' && echo "ok   GET /objects reported the box's own real bounding box (0,0,0)-(5,5,5), not just a type/name/layer listing" || { echo "$RESP10"; echo "FAIL --serve GET /objects did not report the box's expected bounding box"; fail=1; }
    echo "$RESP12" | grep -q '"geometry":{"point":\[20.000000,20.000000,20.000000\]}' && echo "ok   GET /objects?geometry=1 reports a real point object's own coordinates, not just its bounding box" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report the point's coordinates"; fail=1; }
    echo "$RESP12" | grep -q '"geometry":{"vertices":\[\[0.000000,0.000000,0.000000\],\[1.000000,0.000000,0.000000\],\[0.000000,1.000000,0.000000\]\],"faces":\[\[0,1,2\]\]}' && echo "ok   GET /objects?geometry=1 reports a real mesh object's own vertices/faces (0-based indices), not just its bounding box" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report the mesh's expected vertices/faces"; fail=1; }
    echo "$RESP12" | grep -q '"type":"curve".*"geometry":{"degree":1,"rational":false,"control_points":\[\[0.000000,0.000000,0.000000\],\[10.000000,0.000000,0.000000\]\],"knots":\[0.000000,1.000000\]}' && echo "ok   GET /objects?geometry=1 reports a real NURBS curve's own degree/control points/knots (no \"weights\" field for a non-rational curve), not just sampled points" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report the line's expected NURBS curve definition"; fail=1; }
    # Polysurface/SubD (RESP20's own new SubD checked a few lines below,
    # against RESP16 instead - it doesn't exist yet at this point in the
    # flow): a real tessellated-mesh approximation instead of a bare
    # "geometry":null - narrows PARITY_MAP.md's own disclosed gap further.
    # Checked by substantive content (the "tessellated" flag, both extreme
    # corners of the box's own known (0,0,0)-(5,5,5) bounds genuinely
    # present as vertices, and a non-empty face list) rather than the full
    # adaptive-triangulation string verbatim - EnsureDisplay's own adaptive
    # algorithm is deterministic for this fixed input (confirmed by two
    # independent runs against the real binary before writing this check),
    # but pinning its exact internal vertex/triangle order would tie this
    # test to that algorithm's own implementation detail more tightly than
    # the behavior actually being verified here calls for.
    echo "$RESP12" | grep -q '"type":"polysurface".*"geometry":{"tessellated":true,"mesh":{"vertices":\[' && echo "ok   GET /objects?geometry=1 reports a real tessellated mesh approximation for a polysurface instead of bare \"geometry\":null" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report tessellated geometry for the box"; fail=1; }
    echo "$RESP12" | grep -q '\[0.000000,0.000000,0.000000\]' && echo "$RESP12" | grep -q '\[5.000000,5.000000,5.000000\]' && echo "ok   the box's own tessellated mesh genuinely spans its real (0,0,0)-(5,5,5) extent, not a placeholder or degenerate mesh" || { echo "$RESP12"; echo "FAIL --serve box's tessellated mesh did not span its expected extent"; fail=1; }
    echo "$RESP12" | grep -q '"faces":\[\[[0-9]' && echo "ok   the box's own tessellated mesh carries a real, non-empty face list" || { echo "$RESP12"; echo "FAIL --serve box's tessellated mesh had no faces"; fail=1; }
    [ "$RESP13" = '{"ok":true,"id":5}' ] && echo "ok   POST /objects {type:point} added a real point object at the expected id" || { echo "$RESP13"; echo "FAIL --serve POST /objects point did not return the expected {ok,id}"; fail=1; }
    [ "$RESP14" = '{"ok":true,"id":6}' ] && echo "ok   POST /objects {type:mesh} added a real mesh object at the expected id" || { echo "$RESP14"; echo "FAIL --serve POST /objects mesh did not return the expected {ok,id}"; fail=1; }
    [ "$RESP15" = '{"ok":true,"id":7}' ] && echo "ok   POST /objects {type:curve} added a real NURBS curve object at the expected id" || { echo "$RESP15"; echo "FAIL --serve POST /objects curve did not return the expected {ok,id}"; fail=1; }
    [ "$RESP18" = '{"ok":true,"id":8}' ] && echo "ok   POST /objects {type:surface} added a real NURBS surface object at the expected id" || { echo "$RESP18"; echo "FAIL --serve POST /objects surface did not return the expected {ok,id}"; fail=1; }
    [ "$RESP19" = '{"ok":true,"id":9}' ] && echo "ok   POST /objects {type:point_cloud} added a real point-cloud object at the expected id" || { echo "$RESP19"; echo "FAIL --serve POST /objects point_cloud did not return the expected {ok,id}"; fail=1; }
    echo "$RESP16" | grep -q '"id":5,"type":"point".*"geometry":{"point":\[7.000000,8.000000,9.000000\]}' && echo "ok   the point POSTed via /objects reads back through GET /objects?geometry=1 with its own exact coordinates - a genuine round trip, not just an accepted write" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed point"; fail=1; }
    echo "$RESP16" | grep -q '"id":6,"type":"mesh".*"geometry":{"vertices":\[\[0.000000,0.000000,0.000000\],\[2.000000,0.000000,0.000000\],\[0.000000,2.000000,0.000000\]\],"faces":\[\[0,1,2\]\]}' && echo "ok   the mesh POSTed via /objects reads back with its own exact vertices/faces - a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed mesh"; fail=1; }
    echo "$RESP16" | grep -q '"id":7,"type":"curve".*"geometry":{"degree":1,"rational":false,"control_points":\[\[0.000000,0.000000,5.000000\],\[20.000000,0.000000,5.000000\]\]' && echo "ok   the curve POSTed via /objects (with no explicit \"knots\") reads back with its own exact control points and a real knot vector FromControlPoints filled in - a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed curve"; fail=1; }
    echo "$RESP16" | grep -q '"id":8,"type":"surface".*"geometry":{"degree_u":1,"degree_v":1,"u_count":2,"v_count":2,"rational":false,"control_points":\[\[0.000000,0.000000,0.000000\],\[0.000000,5.000000,1.000000\],\[9.000000,0.000000,0.000000\],\[9.000000,5.000000,1.000000\]\],"knots_u":\[0.000000,1.000000\],"knots_v":\[0.000000,1.000000\]}' && echo "ok   the surface POSTed via /objects (with no explicit \"knots_u\"/\"knots_v\") reads back with its own exact control grid and real clamped knot vectors FromControlGrid filled in, in each direction - the fourth geometry kind this wire format now covers, a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed surface"; fail=1; }
    echo "$RESP16" | grep -q '"id":9,"type":"point cloud".*"geometry":{"points":\[\[1.000000,2.000000,3.000000\],\[4.000000,5.000000,6.000000\],\[7.000000,8.000000,9.000000\]\],"colors":\[\[255,0,0\],\[0,255,0\],\[0,0,255\]\],"normals":\[\[1.000000,0.000000,0.000000\],\[0.000000,1.000000,0.000000\],\[0.000000,0.000000,1.000000\]\]}' && echo "ok   the point cloud POSTed via /objects (positions plus both optional colors/normals channels) reads back with its own exact points/colors/normals - the fifth geometry kind this wire format now covers, a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed point cloud"; fail=1; }
    # RESP20's SubD box (id 10, built via rs.Command, so it lands with a
    # real ON_SubD independently of the POST "subd" type checked just
    # below). Unlike the box's own adaptive tessellation above,
    # SubD::ToApproximateMesh() facets the CURRENT subdivision level's own
    # flat control net (its own doc comment is explicit this is never the
    # true limit surface) - a never-Subdivide()'d SubDBox is deterministic
    # exactly, so this pins the full vertex/face list, not just substantive
    # content, the same way the plain Mesh/Curve/Surface checks above do.
    echo "$RESP16" | grep -q '"id":10,"type":"SubD".*"geometry":{"tessellated":true,"mesh":{"vertices":\[\[100.000000,0.000000,0.000000\],\[105.000000,0.000000,0.000000\],\[100.000000,5.000000,0.000000\],\[105.000000,5.000000,0.000000\],\[100.000000,0.000000,5.000000\],\[105.000000,0.000000,5.000000\],\[100.000000,5.000000,5.000000\],\[105.000000,5.000000,5.000000\]\],"faces":\[\[0,2,3,1\],\[4,5,7,6\],\[0,1,5,4\],\[2,6,7,3\],\[0,4,6,2\],\[1,3,7,5\]\]}}' && echo "ok   GET /objects?geometry=1 reports a real tessellated mesh approximation (its own flat control cage, 8 vertices/6 quad faces) for a SubD instead of bare \"geometry\":null" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not report the SubD box's expected tessellated geometry"; fail=1; }
    [ "$RESP_SUBD" = '{"ok":true,"id":11}' ] && echo "ok   POST /objects {type:subd} added a real SubD control cage at the expected id, right after RESP20's own rs.Command-built SubD box" || { echo "$RESP_SUBD"; echo "FAIL --serve POST /objects subd did not return the expected {ok,id}"; fail=1; }
    echo "$RESP16" | grep -q '"id":11,"type":"SubD".*"geometry":{"tessellated":true,"mesh":{"vertices":\[\[20.000000,0.000000,0.000000\],\[21.000000,0.000000,0.000000\],\[21.000000,1.000000,0.000000\],\[20.000000,1.000000,0.000000\]\],"faces":\[\[0,1,2,3\]\]}}' && echo "ok   the SubD POSTed via /objects (one flat quad control cage) reads back as its own exact tessellated flat cage - not through Lua/rs.Command at all, the sixth geometry kind this wire format now covers on the write side" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed SubD's expected control cage"; fail=1; }
    echo "$RESP17" | grep -q '^{"ok":false,"error":"unknown or missing' && echo "ok   POST /objects rejects an unrecognized \"type\" with a clear JSON error instead of silently doing nothing" || { echo "$RESP17"; echo "FAIL --serve POST /objects did not reject an unknown type as expected"; fail=1; }
    [ "$CODE14" = "400" ] && echo "ok   POST /objects rejects a malformed (non-JSON) body with 400 Bad Request" || { echo "FAIL --serve POST /objects malformed body returned HTTP $CODE14, expected 400"; fail=1; }
    [ "$CODE2" = "405" ] && echo "ok   a GET request to the compute server is rejected with 405 Method Not Allowed" || { echo "FAIL --serve GET /run returned HTTP $CODE2, expected 405"; fail=1; }
    echo "$RESP3" | grep -q "compute error: script requires interactive input" && echo "ok   a script calling an interactive rs.Get* prompt is rejected instead of hanging the connection" || { echo "$RESP3"; echo "FAIL --serve interactive-prompt script was not rejected as expected"; fail=1; }
    if echo "$RESP4" | grep -q "DINO8_HAVE_PYTHON"; then
      echo "skip POST /run/python checks (this build has no embedded Python - see DINO8_ENABLE_PYTHON in CMakeLists.txt)"
    else
      echo "$RESP4" | grep -q "^volume: 125.0$" && echo "ok   POST /run/python built a box through the dino8 module over HTTP and read back its printed volume" || { echo "$RESP4"; echo "FAIL --serve POST /run/python did not report volume: 125.0"; fail=1; }
      echo "$RESP6" | grep -q "compute error: script requires interactive input" && echo "ok   a POST /run/python script calling the now-real dino8.GetPoint() is rejected instead of hanging the connection (PythonEngine suspends on a worker thread now - see PythonEngine.h - so this is a real regression risk main.cpp's compute_handler guards against)" || { echo "$RESP6"; echo "FAIL --serve POST /run/python dino8.GetPoint() was not rejected as expected"; fail=1; }
      echo "$RESP7" | grep -q "compute error: script requires interactive input" && echo "ok   a POST /run/python script that catches the cancelled GetPoint() and calls it again still gets an ordinary rejection, not a frozen connection/server" || { echo "$RESP7"; echo "FAIL --serve POST /run/python catch-and-retry GetPoint() hung or returned something unexpected"; fail=1; }
      echo "$RESP8" | grep -q "compute error: script requires interactive input" && echo "ok   a POST /run/python script calling the new dino8.GetInteger() is rejected instead of hanging the connection, same as GetPoint/GetString" || { echo "$RESP8"; echo "FAIL --serve POST /run/python dino8.GetInteger() was not rejected as expected"; fail=1; }
    fi
    [ "$CODE5" = "404" ] && echo "ok   a POST to an unrecognized path is rejected with 404 Not Found" || { echo "FAIL --serve POST to an unknown path returned HTTP $CODE5, expected 404"; fail=1; }
    echo "$RESP21" | grep -q '"index_name": "Dino 8 Reference Plugin Index"' && echo "$RESP21" | grep -q '"id": "hellodino"' && echo "ok   GET /plugins serves the real bundled plugin index as JSON over HTTP" || { echo "$RESP21"; echo "FAIL --serve GET /plugins did not serve the expected bundled index"; fail=1; }
    [ "$CODE6" = "405" ] && echo "ok   a POST to /plugins is rejected with 405 Method Not Allowed (GET only)" || { echo "FAIL --serve POST /plugins returned HTTP $CODE6, expected 405"; fail=1; }

    set +e; wait "$SERVE_PID"; SERVE_EC=$?; set -e
    if [ "$SERVE_EC" -eq 124 ]; then
      cat "$SERVE_LOG"; echo "FAIL: --serve process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$SERVE_EC" -ne 0 ]; then
      cat "$SERVE_LOG"; echo "FAIL: --serve process exited $SERVE_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=24$" "$SERVE_LOG" && echo "ok   --serve exited cleanly on its own after --serve-max-requests 24 real HTTP requests" || { cat "$SERVE_LOG"; echo "FAIL --serve done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token: a second, independent server instance (its own ephemeral
  # port) started with TWO bearer tokens required - a bare, anonymous one
  # ("hunter2") and a named one ("ci:abc123"), checking that --serve-token
  # is genuinely repeatable and that a named token's own caller comes back
  # in the JSON response, not just that auth works at all. Checks: a
  # request with no/wrong Authorization header is rejected with 401 (its
  # script body, "should not run", is never passed to Lua.Start at all -
  # see main.cpp's compute_handler, which checks the token before touching
  # req.path/req.body); the bare token succeeds exactly like the token-less
  # server above, with no "caller" field; and the named token succeeds AND
  # echoes its own name back as "caller" (Accept: application/json).
  TOKEN_LOG="$TMPW/serve_token.log"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token hunter2 --serve-token ci:abc123 --serve-max-requests 4 > "$TOKEN_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token hunter2 --serve-token ci:abc123 --serve-max-requests 4 > "$TOKEN_LOG" 2>&1 &
  fi
  TOKEN_PID=$!

  TOKEN_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$TOKEN_LOG" 2>/dev/null; then
      TOKEN_PORT="$(grep "^serve: listening on port " "$TOKEN_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$TOKEN_PORT" ]; then
    cat "$TOKEN_LOG"; echo "FAIL: --serve-token server never printed its listening port within 10s"; fail=1
    kill "$TOKEN_PID" 2>/dev/null || true
    wait "$TOKEN_PID" 2>/dev/null || true
  else
    echo "ok   --serve-token started a second compute server headless on its own bound port ($TOKEN_PORT)"

    set +e
    CODE_NOAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKEN_PORT/run")"
    CODE_WRONGAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrongtoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKEN_PORT/run")"
    RESP_OKAUTH="$(curl -s --max-time 10 -H 'Authorization: Bearer hunter2' -X POST --data 'print("authorized ok")' "http://127.0.0.1:$TOKEN_PORT/run")"
    RESP_NAMEDAUTH="$(curl -s --max-time 10 -H 'Authorization: Bearer abc123' -H 'Accept: application/json' -X POST --data 'print("authorized ok")' "http://127.0.0.1:$TOKEN_PORT/run")"
    set -e
    [ "$CODE_NOAUTH" = "401" ] && echo "ok   --serve-token rejects a request with no Authorization header with 401" || { echo "FAIL --serve-token no-auth request returned HTTP $CODE_NOAUTH, expected 401"; fail=1; }
    [ "$CODE_WRONGAUTH" = "401" ] && echo "ok   --serve-token rejects a request with the wrong bearer token with 401" || { echo "FAIL --serve-token wrong-token request returned HTTP $CODE_WRONGAUTH, expected 401"; fail=1; }
    echo "$RESP_OKAUTH" | grep -q "^authorized ok$" && echo "ok   --serve-token accepts a request with the correct Authorization: Bearer header and runs the script" || { echo "$RESP_OKAUTH"; echo "FAIL --serve-token correct-token request did not run the script"; fail=1; }
    [ "$RESP_NAMEDAUTH" = '{"ok":true,"output":["authorized ok"],"caller":"ci"}' ] && echo "ok   a second, named --serve-token (ci:abc123) authenticates independently of the bare one and echoes its own caller name back in the JSON response" || { echo "$RESP_NAMEDAUTH"; echo "FAIL --serve-token named-token request did not return the expected caller-tagged JSON"; fail=1; }

    set +e; wait "$TOKEN_PID"; TOKEN_EC=$?; set -e
    if [ "$TOKEN_EC" -eq 124 ]; then
      cat "$TOKEN_LOG"; echo "FAIL: --serve-token process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$TOKEN_EC" -ne 0 ]; then
      cat "$TOKEN_LOG"; echo "FAIL: --serve-token process exited $TOKEN_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=4$" "$TOKEN_LOG" && echo "ok   --serve-token server exited cleanly on its own after 4 real HTTP requests" || { cat "$TOKEN_LOG"; echo "FAIL --serve-token done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file: a third, independent server instance whose tokens
  # come from a file re-read on every request instead of fixed at startup -
  # narrows PARITY_MAP.md's own disclosed "no rotation, expiry, or
  # revocation beyond restarting the server" gap --serve-token alone still
  # has. Starts with one bare token ("filetoken1") in the file, proves it
  # authenticates like any --serve-token would, then overwrites the file
  # mid-run (filetoken1 removed = revoked, filetoken2 + a named ci2:tokenY
  # added = rotated in) and proves the very next requests see the change
  # with no restart: the old token now rejected, the new ones accepted.
  TOKFILE_LOG="$TMPW/serve_token_file.log"
  TOKFILE_PATH="$TMPW/serve_tokens.txt"
  printf 'filetoken1\n' > "$TOKFILE_PATH"
  chmod 0600 "$TOKFILE_PATH"  # owner-only, same as any real deployment would need - see the permissions test below
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$TOKFILE_PATH" --serve-max-requests 5 > "$TOKFILE_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$TOKFILE_PATH" --serve-max-requests 5 > "$TOKFILE_LOG" 2>&1 &
  fi
  TOKFILE_PID=$!

  TOKFILE_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$TOKFILE_LOG" 2>/dev/null; then
      TOKFILE_PORT="$(grep "^serve: listening on port " "$TOKFILE_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$TOKFILE_PORT" ]; then
    cat "$TOKFILE_LOG"; echo "FAIL: --serve-token-file server never printed its listening port within 10s"; fail=1
    kill "$TOKFILE_PID" 2>/dev/null || true
    wait "$TOKFILE_PID" 2>/dev/null || true
  else
    echo "ok   --serve-token-file started a third compute server headless on its own bound port ($TOKFILE_PORT)"

    set +e
    FILE_CODE_NOAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    FILE_RESP_OK1="$(curl -s --max-time 10 -H 'Authorization: Bearer filetoken1' -X POST --data 'print("file token ok")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    # Rewrite the file while the server is still running, no restart:
    # filetoken1 is gone (revoked), filetoken2/ci2:tokenY are new (rotated
    # in) - both take effect on the next two requests below.
    printf 'filetoken2\nci2:tokenY\n' > "$TOKFILE_PATH"
    FILE_CODE_REVOKED="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer filetoken1' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    FILE_RESP_ROTATED="$(curl -s --max-time 10 -H 'Authorization: Bearer filetoken2' -X POST --data 'print("rotated token ok")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    FILE_RESP_NAMED="$(curl -s --max-time 10 -H 'Authorization: Bearer tokenY' -H 'Accept: application/json' -X POST --data 'print("named ok")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    set -e
    [ "$FILE_CODE_NOAUTH" = "401" ] && echo "ok   --serve-token-file rejects a request with no Authorization header with 401, same as --serve-token" || { echo "FAIL --serve-token-file no-auth request returned HTTP $FILE_CODE_NOAUTH, expected 401"; fail=1; }
    echo "$FILE_RESP_OK1" | grep -q "^file token ok$" && echo "ok   --serve-token-file accepts a token currently listed in the file and runs the script" || { echo "$FILE_RESP_OK1"; echo "FAIL --serve-token-file did not accept the file's own listed token"; fail=1; }
    [ "$FILE_CODE_REVOKED" = "401" ] && echo "ok   rewriting the token file to drop a token revokes it on the very next request - no server restart needed" || { echo "FAIL --serve-token-file still accepted a token removed from the file (HTTP $FILE_CODE_REVOKED, expected 401) - revocation did not take effect live"; fail=1; }
    echo "$FILE_RESP_ROTATED" | grep -q "^rotated token ok$" && echo "ok   a token added to the file after the server started authenticates immediately - live rotation, no restart needed" || { echo "$FILE_RESP_ROTATED"; echo "FAIL --serve-token-file did not accept a token added to the file after startup"; fail=1; }
    [ "$FILE_RESP_NAMED" = '{"ok":true,"output":["named ok"],"caller":"ci2"}' ] && echo "ok   a named NAME:TOKEN entry in the token file authenticates and echoes its own caller name back, same as a named --serve-token" || { echo "$FILE_RESP_NAMED"; echo "FAIL --serve-token-file named-entry request did not return the expected caller-tagged JSON"; fail=1; }

    set +e; wait "$TOKFILE_PID"; TOKFILE_EC=$?; set -e
    if [ "$TOKFILE_EC" -eq 124 ]; then
      cat "$TOKFILE_LOG"; echo "FAIL: --serve-token-file process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$TOKFILE_EC" -ne 0 ]; then
      cat "$TOKFILE_LOG"; echo "FAIL: --serve-token-file process exited $TOKFILE_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=5$" "$TOKFILE_LOG" && echo "ok   --serve-token-file server exited cleanly on its own after 5 real HTTP requests" || { cat "$TOKFILE_LOG"; echo "FAIL --serve-token-file done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file-ttl: real automatic expiry, the one piece plain
  # --serve-token-file still lacked (it can rotate/revoke live, but an
  # unedited file's own tokens stayed valid forever). A 2s TTL, a fresh
  # token file, and real sleeps (the same mtime-comparison-needs-a-real-
  # elapsed-interval technique the DataLinkUpdate checks above already
  # use) prove a token that authenticated moments ago stops working once
  # the file goes stale, and starts working again the instant the file is
  # rewritten (even with the IDENTICAL token text) - `touch`-to-renew,
  # no restart.
  TTL_LOG="$TMPW/serve_token_ttl.log"
  TTL_PATH="$TMPW/serve_tokens_ttl.txt"
  printf 'ttltoken\n' > "$TTL_PATH"
  chmod 0600 "$TTL_PATH"  # owner-only, same as any real deployment would need - see the permissions test below
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$TTL_PATH" --serve-token-file-ttl 2 --serve-max-requests 3 > "$TTL_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$TTL_PATH" --serve-token-file-ttl 2 --serve-max-requests 3 > "$TTL_LOG" 2>&1 &
  fi
  TTL_PID=$!

  TTL_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$TTL_LOG" 2>/dev/null; then
      TTL_PORT="$(grep "^serve: listening on port " "$TTL_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$TTL_PORT" ]; then
    cat "$TTL_LOG"; echo "FAIL: --serve-token-file-ttl server never printed its listening port within 10s"; fail=1
    kill "$TTL_PID" 2>/dev/null || true
    wait "$TTL_PID" 2>/dev/null || true
  else
    set +e
    TTL_RESP_FRESH="$(curl -s --max-time 10 -H 'Authorization: Bearer ttltoken' -X POST --data 'print("fresh ok")' "http://127.0.0.1:$TTL_PORT/run")"
    sleep 4
    TTL_CODE_EXPIRED="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ttltoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$TTL_PORT/run")"
    printf 'ttltoken\n' > "$TTL_PATH"
    TTL_RESP_RENEWED="$(curl -s --max-time 10 -H 'Authorization: Bearer ttltoken' -X POST --data 'print("renewed ok")' "http://127.0.0.1:$TTL_PORT/run")"
    set -e
    echo "$TTL_RESP_FRESH" | grep -q "^fresh ok$" && echo "ok   --serve-token-file-ttl accepts a token right after the file was written (well inside the TTL)" || { echo "$TTL_RESP_FRESH"; echo "FAIL --serve-token-file-ttl rejected a fresh token"; fail=1; }
    [ "$TTL_CODE_EXPIRED" = "401" ] && echo "ok   the identical token is rejected once the file's own age exceeds --serve-token-file-ttl, with no edit to the file at all - real automatic expiry" || { echo "FAIL --serve-token-file-ttl still accepted a token from a stale file (HTTP $TTL_CODE_EXPIRED, expected 401) - expiry did not take effect"; fail=1; }
    echo "$TTL_RESP_RENEWED" | grep -q "^renewed ok$" && echo "ok   rewriting the file (even with the identical token text) renews it - access resumes immediately, no restart needed" || { echo "$TTL_RESP_RENEWED"; echo "FAIL --serve-token-file-ttl did not accept the token again after the file was rewritten"; fail=1; }

    set +e; wait "$TTL_PID"; TTL_EC=$?; set -e
    if [ "$TTL_EC" -eq 124 ]; then
      cat "$TTL_LOG"; echo "FAIL: --serve-token-file-ttl process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$TTL_EC" -ne 0 ]; then
      cat "$TTL_LOG"; echo "FAIL: --serve-token-file-ttl process exited $TTL_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=3$" "$TTL_LOG" && echo "ok   --serve-token-file-ttl server exited cleanly on its own after 3 real HTTP requests" || { cat "$TTL_LOG"; echo "FAIL --serve-token-file-ttl done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file hashed entries ("sha256:HEX"): the file holds only
  # a digest, never the real bearer secret, closing the "no hashing" gap
  # named alongside rotation/revocation/expiry above. Real SHA-256 hex
  # digests below (computed with `sha256sum`, not made up) for two real
  # tokens - a bare one ("hashedtoken123") and a named one
  # ("ci3:secretXYZ") - prove the server actually hashes the PRESENTED
  # token and compares digests, rather than, say, accidentally comparing
  # the presented plaintext against the stored hex string itself (which
  # would make every request fail, never succeed).
  HASH_LOG="$TMPW/serve_token_hash.log"
  HASH_PATH="$TMPW/serve_tokens_hash.txt"
  printf 'sha256:79d8dad2f0a04420fd1e0b3c2090350a527c9e8b147bba7a06e8c38ed666a034\nci3:sha256:8800d70b1d06d18497e333a3942da0037e660a66250a081e570073ad533c5ddc\n' > "$HASH_PATH"
  chmod 0600 "$HASH_PATH"  # owner-only, same as any real deployment would need - see the permissions test below
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$HASH_PATH" --serve-max-requests 4 > "$HASH_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$HASH_PATH" --serve-max-requests 4 > "$HASH_LOG" 2>&1 &
  fi
  HASH_PID=$!

  HASH_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$HASH_LOG" 2>/dev/null; then
      HASH_PORT="$(grep "^serve: listening on port " "$HASH_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$HASH_PORT" ]; then
    cat "$HASH_LOG"; echo "FAIL: --serve-token-file (hashed entries) server never printed its listening port within 10s"; fail=1
    kill "$HASH_PID" 2>/dev/null || true
    wait "$HASH_PID" 2>/dev/null || true
  else
    set +e
    HASH_CODE_NOAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$HASH_PORT/run")"
    HASH_CODE_WRONG="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer notthetoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$HASH_PORT/run")"
    HASH_RESP_OK="$(curl -s --max-time 10 -H 'Authorization: Bearer hashedtoken123' -H 'Accept: application/json' -X POST --data 'print("hashed ok")' "http://127.0.0.1:$HASH_PORT/run")"
    HASH_RESP_NAMED="$(curl -s --max-time 10 -H 'Authorization: Bearer secretXYZ' -H 'Accept: application/json' -X POST --data 'print("named hashed ok")' "http://127.0.0.1:$HASH_PORT/run")"
    set -e
    [ "$HASH_CODE_NOAUTH" = "401" ] && echo "ok   --serve-token-file with hashed entries still rejects a request with no Authorization header with 401" || { echo "FAIL --serve-token-file (hashed) no-auth request returned HTTP $HASH_CODE_NOAUTH, expected 401"; fail=1; }
    [ "$HASH_CODE_WRONG" = "401" ] && echo "ok   --serve-token-file with hashed entries rejects a wrong token with 401 - it genuinely hashes the presented token and compares, not a lucky accident" || { echo "FAIL --serve-token-file (hashed) wrong-token request returned HTTP $HASH_CODE_WRONG, expected 401"; fail=1; }
    [ "$HASH_RESP_OK" = '{"ok":true,"output":["hashed ok"]}' ] && echo "ok   presenting the real plaintext token authenticates against its file-stored sha256:HEX digest alone, with no spurious \"caller\":\"sha256\" field - the leading \"sha256:\" wasn't misparsed as a NAME: prefix, and the file itself never held the real secret" || { echo "$HASH_RESP_OK"; echo "FAIL --serve-token-file did not accept the real plaintext token for a bare hashed entry, or returned an unexpected caller field"; fail=1; }
    [ "$HASH_RESP_NAMED" = '{"ok":true,"output":["named hashed ok"],"caller":"ci3"}' ] && echo "ok   a named NAME:sha256:HEX entry hashes and authenticates independently, still echoing its own caller name back in the JSON response" || { echo "$HASH_RESP_NAMED"; echo "FAIL --serve-token-file named-hashed-entry request did not return the expected caller-tagged JSON"; fail=1; }

    set +e; wait "$HASH_PID"; HASH_EC=$?; set -e
    if [ "$HASH_EC" -eq 124 ]; then
      cat "$HASH_LOG"; echo "FAIL: --serve-token-file (hashed entries) process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$HASH_EC" -ne 0 ]; then
      cat "$HASH_LOG"; echo "FAIL: --serve-token-file (hashed entries) process exited $HASH_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=4$" "$HASH_LOG" && echo "ok   --serve-token-file (hashed entries) server exited cleanly on its own after 4 real HTTP requests" || { cat "$HASH_LOG"; echo "FAIL --serve-token-file (hashed entries) done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file loose permissions: the file's own group/other-read
  # bits are checked fresh on every request, the same live-reconsideration
  # TTL/rotation/revocation already get - starts the file world-readable
  # (0644), proves a real correct token is still rejected (the file is
  # untrustworthy regardless of what it says), tightens it to 0600 WHILE
  # the server keeps running and proves the identical token now succeeds
  # with no restart, then loosens it right back to 0644 and proves access
  # is revoked again just as live - not a one-time startup check.
  PERM_LOG="$TMPW/serve_token_perm.log"
  PERM_PATH="$TMPW/serve_tokens_perm.txt"
  printf 'permtoken\n' > "$PERM_PATH"
  chmod 0644 "$PERM_PATH"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$PERM_PATH" --serve-max-requests 3 > "$PERM_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$PERM_PATH" --serve-max-requests 3 > "$PERM_LOG" 2>&1 &
  fi
  PERM_PID=$!

  PERM_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$PERM_LOG" 2>/dev/null; then
      PERM_PORT="$(grep "^serve: listening on port " "$PERM_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$PERM_PORT" ]; then
    cat "$PERM_LOG"; echo "FAIL: --serve-token-file (permissions) server never printed its listening port within 10s"; fail=1
    kill "$PERM_PID" 2>/dev/null || true
    wait "$PERM_PID" 2>/dev/null || true
  else
    set +e
    PERM_CODE_LOOSE="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer permtoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$PERM_PORT/run")"
    chmod 0600 "$PERM_PATH"
    PERM_RESP_TIGHT="$(curl -s --max-time 10 -H 'Authorization: Bearer permtoken' -X POST --data 'print("tight perms ok")' "http://127.0.0.1:$PERM_PORT/run")"
    chmod 0644 "$PERM_PATH"
    PERM_CODE_LOOSE_AGAIN="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer permtoken' -X POST --data 'print("should not run either")' "http://127.0.0.1:$PERM_PORT/run")"
    set -e
    if [ "$IS_WINDOWS" = 1 ]; then
      # Not a pass: TokenFilePermissionsOk (main.cpp) is a documented no-op
      # on Windows - there are no POSIX group/other read bits to inspect
      # (Git-Bash's chmod above changes nothing the app could read either),
      # and NTFS ACLs are not examined - so the two loose-permissions
      # rejections below cannot be exercised there. Both are left FAIL on
      # every other platform; the server start, the tight-permissions
      # request and the clean exit are still checked here exactly as on
      # Linux/macOS, so the Winsock path itself is not skipped.
      echo "skip (Windows: POSIX permission bits not checked - TokenFilePermissionsOk is a documented no-op there) --serve-token-file world-readable (0644) rejection (HTTP $PERM_CODE_LOOSE)"
    else
      [ "$PERM_CODE_LOOSE" = "401" ] && echo "ok   --serve-token-file rejects a correct token when the file itself is world-readable (0644) - the token file's own permissions, not just what it contains, are checked" || { echo "FAIL --serve-token-file accepted a token from a world-readable (0644) file, expected 401 (HTTP $PERM_CODE_LOOSE)"; fail=1; }
    fi
    echo "$PERM_RESP_TIGHT" | grep -q "^tight perms ok$" && echo "ok   chmod'ing the file to 0600 WHILE the server keeps running immediately allows the identical token - live, no restart needed, same as TTL/rotation above" || { echo "$PERM_RESP_TIGHT"; echo "FAIL --serve-token-file still rejected the token after tightening the file to 0600"; fail=1; }
    if [ "$IS_WINDOWS" = 1 ]; then
      echo "skip (Windows: POSIX permission bits not checked - TokenFilePermissionsOk is a documented no-op there) --serve-token-file re-loosened (0644) revocation (HTTP $PERM_CODE_LOOSE_AGAIN)"
    else
      [ "$PERM_CODE_LOOSE_AGAIN" = "401" ] && echo "ok   chmod'ing the file back to 0644 revokes access again on the very next request - a live recheck every time, not a one-shot startup gate" || { echo "FAIL --serve-token-file accepted a token again after loosening the file back to 0644, expected 401 (HTTP $PERM_CODE_LOOSE_AGAIN)"; fail=1; }
    fi

    set +e; wait "$PERM_PID"; PERM_EC=$?; set -e
    if [ "$PERM_EC" -eq 124 ]; then
      cat "$PERM_LOG"; echo "FAIL: --serve-token-file (permissions) process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$PERM_EC" -ne 0 ]; then
      cat "$PERM_LOG"; echo "FAIL: --serve-token-file (permissions) process exited $PERM_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=3$" "$PERM_LOG" && echo "ok   --serve-token-file (permissions) server exited cleanly on its own after 3 real HTTP requests" || { cat "$PERM_LOG"; echo "FAIL --serve-token-file (permissions) done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # A missing/unreadable token file must fail CLOSED (deny everything),
  # never silently fall back to the fully-open behavior an empty
  # serve_tokens alone would mean - a typo'd --serve-token-file path must
  # not accidentally leave the compute server open to the network.
  MISSING_LOG="$TMPW/serve_token_file_missing.log"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$TMPW/does_not_exist.txt" --serve-max-requests 1 > "$MISSING_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$TMPW/does_not_exist.txt" --serve-max-requests 1 > "$MISSING_LOG" 2>&1 &
  fi
  MISSING_PID=$!
  MISSING_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$MISSING_LOG" 2>/dev/null; then
      MISSING_PORT="$(grep "^serve: listening on port " "$MISSING_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done
  if [ -z "$MISSING_PORT" ]; then
    cat "$MISSING_LOG"; echo "FAIL: --serve-token-file (missing file) server never printed its listening port within 10s"; fail=1
    kill "$MISSING_PID" 2>/dev/null || true
    wait "$MISSING_PID" 2>/dev/null || true
  else
    set +e
    MISSING_CODE="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$MISSING_PORT/run")"
    set -e
    [ "$MISSING_CODE" = "401" ] && echo "ok   --serve-token-file pointed at a file that doesn't exist fails CLOSED (401), not open - a bad path can't accidentally disable auth" || { echo "FAIL --serve-token-file with a missing file returned HTTP $MISSING_CODE, expected 401 (fail closed)"; fail=1; }
    set +e; wait "$MISSING_PID"; set -e
  fi
fi

# STEP rational B-spline interoperability (io/FileIgesStep.cpp, see
# step_rational_script.txt and the two fixtures it opens). Real CAD
# exporters write a rational B-spline surface/curve as the STANDARD ISO
# 10303-21 complex entity with the attributes split over their own
# supertypes - B_SPLINE_SURFACE(...)B_SPLINE_SURFACE_WITH_KNOTS(...)
# RATIONAL_B_SPLINE_SURFACE(...) - and Dino 8's reader refused exactly that
# layout ("args.size() < 12" / "< 9") while its own writer emitted a flat
# variant nothing else reads (every attribute packed into the WITH_KNOTS
# part behind a leading empty field). Regression for both halves: the
# reader now accepts both layouts (older Dino 8 files keep importing), the
# writer emits the standard one with lossless REALs, and a bare top-level
# B-spline surface (what the kernel's own NurbsSurface::SaveStep writes)
# imports as a free surface object. Confirmed failing first: the pre-fix
# binary reports "STEP: 0 breps (0 trimmed faces), 1 curve, 0 points; 1
# unsupported entity skipped" and "FAIL expect_objects 3 (got 1)" on the
# first fixture, and "No usable geometry found" on the kernel-written one.
sed "s|@TMP@|$TMPW|g" "$HERE/step_rational_script.txt" > "$TMPW/step_rational_script.txt"
cp "$HERE/step_rational_standard_layout_fixture.stp" "$TMPW/step_rational_standard_layout_fixture.stp"
cp "$HERE/step_kernel_rational_sphere_fixture.stp" "$TMPW/step_kernel_rational_sphere_fixture.stp"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  RAT="$(timeout 900 "$BIN" --smoke 80 --script "$TMPW/step_rational_script.txt" 2>&1)" || { echo "$RAT"; echo "FAIL: step rational script exited non-zero"; exit 1; }
else
  RAT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 80 --script "$TMPW/step_rational_script.txt" 2>&1)" || { echo "$RAT"; echo "FAIL: step rational script exited non-zero"; exit 1; }
fi
ratcheck() { if echo "$RAT" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$RAT" "$1"; fail=1; fi; }
ratcount() { if [ "$(grep -c "$1" <<<"$RAT")" -ge "$2" ]; then echo "ok   $3"; else echo "FAIL $3"; near "$RAT" "$1"; fail=1; fi; }
# (1) the hand-written standard-layout fixture
ratcheck "STEP: 1 brep (0 trimmed faces), 2 curves, 0 points, 1 face fell back to untrimmed" "a standard-layout rational B_SPLINE_SURFACE face (quarter cylinder) plus a standard-layout AND a flat-layout rational B_SPLINE_CURVE all imported - no entity 'unsupported', no face dropped (was: 0 breps, 1 curve, 1 unsupported entity skipped)"
ratcheck "^ok   expect_objects 3" "the standard-layout fixture became exactly 3 objects (was: 1, only the flat-layout curve)"
ratcheck "Object [0-9]* (polysurface) layer Default name 'QuarterCylinder'" "the quarter-cylinder face imported as a polysurface named from its SHELL_BASED_SURFACE_MODEL"
ratcheck "^history:   1 faces, 4 edges, open" "the untrimmed quarter-cylinder face is one open face with its four natural edges"
ratcount "^history:   degree 2, 3 control points, rational, open" 2 "both quarter arcs (standard split layout AND the older flat layout) decode as degree-2, 3-control-point RATIONAL open curves - the weights were read, not dropped"
ratcount "^history: Curve [0-9]* length = 7.854" 2 "each quarter arc's length is 5*pi/2 = 7.854 - a genuine circular arc (the sqrt(2)/2 middle weight applied), not an unweighted parabola (which would be 7.969)"
ratcheck "^history: Total length = 15.71 Millimeters" "the two arcs together: 5*pi = 15.71"
ratcheck "^history: Area = 314.1 square Millimeters" "the quarter cylinder's area is 100*pi = 314.2 (314.1 on the tessellated mesh) (radius 10 x height 20 x pi/2): its sqrt(2)/2 weights were read at full precision"
ratcheck "^history: Bounding box min 0,0,0 max 10,10,20" "the quarter cylinder's bounding box is exactly 0,0,0 - 10,10,20"
# (2) the file the kernel's own NurbsSurface::SaveStep writes (a sphere, centre 1,2,3, radius 2.5)
ratcheck "STEP: 0 breps (0 trimmed faces), 0 curves, 0 points, 1 surface" "a bare top-level rational B_SPLINE_SURFACE entity in the standard layout - the kernel's own SaveStep output - imports as one free surface object (was: 'No usable geometry found')"
ratcheck "^ok   expect_objects 1" "the kernel-written sphere file became exactly 1 object"
ratcheck "^history:   degree 2 x 2, CVs 9 x 5" "the imported sphere keeps the kernel's exact degree-(2,2), 9x5 control net"
ratcheck "^history: Area = 78.4 square Millimeters" "the imported sphere's area is 4*pi*2.5^2 = 78.54 (78.4 on the tessellated mesh): every sqrt(2)/2 weight read back exactly"
ratcheck "^history: Bounding box min -1.5,-0.5,0.5 max 3.5,4.5,5.5" "the imported sphere's bounding box is exactly centre (1,2,3) +/- 2.5"
# (3) ExportStep -> ImportStep round trip of the app's own rational geometry
ratcount "^history: Volume = 4177 cubic Millimeters" 2 "the reimported sphere (rational faces written by ExportStep in the standard layout) has the identical tessellated volume 4177 as the original - weights, knots and control points round-tripped losslessly"
ratcheck "^ok   expect_objects 2" "the round-trip file came back as exactly 2 objects (sphere polysurface + circle)"
ratcheck "^history: Total length = 31.42 Millimeters" "the round-tripped circle's length is 2*pi*5 = 31.42"
grep -q "^#[0-9]*=(BOUNDED_SURFACE()B_SPLINE_SURFACE(2,2,((#" "$TMPW/rational_roundtrip.stp" && echo "ok   rational_roundtrip.stp writes the sphere's rational face as the STANDARD complex entity: B_SPLINE_SURFACE carries the degrees and control net" || { echo "FAIL rational_roundtrip.stp lacks the standard B_SPLINE_SURFACE(u_degree,v_degree,control_points,...) part"; fail=1; }
grep -q ",.F.,.F.,.F.)B_SPLINE_SURFACE_WITH_KNOTS((" "$TMPW/rational_roundtrip.stp" && echo "ok   rational_roundtrip.stp's B_SPLINE_SURFACE_WITH_KNOTS part carries only the knot data, right after the three B_SPLINE_SURFACE flags" || { echo "FAIL rational_roundtrip.stp's B_SPLINE_SURFACE_WITH_KNOTS part is not the standard knot-only form"; fail=1; }
grep -q ")GEOMETRIC_REPRESENTATION_ITEM()RATIONAL_B_SPLINE_SURFACE(((" "$TMPW/rational_roundtrip.stp" && echo "ok   rational_roundtrip.stp carries the weights as a RATIONAL_B_SPLINE_SURFACE grid" || { echo "FAIL rational_roundtrip.stp has no RATIONAL_B_SPLINE_SURFACE weight grid"; fail=1; }
grep -q "0\.7071067811865[0-9][0-9]" "$TMPW/rational_roundtrip.stp" && echo "ok   rational_roundtrip.stp writes the sphere's sqrt(2)/2 weights losslessly (17 significant digits), not rounded to 9" || { echo "FAIL rational_roundtrip.stp rounds its weights (no full-precision sqrt(2)/2)"; fail=1; }
grep -q "B_SPLINE_SURFACE()\|B_SPLINE_SURFACE_WITH_KNOTS(,\|B_SPLINE_CURVE()\|B_SPLINE_CURVE_WITH_KNOTS(," "$TMPW/rational_roundtrip.stp" && { echo "FAIL rational_roundtrip.stp still contains the flat pre-fix layout (an empty supertype part or a leading empty field)"; fail=1; } || echo "ok   rational_roundtrip.stp contains no empty B_SPLINE_SURFACE()/B_SPLINE_CURVE() part and no leading empty field - the flat layout only Dino 8 could read is gone"

# Kernel primitives reached from the app commands (kernel_wiring_script.txt):
# MergeSrf -> NurbsSurface::Join (exact control-net splice, 7x4 for a bicubic
# split at 0.4, instead of a 25x17 sample-and-refit), ChamferEdge/ChamferSrf
# on a cylinder rim -> ChamferCylinderRim (exact cone, unequal distances,
# re-closed into a true 4-face/7-edge solid), and the curve MakeUniform ->
# NurbsCurve::MakeUniform (domain-preserving, deviation-gated). The second half
# of the same script proves the section-anchored single-section Sweep1/Sweep2
# (a section anywhere along the rail is reproduced exactly and the surface
# covers the whole rail - the kernel call alone carried it rigidly from the
# rail start) and the exact interpolating Loft (every section reproduced,
# curves reversed/re-seamed first, capped solids, mixed open/closed refused).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  KW="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/kernel_wiring_script.txt" 2>&1)" || { echo "$KW"; echo "FAIL: kernel-wiring script exited non-zero"; exit 1; }
else
  KW="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/kernel_wiring_script.txt" 2>&1)" || { echo "$KW"; echo "FAIL: kernel-wiring script exited non-zero"; exit 1; }
fi
kwcheck() { if grep -q "$1" <<<"$KW"; then echo "ok   $2"; else echo "FAIL $2"; near "$KW" "$1"; fail=1; fi; }
kwcount() { local n; n="$(grep -c "$1" <<<"$KW" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$KW" "$1"; fail=1; fi; }
echo "$KW" | grep -E "^(ok|FAIL)"
if grep -q "^FAIL" <<<"$KW"; then fail=1; fi
kwcheck "^ok   expect_objects 4" "kernel-wiring script: the merged surface is the only surface left (plus the three boxes BoundingBox leaves behind)"
kwcheck "^ok   expect_objects 0 (got 0)" "kernel-wiring script ended with every section's own objects cleaned up"
kwcheck "MergeSrf: merged 2 surfaces into one (exact merge: control nets spliced across the shared edge, 7 x 4 control points, no refit)" "MergeSrf on the two halves SplitFace cut from a non-planar bicubic reaches kernel NurbsSurface::Join and says so: an exact merge, not '(refit through samples)'"
kwcheck "degree 3 x 3, CVs 7 x 4" "the merged surface's control net is exactly 7 x 4 (two 4x4 halves sharing one boundary row), not the 25 x 17 sample grid the old refit built"
kwcount "Bounding box min 0,0,0 max 9,9,3" 3 "the original bicubic, its two halves and the merged surface all report the identical bounding box"
kwcount "Area = 84.57 square" 3 "...and the identical area (84.57): the exact merge reproduces the original surface"
kwcheck "! MergeSrf: the surfaces do not share an edge" "MergeSrf on two planes with no shared edge is still refused with the original diagnostic after the Join attempt throws"
# MergeSrf compatible-form merges: pairs that are NOT already in splice-ready form
# (degree mismatch, different knot spacing along the edge, edge walked in opposite
# directions) now still merge exactly instead of dropping to the sample-and-refit;
# the refit survives only for the one pair whose edge is parameterized differently.
kwcount "exact merge: control nets spliced across the shared edge, 7 x 4 control points, no refit)" 2 "MergeSrf on a bicubic + a biquadratic patch sharing an edge merges exactly into a 7 x 4 net (the second 7 x 4 besides the SplitFace halves above): the lower degree is raised in both directions instead of refitting"
kwcheck "made the pair compatible along the shared edge first (.*degree along the shared edge 2 -> 3.*degree across the shared edge 2 -> 3); the merged surface reproduces both inputs to" "...and says what it did: the quadratic patch's degree raised 2 -> 3 along and across the edge, the result reproducing both inputs"
kwcheck "exact merge: control nets spliced across the shared edge, 7 x 7 control points, no refit)" "MergeSrf on two bicubics whose shared edge carries different knots (interior knot at 1/2 vs 1/3 and 2/3) merges exactly into a 7 x 7 net: the union {1/3, 1/2, 2/3} inserted into both"
kwcheck "inserted 2 knot(s) along the shared edge into the .* surface" "...and reports the two knots it inserted into one patch"
kwcheck "inserted 1 knot(s) along the shared edge into the .* surface" "...and the one knot it inserted into the other"
kwcheck "exact merge: control nets spliced across the shared edge, 4 x 7 control points, no refit)" "MergeSrf on two bicubics meeting along y = 3 with one of them Flip'd (so they walk the shared edge in opposite directions) merges exactly into a 4 x 7 net"
kwcheck "reversed the second surface along the shared edge so both run the same way" "...and reports turning the second patch back along the edge"
kwcheck "swapped the second surface's U and V so its shared edge is a U side" "...and swapping its U/V (the shared edge sits on a V side of the second patch)"
kwcount "refit through samples" 1 "the sample-and-refit fallback ran exactly once in the whole kernel-wiring script: the three compatible-form merges above did NOT fall back to it"
kwcheck "refit through samples; the exact kernel merge refused this pair: the two surfaces do not share an edge (closest pair of sides 0.05" "the one pair that still refits (a shared segment traced with a different parameterization, 0.05 apart) says WHY the exact merge refused it"
# Rim chamfers: Volume lines in order = plain cylinder, ChamferEdge top rim
# 0.6/0.4, swapped 0.4/0.6, bottom rim 0.6/0.4, ChamferSrf 0.5, Distance/Angle refusal.
KW_VOLS="$(echo "$KW" | grep -o "Volume = [0-9.]* cubic" | awk '{printf "%s ", $3}')"
if echo "$KW_VOLS" | awk 'function abs(x) { return x < 0 ? -x : x } { exit !(abs($1-62.7)<0.03 && abs($2-61.3)<0.03 && abs($3-61.35)<0.03 && abs($4-61.3)<0.03 && abs($5-61.26)<0.03 && abs($6-62.7)<0.03) }'; then
  echo "ok   cylinder rim volumes read 62.7 (plain), 61.3 (top 0.6/0.4), 61.35 (swapped 0.4/0.6), 61.3 (bottom rim), 61.26 (ChamferSrf 0.5), 62.7 (Angle refused, untouched)"
else
  echo "FAIL cylinder rim volumes unexpected: $KW_VOLS"; fail=1
fi
if echo "$KW_VOLS" | awk 'function abs(x) { return x < 0 ? -x : x }
  function rem(dw, dc,   R) { R = 2; return (2 * 3.14159265358979 * dw / dc) * (R * R * R / 3 - (R - dc) * R * R / 2 + (R - dc) ^ 3 / 6) }
  { exit !(abs(($1 - $2) - rem(0.6, 0.4)) < 0.05 && abs(($1 - $3) - rem(0.4, 0.6)) < 0.05 && abs(($1 - $4) - rem(0.6, 0.4)) < 0.05 && abs(($1 - $5) - rem(0.5, 0.5)) < 0.01) }'; then
  echo "ok   the volume each rim chamfer removes matches the revolved-triangle closed form (2*pi*dw/dc)*(R^3/3-(R-dc)*R^2/2+(R-dc)^3/6): 1.407 (0.6/0.4), 1.357 (0.4/0.6), 1.440 (0.5/0.5)"
else
  echo "FAIL rim chamfer removed volumes do not match the closed form: $KW_VOLS"; fail=1
fi
kwcheck "ChamferEdge: edge .* of object .* replaced with an exact chamfer (distance1 0.6, distance2 0.4; exact cone on the cylinder rim" "ChamferEdge Distance1=0.6 Distance2=0.4 on a cylinder rim reaches kernel::ChamferCylinderRim (wall 0.6 / cap 0.4)"
kwcheck "ChamferEdge: edge .* of object .* replaced with an exact chamfer (distance1 0.4, distance2 0.6; exact cone on the cylinder rim" "...and the swapped distances are a different, equally exact chamfer"
kwcheck "ChamferSrf: faces .* and .* of object .* replaced with an exact chamfer (distance 0.5; exact cone on the cylinder rim)" "ChamferSrf on a cylinder's cap and wall now reaches the exact cone instead of the approximate 'contact points off by' ruled surface"
kwcount "4 faces, 7 edges, closed solid" 3 "every rim chamfer (top, bottom, ChamferSrf) is a true closed 4-face/7-edge solid with exact circular caps, not the kernel's raw 261-edge open polygon shell"
kwcheck "Area = 84.01 square" "the top-rim chamfer's area (84.01) matches the closed form 2*pi*R*(L-dw)+pi*R^2+pi*(R-dc)^2+pi*(2R-dc)*sqrt(dw^2+dc^2) = 84.056 to the display mesh's 0.05"
kwcheck "ChamferSrf: built between object .* and .*, radius 3" "a ChamferSrf cap setback of 3 on the R=2 cylinder is refused by the kernel and falls through to the approximate surface exactly as before"
kwcheck "cylinder-rim attempt: Distance/Angle mode has no cylinder-rim construction" "ChamferEdge Angle= on a cylinder rim keeps its clear 'needs the whole object to be planar-faced' diagnostic and leaves the cylinder untouched"
# Curve MakeUniform
kwcheck "! MakeUniform: curve .* left unchanged - uniform knots would move it by up to 0.5, more than Tolerance 0.001" "curve MakeUniform at the default (document) Tolerance refuses a re-knot that would move the curve 0.5 and reports the measured 0.5 - the old call shipped it unmeasured"
kwcheck "! MakeUniform: curve .* left unchanged - uniform knots would move it by up to 0.5, more than Tolerance 0.4" "...and Tolerance=0.4 still refuses (0.5 > 0.4)"
kwcheck "MakeUniform: 1 curve(s) now have uniform knots (largest measured shape change 0.5, domain preserved)" "Tolerance=0.6 commits, reporting the exact closed-form 0.5 shift"
kwcount "Curve .* domain: 0 to 1" 3 "the curve's domain is 0 to 1 before, after the refused runs and after the committed re-knot (the old call re-domained it to 0 to 2)"
kwcheck "MakeUniform: 0 curve(s) now have uniform knots; 1 already uniform" "a second MakeUniform finds the curve already uniform (NoOpAlreadySatisfied) and changes nothing"

# Surface construction commands (last section of kernel_wiring_script.txt):
# NetworkSrf with 3 curves -> NurbsSurface::CoonsPatchTriangular (closure
# against the DOCUMENT tolerance, order/direction resolved, measured boundary
# deviation printed, old fitted patch kept as the printed fail-open path),
# Sweep2 with several cross-sections -> Brep::Sweep2Sections, and Patch of
# non-planar data -> NurbsSurface::FitPatch + Brep::TrimmedPatchFace. Everything
# below is read only from this section's own output (from its first NetworkSrf
# on), so the earlier sections' areas and boxes cannot satisfy these.
KW3="$(echo "$KW" | sed -n '/Command: NetworkSrf/,$p')"
kw3check() { if echo "$KW3" | grep -q "$1"; then echo "ok   $2"; else echo "FAIL $2"; near "$KW3" "$1"; fail=1; fi; }
kw3count() { local n; n="$(echo "$KW3" | grep -c "$1" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$KW3" "$1"; fail=1; fi; }
kw3count "NetworkSrf: exact 3-sided Coons patch through 3 curves (all 3 boundaries reproduced exactly)" 3 "NetworkSrf with exactly 3 curves reaches the kernel's CoonsPatchTriangular three times (scrambled straight triangle, curved out-of-plane third edge, open corner inside tolerance) and says so"
kw3check "Area = 50 square" "the scrambled straight triangle (two edges drawn the wrong way round) gives the closed-form area 50 of the triangle (0,0) (10,0) (10,10)"
KW3_DEVS="$(echo "$KW3" | grep -o "measured boundary deviation from the closed loop [0-9.e-]*" | awk '{print $NF}')"
if [ "$(echo "$KW3_DEVS" | wc -l)" = "4" ] && echo "$KW3_DEVS" | awk '{ if ($1 + 0 > 1e-12) bad = 1 } END { exit bad }'; then
  echo "ok   all 4 exact Coons results (3 triangular + 1 four-curve) print a MEASURED boundary deviation from their closed loop below 1e-12 (got: $(echo $KW3_DEVS))"
else
  echo "FAIL the exact Coons boundary deviations are not all 4 values below 1e-12: $KW3_DEVS"; fail=1
fi
kw3check "corners closed within the document tolerance 0.001 (largest gap 0.0005 split between the two ends)" "a 3-curve loop open by 0.0005 is closed against the document tolerance 0.001 (ends moved to their midpoint) and still gets the exact patch"
kw3check "NetworkSrf: exact Coons patch through 4 curves (all 4 boundaries reproduced exactly), corners closed within the document tolerance 0.001 (largest gap 0.0004" "...and so does a 4-curve loop open by 0.0004"
kw3check "NetworkSrf: fitted bilinear Coons patch through 3 curves (approximate fallback: the 3 curves do not close into a loop within the document tolerance 0.001 (largest corner gap 0.5))" "a 3-curve set open by 0.5 is NOT a loop: the old fitted patch runs and the printed reason is the measured gap against the tolerance"
kw3count "fitted bilinear Coons patch" 1 "the old fitted bilinear Coons patch ran exactly once in the section: the four loops above did not fall back to it"
# Sweep2, several cross-sections
kw3check "Sweep2: exact kernel multi-section sweep (3 sections, 33 rail stations); measured: sections reproduced to [0-9.e-]*, wall edges within [0-9.e-]* of the rails; document tolerance 0.001" "Sweep2 with 3 cross-sections between straight diverging rails reaches the kernel's Brep::Sweep2Sections and prints its measured accuracy"
kw3count "Area = 57.55 square" 2 "the 3-section wall and the one-section exact Brep::Sweep2 wall (same rails, first section only) have the identical area 57.55 - three same-shaped sections reduce to the one-section sweep"
kw3check "Bounding box min 0,0,0 max 6,1.5,10" "the 3-section wall's box is the closed form: x to 6 (the far rail), y to 1.5 (apex of the z = 10 arc, control height 3), z to 10"
kw3check "Sweep2: exact kernel sweep (two-rail frame transport)" "the one-section comparison sweep still takes the existing exact Brep::Sweep2 path"
KW3_SW="$(echo "$KW3" | grep -o "(3 sections, 32 rail stations); measured: sections reproduced to [0-9.e-]*, wall edges within [0-9.e-]* of the rails" | head -1)"
if [ -n "$KW3_SW" ] && echo "$KW3_SW" | awk '{ s = $10; e = $14; exit !(s + 0 < 1e-12 && e + 0 < 1e-4) }'; then
  echo "ok   Sweep2 on cubic rails with three different sections: sections reproduced below 1e-12 and wall edges within 1e-4 of the rails, measured by the kernel ($KW3_SW)"
else
  echo "FAIL Sweep2 on cubic rails: accuracy line missing or out of bounds: $KW3_SW"; fail=1
fi
kw3check "Sweep2: the exact multi-section sweep was not used (dino8::kernel::Brep::Sweep2Sections: the sections are not ordered consistently along the two rails (their anchors cross)); using the scaled-frame fit" "Sweep2 with two sections whose anchors cross is refused by the kernel, the reason is printed and the scaled-frame fit takes over"
kw3check "Sweep2: 2 section(s) along 2 rail stations" "...and that fallback still builds its surface exactly as before"
kw3count "Sweep2: exact kernel multi-section sweep" 2 "exactly the two well-formed multi-section sweeps (straight and cubic rails) reached the kernel"
# Patch, non-planar data
kw3count "Patch: non-planar data - kernel least-squares NURBS" 2 "exactly two Patch inputs reached the kernel's least-squares fit: the closed saddle curve and the nine non-coplanar points"
kw3check "Patch: non-planar data - kernel least-squares NURBS patch (5 x 5 net, worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1.5) trimmed by the closed curve; the face's edge is within [0-9.e-]* of the curve" "Patch of a closed saddle-shaped curve (best-fit plane misses it by 1.5) fits a 5 x 5 NURBS patch within the tolerance and trims it by the curve"
KW3_PATCH="$(echo "$KW3" | grep -o "worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1.5) trimmed by the closed curve; the face's edge is within [0-9.e-]* of the curve" | head -1)"
if [ -n "$KW3_PATCH" ] && echo "$KW3_PATCH" | awk '{ d = $4; e = $(NF-3); exit !(d + 0 < 1e-3 && e + 0 < 1.5e-3) }'; then
  echo "ok   ...with the printed data deviation below the 0.001 tolerance and the trimmed edge within 1.5e-3 of the curve ($KW3_PATCH)"
else
  echo "FAIL saddle Patch: deviation/edge figures out of bounds: $KW3_PATCH"; fail=1
fi
KW3_AREA="$(echo "$KW3" | grep -o "Area = [0-9.]* square" | sed -n '5p' | awk '{print $3}')"
if echo "$KW3_AREA" | awk '{ exit !($1 > 83 && $1 < 87) }'; then
  echo "ok   the trimmed saddle patch has area $KW3_AREA, the saddle disc's (about 85.2 for r = 5; the flat disc the old command made is 78.5)"
else
  echo "FAIL the trimmed saddle patch area is $KW3_AREA, expected 83-87 (flat disc: 78.5)"; fail=1
fi
KW3_Z="$(echo "$KW3" | grep -o "Bounding box min -[0-9.]*,-[0-9.]*,-[0-9.]* max [0-9.]*,[0-9.]*,[0-9.]*" | head -1)"
if [ -n "$KW3_Z" ] && echo "$KW3_Z" | awk '{ split($4, lo, ","); split($6, hi, ","); exit !(lo[3] < -1.3 && hi[3] > 1.3 && hi[1] > 4.9 && lo[1] < -4.9) }'; then
  echo "ok   the trimmed saddle patch (the curve deleted first, so the patch alone) really leaves the plane: its box spans x -5..5 and z from below -1.3 to above 1.3 ($KW3_Z), a flat patch would be z = 0"
else
  echo "FAIL the trimmed saddle patch box does not span z -1.4..1.5: $KW3_Z"; fail=1
fi
kw3check "Patch: non-planar data - kernel least-squares NURBS surface through 0 curve(s) and 9 point(s) (2 x 2 net, worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1); untrimmed, spanning the data's extent" "Patch through nine non-coplanar points on z = x y / 4 fits a bilinear 2 x 2 NURBS surface through all of them (best-fit plane misses them by 1)"
kw3check "Area = 17.27 square" "...whose area is the closed-form integral of sqrt(1 + (x^2 + y^2) / 16) over the square, 17.2646 (display mesh 17.27), not the 16 of a flat rectangle"
kw3check "Patch: least-squares plane through 0 curve(s) and 3 point(s)" "Patch of three coplanar points keeps the planar construction (no kernel fit attempted)"
kw3check "! Patch: the input is collinear" "Patch of collinear points keeps its original diagnostic"

# Section-anchored single-section Sweep1/Sweep2 and the exact interpolating Loft
# (the second half of kernel_wiring_script.txt; read its comments for each case).
# kwdist START NTH SKIP N TARGET LIMIT DESC: after the NTH line matching START,
# skip the next SKIP "Closest point" lines, then every one of the following N
# must read a distance within LIMIT of TARGET (the worst one is reported).
kwdist() {
  local r
  r="$(awk -v start="$1" -v nth="$2" -v skip="$3" -v n="$4" -v target="$5" -v lim="$6" '
    !on && $0 ~ start { if (++hits == nth) on = 1; next }
    on && /Closest point/ { idx++; if (idx > skip && idx <= skip + n) { cnt++; e = $NF - target; if (e < 0) e = -e; if (e > worst) worst = e } }
    END { if (!on) print "NOSTART"; else if (cnt != n) print "COUNT " cnt; else if (worst < lim) print "OK " worst + 0; else print "BAD " worst + 0 }' <<<"$KW")"
  case "$r" in OK*) echo "ok   $7 (worst ${r#OK })" ;; *) echo "FAIL $7 ($r)"; near "$KW" "$1"; fail=1 ;; esac
}
KWTINY='\(e-\(0[7-9]\|[1-9][0-9]\)\|e+00\)$'
kwcount "Sweep1: the section is at the rail start; the section's isocurve on the result deviates by [0-9.]*$KWTINY" 2 "Sweep1 with the section AT the rail start (0%) keeps the kernel call unchanged and measures the section's isocurve on the result: < 1e-6 (straight rail and curved rail)"
kwcount "Sweep1: the section sits 40.0% along the rail; the rail was split there and both sides swept from the section and joined; the result reproduces the section to [0-9.]*$KWTINY" 2 "Sweep1 with the section 40% along the rail splits the rail there, sweeps both sides from the section, joins them, and reports the result reproducing the section to < 1e-6 (straight rail and curved rail)"
kwcount "Sweep1: the section sits 100.0% along the rail; swept back along the rail from the section; the result reproduces the section to [0-9.]*$KWTINY" 2 "Sweep1 with the section AT the rail end (100%) sweeps back along the reversed rail and reproduces the section to < 1e-6 (straight rail and curved rail)"
kwcount "Bounding box min -2,-1.912,0 max 2,1.912,10" 3 "a radius-2 circle swept along a straight z = 0..10 rail covers exactly the rail's z = 0..10 whether the circle sits at 0%, 40% or 100% of it (before: z = 0..10, 4..14 and 10..20)"
kwcheck "Bounding box min 0,0,0 max 5,0,12" "Sweep2 along two straight rails with the section 40% of the way up spans the rails' own z = 0..10 (the polyline's 2-high apex rises to 12 at the far end; before: z = 4..16)"
kwcheck "Sweep1: the section sits 40.0% along the rail; the closed rail was re-seamed there; the result reproduces the section to [0-9.]*$KWTINY" "Sweep1 along a CLOSED rail re-seams the rail at the section (no split) and reproduces the section to < 1e-6"
kwdist "the closed rail was re-seamed there" 1 0 6 1 0.001 "...and the periodic tube is the section's radius (1) from the rail at 0, 36, 90, 144, 200 and 300 degrees"
kwcheck "Sweep2: exact sweep not used - the section sits at the start of rail 1 but at the interior of rail 2, so one rail has nothing to sweep on one side of it; falling back to the approximate section-anchored sweep" "Sweep2 with the section at the start of rail 1 but interior to rail 2 refuses the exact path, prints why, and falls back"
kwcheck "Sweep2: 1 section(s) along 2 rail stations" "...and the older approximate section-anchored sweep still produces the surface"
kwdist "Sweep1: the section is at the rail start" 2 0 8 0 0.000001 "curved rail, section at 0%: 8 points on the section circle lie on the swept surface to < 1e-6"
kwdist "Sweep1: the section is at the rail start" 2 8 6 1.5 0.001 "...and the rail's points at 0, 20, ..., 100% are all the tube radius (1.5) from it"
kwdist "Sweep1: the section sits 40.0% along the rail; the rail was split" 2 0 8 0 0.000001 "curved rail, section at 40%: 8 points on the section circle lie on the joined surface to < 1e-6"
kwdist "Sweep1: the section sits 40.0% along the rail; the rail was split" 2 8 6 1.5 0.001 "...and ALL six rail points (0..100%) are exactly the tube radius (1.5) from it - a tube around the whole rail (before: 7.2, 4.0, 1.5, 1.2, 0.46, 0.28)"
kwdist "Sweep1: the section sits 100.0% along the rail" 2 0 8 0 0.000001 "curved rail, section at 100%: 8 points on the section circle lie on the surface to < 1e-6"
kwdist "Sweep1: the section sits 100.0% along the rail" 2 8 6 1.5 0.001 "...and all six rail points are the tube radius (1.5) from it (before: 16.1, 14.1, 11.2, 7.8, 4.2, 1.4)"
kwdist "Sweep2: the section is at the start of both rails" 2 0 5 0 0.000001 "Sweep2, curved rails, section at 0%: 5 points on the polyline section lie on the surface to < 1e-6"
kwdist "Sweep2: the section is at the start of both rails" 2 5 12 0 0.05 "...and both rails sampled at 0..100% lie within 0.05 of the surface (they are its sides, to within the 32-station skin)"
kwcheck "Sweep2: the section sits 40.0% along rail 1 and 40.0% along rail 2; both rails were split there and both sides swept from the section and joined; the result reproduces the section to [0-9.]*$KWTINY" "Sweep2 with the section 40% along both rails splits both, sweeps and joins, reproducing the section to < 1e-6"
kwdist "Sweep2: the section sits 40.0% along rail 1 and 40.0% along rail 2" 2 0 5 0 0.000001 "Sweep2, curved rails, section at 40%: 5 points on the section lie on the joined surface to < 1e-6"
kwdist "Sweep2: the section sits 40.0% along rail 1 and 40.0% along rail 2" 2 5 12 0 0.05 "...and both rails, 0..100%, lie within 0.05 of it (before: up to 7.8 away)"
kwdist "Sweep2: the section sits 100.0% along rail 1 and 100.0% along rail 2; swept back" 1 0 5 0 0.000001 "Sweep2, curved rails, section at 100%: 5 points on the section lie on the surface to < 1e-6"
kwdist "Sweep2: the section sits 100.0% along rail 1 and 100.0% along rail 2; swept back" 1 5 12 0 0.05 "...and both rails, 0..100%, lie within 0.05 of it"
# Loft
kwcheck "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.]*${KWTINY%\$}; aligned first: 1 curve(s) reversed, 0 seam(s) moved" "Loft through three lines (the middle one drawn the other way) is the exact interpolating kernel loft: the middle line is reversed to run with the others and every section is reproduced to < 1e-6"
kwcheck "Area = 147.9 square" "...and the sheet has the exact area 5(sqrt5 + asinh 2) * 10 = 147.9 (before: the ribbon along the sample polyline measured 6.7)"
kwdist "aligned first: 1 curve.s. reversed, 0 seam.s. moved" 1 0 11 0 0.000001 "...and all 11 sampled points of the three lines (both ends and the middle of each) lie on the lofted surface to < 1e-6 (before: the line ends were 0.88 off and the sheet never spanned the lines)"
kwcheck "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.]*${KWTINY%\$}; aligned first: 1 curve(s) reversed, 2 seam(s) moved; end caps added (Cap=Yes), a closed polysurface" "Loft through three circles, the middle one rotated a quarter turn and reversed and the last one rotated 200 degrees: reverses one curve, moves two seams, caps the ends into a closed polysurface"
kwcheck "Volume = 433" "...whose volume is the exact 10 pi * 13.8 = 433.5 (before: a mesh of volume 165.6)"
kwcount "3 faces, 3 edges, closed solid" 4 "the three capped lofts (three circles, the radius-5-to-3 frustum, two squares) are real closed-solid polysurfaces with one planar trimmed face per end (wall + 2 caps, 3 edges: two cap circles/loops and the seam), not meshes; the 4th match is the plain cylinder of the ChamferEdge section, which has the same topology"
kwcheck "! Loft: curve 2 is closed but curve 1 is open - a loft needs all open or all closed curves (an open and a closed curve have no point-for-point correspondence)" "Loft of a line and a circle is refused with the reason printed (and creates nothing: expect_objects 2 above)"
kwcheck "Loft: exact interpolating kernel loft through 2 curves (degree 1 in the loft direction); every section reproduced, max deviation [0-9.]*${KWTINY%\$}; uncapped (Cap=No)" "Loft Style=Straight Cap=No between two circles is degree 1 in the loft direction and uncapped"
kwcheck "Area = 25[0-9]" "...a surface with the exact frustum lateral area pi (5+3) sqrt(104) = 256.3"
kwcheck "Volume = 51[0-9]" "...and capped (Cap=Yes) it is the exact frustum solid pi 10/3 (25+15+9) = 513.2"
kwcheck "Loft: exact kernel loft not used (dino8::kernel::Brep::Loft: every section coincides with every other one - nothing to loft); using the older control-point fit instead" "Loft of two coincident circles: the kernel refuses, the reason is printed, the older control-point fit is kept as the fail-open path"
kwcheck "Area = 600 square" "Loft Style=Straight between two squares (second starting at a different corner) is the exact capped box: lateral + cap area 600"
kwcount "Loft: exact interpolating kernel loft through 3 curves (degree 2 in the loft direction); every section reproduced, max deviation [0-9.]*$KWTINY" 3 "Loft with History On: built once, re-lofted automatically when the middle line moved (no UpdateHistory call), and re-lofted again by the explicit UpdateHistory (three kernel lofts)"
kwcheck "Closest point 5,7,5 distance 0" "...and after the middle line moves +2 in y, UpdateHistory's re-loft passes through (5,7,5)"
kwcheck "Area = 114.8 square" "SubDLoft through three lines still builds the control-point-fit NURBS surface, now laid out correctly (area 114.8; before: a ribbon of area 6.7)"
kwcheck "140 faces, 210 edges, 72 vertices, 0 creases" "SubDLoft through three circles still builds a SubD"
kwcheck "through 4 curves (degree 3 in the loft direction); every section reproduced, max deviation [0-9.]*e-\(0[6-9]\|[1-9][0-9]\)$" "Loft through four lines is cubic in the loft direction and reproduces every section"
kwdist "through 4 curves .degree 3 in the loft direction." 1 0 3 0 0.000001 "...and the middle points of the three non-trivial lines lie on the surface to < 1e-6"

# SubD parity (app_subd_mesh): ToNURBS closes a SubD into a watertight solid,
# ToSubD verifies a smooth Brep and creases feature edges, SubD booleans work
# on the operands' limit surfaces with a creased cut, and SubD symmetry
# (radial / two-plane / welded live copy / crease-preserving Reflect) - all
# measured through the real app (see subd_parity_script.txt).
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SPAR="$(timeout 900 "$BIN" --smoke 300 --script "$HERE/subd_parity_script.txt" 2>&1)" || { echo "$SPAR"; echo "FAIL: subd parity script exited non-zero"; exit 1; }
else
  SPAR="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 300 --script "$HERE/subd_parity_script.txt" 2>&1)" || { echo "$SPAR"; echo "FAIL: subd parity script exited non-zero"; exit 1; }
fi
sparcheck() { if grep -q -- "$1" <<<"$SPAR"; then echo "ok   $2"; else echo "FAIL $2"; near "$SPAR" "$1"; fail=1; fi; }
# (1) ToNURBS: closed SubD -> closed polysurface (was: 240 faces, open, Volume refused)
sparcheck "ToNURBS: watertight conversion of a 6-face SubD (3 Catmull-Clark refinement round(s) first): 384 bicubic patches (360 exact limit patches, 24 Coons patches on the shared edge curves; 744 exact + 24 Hermite edge curves), joined 768 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes, manifold; max distance of 3456 patch samples from the Subdivide(+2) limit reference 0\.00[0-9]*" "ToNURBS turns SubDBox into 384 bicubic patches (360 exact + 24 Coons) joined at 1e-6 into a closed manifold solid with 0 naked edges, within 0.01 of the limit surface"
sparcheck "384 faces, 1536 edges, closed solid" "the ToNURBS result of SubDBox lists as a closed solid (before: 240 faces, open)"
sparcheck "ToNURBS: watertight conversion of a 48-face SubD (3 Catmull-Clark refinement round(s) first): 2304 bicubic patches (2016 exact limit patches, 288 Coons patches on the shared edge curves; 4320 exact + 288 Hermite edge curves), joined 4608 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes, manifold" "ToNURBS closes the triangulated-cage SubD sphere (almost every vertex extraordinary) into a closed manifold solid with 0 naked edges (before: 2304 faces, open)"
sparcheck "2304 faces, 9216 edges, closed solid" "the ToNURBS result of the SubD sphere lists as a closed solid"
sparcheck "384 bicubic patches (312 exact limit patches, 72 Coons patches on the shared edge curves; 696 exact + 72 Hermite edge curves), joined 768 edge pair(s) at 1e-6, 0 naked edge(s) left, closed solid: yes" "ToNURBS of a box with 4 creased edges is also a closed solid (crease chains are shared exact cubic B-spline curves: 696 exact edge curves)"
# (2) Brep -> SubD
sparcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); cage interpolated onto the Brep surface (limit surface passes through every cage vertex: [0-9]* iteration(s), residual 0\.0000[0-9]*), 0 feature edge(s) creased" "ToSubD on a Brep sphere VERIFIES: measured limit-surface deviation < 0.001 (before: 0 of 1 verified, 0.0202) with the cage interpolated onto the surface"
sparcheck "18240 faces, 27360 edges, 9122 vertices, 0 creases" "the verified sphere SubD is the 96 x 96 grid cage (Euler 9122 - 27360 + 18240 = 2)"
sparcheck "512 feature edge(s) creased" "ToSubD on a cylinder creases its 512 rim edges (two 256-segment circles) instead of rounding them off"
sparcheck "11894 faces, 17841 edges, 5949 vertices, 512 creases" "the cylinder SubD carries the 512 rim creases (before: 0 creases)"
sparcheck "ToSubD: created 1 object(s) (0 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.02[0-9]*)" "the cylinder (trimmed planar caps the grid tessellation cannot weld) still falls back to the mesher cage and honestly reports it is NOT verified (0.02x)"
# (3) SubD booleans on the limit surfaces
sparcheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), 815 face(s), 158 crease edge(s) (158 on the cut seam, 0 along operand creases, 0 sharp-angle); cage interpolated onto the Boolean surface" "BooleanUnion of two overlapping SubD boxes: 815 faces, the 158 edges of the cut seam are creases"
sparcheck "BooleanDifference: SubD boolean (operands refined to their limit surfaces, seam creased), 640 face(s), 160 crease edge(s) (160 on the cut seam" "BooleanDifference: 640 faces, 160 seam creases"
sparcheck "BooleanIntersection: SubD boolean (operands refined to their limit surfaces, seam creased), 462 face(s), 159 crease edge(s) (159 on the cut seam" "BooleanIntersection: 462 faces, 159 seam creases"
sparcheck "BooleanUnion: SubD boolean (operands refined to their limit surfaces, seam creased), [0-9]* face(s), 64 crease edge(s) (0 on the cut seam, 64 along operand creases" "a creased operand's 8 crease edges survive the union (64 crease edges along operand creases after 3 refinement rounds)"
sparcheck "Crease edges: 158" "the union SubD reports its 158 crease edges in What"
# volumes in script order: ToNURBS x3, ToSubD x2, union, difference, intersection, Reflect, Weld=No
mapfile -t SPAR_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SPAR" | awk '{print $3}')
if [ "${#SPAR_VOLS[@]}" -ge 10 ]; then
  echo "ok   subd parity script printed ${#SPAR_VOLS[@]} volumes"
  # The two boxes are translates of each other, so |A union B| = |A-B| + |A intersect B| + |B-A| = 2|A-B| + |A intersect B|.
  SPAR_RES="$(awk -v u="${SPAR_VOLS[5]}" -v d="${SPAR_VOLS[6]}" -v i="${SPAR_VOLS[7]}" 'BEGIN{r=u-(2*d+i); if(r<0) r=-r; printf "%.4f", r}')"
  if awk -v r="$SPAR_RES" 'BEGIN{exit !(r<0.05)}'; then echo "ok   SubD booleans are mutually consistent: union ${SPAR_VOLS[5]} = 2 x difference ${SPAR_VOLS[6]} + intersection ${SPAR_VOLS[7]} (residual $SPAR_RES < 0.05)"; else echo "FAIL SubD boolean volumes inconsistent: union ${SPAR_VOLS[5]}, difference ${SPAR_VOLS[6]}, intersection ${SPAR_VOLS[7]} (residual $SPAR_RES)"; fail=1; fi
  if awk -v a="${SPAR_VOLS[0]}" 'BEGIN{exit !(a>300 && a<340)}'; then echo "ok   ToNURBS SubDBox volume ${SPAR_VOLS[0]} (a smooth cube blob, in 300..340)"; else echo "FAIL ToNURBS SubDBox volume ${SPAR_VOLS[0]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[3]}" 'BEGIN{exit !(a>523 && a<525)}'; then echo "ok   verified sphere SubD encloses ${SPAR_VOLS[3]} (true sphere 523.6)"; else echo "FAIL sphere SubD volume ${SPAR_VOLS[3]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[8]}" 'BEGIN{exit !(a>1999 && a<2001)}'; then echo "ok   Reflect of a closed SubD box across its far face has volume ${SPAR_VOLS[8]} (two boxes, one body)"; else echo "FAIL Reflect volume ${SPAR_VOLS[8]}"; fail=1; fi
  if awk -v a="${SPAR_VOLS[9]}" 'BEGIN{exit !(a>999 && a<1001)}'; then echo "ok   Symmetry Weld=No mirror copy has positive volume ${SPAR_VOLS[9]} (outward winding)"; else echo "FAIL Weld=No mirrored copy volume ${SPAR_VOLS[9]}"; fail=1; fi
else
  echo "FAIL subd parity script printed only ${#SPAR_VOLS[@]} volumes (expected 10)"; fail=1
fi
# (4) symmetry
sparcheck "Symmetry: 1 live radial copy created (1 welded into one SubD with creases kept \[128 faces, 32 crease edges\])" "Symmetry Mode=Radial Count=4 welds a 32-face triangulated sector into one 128-face SubD"
sparcheck "Bounding box: (290, -10, 0) to (310, 10, 0)" "the radial SubD spans the full 20 x 20 about the axis through (300, 0)"
sparcheck "Symmetry: 1 live two-plane copy created (1 welded into one SubD with creases kept \[128 faces, 32 crease edges\])" "Symmetry Mode=TwoPlane mirrors the sector across two perpendicular planes into one 128-face SubD"
sparcheck "Bounding box: (390, -10, 0) to (410, 10, 0)" "the two-plane SubD spans the full 20 x 20"
sparcheck "Reflect: mirrored across the plane through 510,0,0 and welded original . mirror image into one symmetric SubD (10 faces)" "Reflect of a closed SubD box across its own far-face plane drops the shared wall: 10 faces"
sparcheck "10 faces, 20 edges, 12 vertices, 0 creases" "the reflected box is one closed body (Euler 12 - 20 + 10 = 2)"
sparcheck "Crease edges: 8" "Reflect mirrors the 4 creased edges of the source onto the other half (4 + 4 = 8 crease edges)"
sparcheck "Symmetry: 1 live mirrored copy created (1 welded into one SubD with creases kept \[64 faces, 32 crease edges\])" "Symmetry on a SubD plane welds source + mirror into one 64-face SubD by default"
sparcheck "Bounding box: (785, 0, 0) to (815, 10, 0)" "the live symmetric copy first spans the source plus its mirror about x = 800"
sparcheck "Bounding box: (775, 0, 0) to (825, 10, 0)" "after the source is MOVED +10 the live symmetric copy re-derived itself and now spans (775 .. 825) - a live link, rebuilt from the changed cage"
sparcheck "Bounding box: (730.608[0-9]*, 0.60763[0-9]*, 0.60763[0-9]*) to (739.39[0-9]*, 9.3923[0-9]*, 9.3923[0-9]*)" "Symmetry Weld=No gives a separate mirror copy on the other side of the plane (x 730.6 .. 739.4)"
sparcheck "gl_error=0" "subd parity script ran without OpenGL errors"
sparcheck "smoke: frames=[0-9]* objects=24" "subd parity script produced the expected object count"

# ---------------------------------------------------------------------------
# SX: exact curved-solid QC (solidsx_script.txt) - the audit/closure of the
# "Solid editing with B-rep results (booleans, fillet, shell, offset)" bullet:
# Boolean of curved solids (General engine, sewn closed and cross-checked
# against the mesh boolean), exact Shell/OffsetSrf/Pipe(closed rail) and the
# exact torus fillet of a plain cylinder's rim. Every case is bracketed by an
# SXBEGIN_<name> marker; sxblock slices the app output into that case.
# Volumes are read from the display mesh (chord 0.005), so the ranges below
# carry that tessellation error (up to ~1% on a torus, ~3% on a thin pipe).
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SXOUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/solidsx_script.txt" 2>&1)" || { echo "$SXOUT"; echo "FAIL: solidsx script exited non-zero"; exit 1; }
else
  SXOUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/solidsx_script.txt" 2>&1)" || { echo "$SXOUT"; echo "FAIL: solidsx script exited non-zero"; exit 1; }
fi
sxblock() { awk -v name="$1" '$0 ~ ("Unknown command: SXBEGIN_" name "$") { on = 1; next } on && /Unknown command: SXBEGIN_|Unknown command: SXEND/ { exit } on { print }' <<<"$SXOUT"; }
sxcheck() { local blk; blk="$(sxblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Boolean|Shell|Offset|Pipe|FilletEdge|Object|  [0-9]|Volume|!)" <<<"$blk" | head -8 | sed 's/^/     actual:   /'; fail=1; fi; }
# sxvol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
sxvol() {
  local blk v; blk="$(sxblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/')"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- Booleans of curved solids: exact, sewn closed, volume = closed form
sxcheck B_box_minus_cyl "BooleanDifference: exact B-rep boolean (no tessellation, general engine), 7 face(s), sewn into a closed solid" "box minus a through-hole cylinder is the General engine's result sewn into a closed solid (before: an 'open' polysurface that Volume refused)"
sxcheck B_box_minus_cyl "(polysurface)" "...and stays a polysurface (not a mesh)"
sxcheck B_box_minus_cyl "faces, [0-9]* edges, closed solid" "...List reports it as a closed solid (before: 188 edges, open)"
sxvol B_box_minus_cyl 873.5 875.5 "box minus a through-hole cylinder: Volume = 1000 - pi*2^2*10 = 874.34 (before: 'Object 3 is not closed', Volume 0)"
sxcheck B_box_minus_cyl "mesh cross-check" "...every accepted exact result prints its independent mesh-boolean cross-check volume"
sxcheck B_box_minus_cyl "Area = " "...and Area works on it"
sxcheck B_box_minus_blind "8 face(s), sewn into a closed solid" "blind hole: exact, closed"
sxvol B_box_minus_blind 936.2 938.2 "blind hole Volume = 1000 - pi*4*5 = 937.17"
sxcheck B_box_plus_boss "BooleanUnion: exact B-rep boolean (no tessellation, general engine), 8 face(s), sewn into a closed solid" "boss: exact, closed"
sxvol B_box_plus_boss 1139.5 1143 "cylindrical boss Volume = 1000 + pi*9*5 = 1141.37"
sxcheck B_tube "4 face(s), sewn into a closed solid" "tube (cylinder minus coaxial cylinder): exact, closed"
sxvol B_tube 656 662 "tube Volume = pi*(25-4)*10 = 659.73"
sxcheck B_cyl_stack "5 face(s), sewn into a closed solid" "stacked cylinders union: exact, closed"
sxvol B_cyl_stack 343 347.5 "stacked cylinders Volume = pi*9*10 + pi*4*5 = 345.58"
sxcheck B_cyl_minus_sphere "4 face(s), sewn into a closed solid" "cylinder minus a dome-cutting sphere: exact, closed"
sxvol B_cyl_minus_sphere 649 653.5 "dome cut Volume = 250*pi - 2/3*pi*64 = 651.36"
sxcheck B_two_holes_at_once "8 face(s), sewn into a closed solid" "two holes cut in one Boolean (cutters selected together): exact, closed"
sxvol B_two_holes_at_once 857.5 860.5 "two holes Volume = 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_small "closed solid" "the same hole at 1/10 size is still exact and closed"
sxvol B_scale_small 0.870 0.880 "1/10-size hole Volume = 1 - pi*0.04*1 = 0.8743"
# --- Declined with a reason; the result is a closed mesh (never an open polysurface)
sxcheck B_sphere_plus_box "exact B-rep boolean declined (the sewn result does not tessellate to a closed mesh); using the mesh boolean, so the result is a mesh" "box + sphere: declined WITH the reason (the sphere's pole does not weld watertight), mesh boolean used"
sxcheck B_sphere_plus_box "(mesh)" "...and the result is a mesh"
sxvol B_sphere_plus_box 1130 1136 "box + sphere mesh result is a closed solid with Volume = 1000 + 2/3*pi*64 = 1134.04"
sxcheck B_cyl_offaxis "exact B-rep boolean declined (dino8::kernel::BooleanCombineGeneral: an edge is claimed by 3 or more fragment loops" "off-axis cylinder union: the engine's own refusal is printed as the reason"
sxcheck B_chain "exact B-rep boolean declined (the engine's result has gaps between faces that sewing could not close" "a second SEQUENTIAL hole in an already-sewn result is declined with the reason (cut both holes in one Boolean, above, to stay exact)"
sxvol B_chain 857 861 "...and the mesh fallback still gives the right volume 1000 - 2*pi*1.5^2*10 = 858.62"
sxcheck B_scale_large "exact B-rep boolean declined" "100x-size hole: declined with a reason (the engine's absolute 1e-3 refinement leaves gaps the closed-mesh check rejects)"
sxcheck B_far_from_origin "exact B-rep boolean declined" "a hole 100000 units from the origin: declined with a reason"
sxcheck B_meshalias "MeshBooleanDifference: [0-9]* faces, volume" "old behaviour stays reachable: MeshBooleanDifference always returns the mesh"
sxcheck B_then_shell "Shell: thickness 0.5, closed, volume" "Shell of the sewn Boolean result now works (before: 'Object 3 is not a closed solid; skipped')"
sxcheck B_then_shell "exact B-rep shell not used (" "...and says why that shell is a mesh (a curved face has no exact kernel shell)"
# --- Shell
sxcheck S_box_closed "Shell: thickness 1, closed, exact B-rep, volume 488" "control: closed box shell is exact (1000 - 8^3)"
sxcheck S_box_open "Shell: thickness 1, open (1 face(s) removed), exact B-rep, volume 424" "box with the top face removed is now an exact B-rep (kernel ShellConvexPlanar with removed_faces; before: a mesh)"
sxcheck S_box_open "(polysurface)" "...a polysurface"
sxcheck S_box_open "14 faces, 28 edges, closed solid" "...14 faces (5 outer + 5 inner + 4 rim) and 28 edges, a closed solid"
sxcheck S_box_perface "1 face(s) at their own thickness, closed, exact B-rep, volume 616" "per-face thickness (top 3, others 1) is exact: 1000 - 8*8*6 = 616 (before: a mesh)"
sxcheck S_box_exactno "Shell: thickness 1, closed, volume 488" "old behaviour reachable: Exact=No gives the mesh construction"
sxcheck S_box_exactno "(mesh)" "...a mesh"
sxcheck S_sphere "Shell: thickness 1, closed, exact B-rep" "whole sphere shell is exact (concentric reversed inner sphere)"
sxcheck S_sphere "2 faces, 2 edges, closed solid" "...2 faces, closed solid"
sxvol S_sphere 253.5 256.5 "sphere shell Volume = 4/3*pi*(125-64) = 255.5"
sxcheck S_torus "Shell: thickness 1, closed, exact B-rep" "whole torus shell is exact"
sxvol S_torus 970 990 "torus shell Volume = 2*pi^2*10*(9-4) = 986.96 (display mesh reads low on a torus)"
sxcheck S_cyl_closed "Shell: thickness 1, closed, exact B-rep" "plain cylinder closed hollow shell is exact (before: a 14208-triangle mesh)"
sxcheck S_cyl_closed "6 faces, 6 edges, closed solid" "...6 faces (outer 3 + inner 3), closed solid"
sxvol S_cyl_closed 381 385 "hollow cylinder Volume = pi*(250-128) = 383.27"
sxcheck S_cyl_open "open (1 face(s) removed), exact B-rep" "cylinder with the top cap removed is an exact cup (before: a mesh)"
sxcheck S_cyl_open "5 faces, 9 edges, closed solid" "...5 faces (outer wall, base disc, inner wall, floor, rim annulus), closed solid"
sxvol S_cyl_open 331 335 "cup Volume = pi*(250-16*9) = 333.01"
sxcheck S_cyl_open_bottom "open (1 face(s) removed), exact B-rep" "removing the bottom cap works too"
sxcheck S_L_nonconvex "exact B-rep shell not used (" "non-convex L-shaped extrusion: no exact shell, reason printed, mesh construction kept"
# --- OffsetSrf
sxcheck O_sphere "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "sphere offset is exact (before: a 4700-triangle mesh)"
sxcheck O_sphere "1 faces, 1 edges, closed solid" "...one closed spherical face"
sxvol O_sphere 902 906 "offset sphere Volume = 4/3*pi*216 = 904.78"
sxcheck O_torus "1 exact B-rep" "torus offset is exact"
sxvol O_torus 3110 3170 "offset torus Volume = 2*pi^2*10*16 = 3158.3 (display mesh)"
sxcheck O_cyl "3 faces, 3 edges, closed solid" "plain cylinder offset is an exact 3-face cylinder"
sxvol O_cyl 1353 1359 "offset cylinder Volume = pi*36*12 = 1357.17"
sxcheck O_box_solid "OffsetSrf: distance 1, 1 object(s), solid, 1 exact B-rep" "Solid=Yes on a box is exact (before: a mesh)"
sxcheck O_box_solid "(polysurface)" "...a polysurface"
sxvol O_box_solid 727.5 728.5 "box Solid=Yes Volume = 12^3 - 10^3 = 728"
sxcheck O_sphere_solid "solid, 1 exact B-rep" "sphere Solid=Yes is exact"
sxvol O_sphere_solid 379 383 "sphere Solid=Yes Volume = 4/3*pi*(216-125) = 381.2"
sxcheck O_sphere_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
sxcheck O_L_nonconvex "exact B-rep offset not used (" "non-convex L extrusion: no exact offset, reason printed"
# --- Pipe on a closed rail
sxcheck P_closed "Pipe: radius 1, 1 pipe(s) (exact closed B-rep tube)" "Pipe on a closed circular rail is the kernel's exact closed tube (before: a 1152-triangle mesh)"
sxcheck P_closed "(polysurface)" "...a polysurface"
sxcheck P_closed "closed solid" "...a closed solid"
sxvol P_closed 186 200 "closed-rail pipe Volume ~ 2*pi^2*10*1 = 197.39 (display mesh; the Torus primitive reads 191.2 under the same mesher)"
# --- Fillet of a plain cylinder's rim
sxcheck F_cyl_top "cylinder rim(s) of object 1 replaced with an exact fillet (top radius 1; exact quarter-torus patch, 4 faces, closed solid)" "cylinder top-rim fillet is an exact quarter torus (before: a mesh whose volume INCREASED to 1594)"
sxcheck F_cyl_top "4 faces, 7 edges, closed solid" "...4 faces (wall, torus, 2 discs) and 7 edges, closed solid"
sxvol F_cyl_top 1561 1566 "top-rim fillet Volume = 25*pi*20 - 6.44 = 1564.36 (before 1594)"
sxcheck F_cyl_both "top radius 1, bottom radius 2; exact quarter-torus patches, 5 faces, closed solid" "both rims in one run become one exact solid"
sxvol F_cyl_both 1536 1542 "both-rim fillet Volume = 1539.80"
sxvol F_cyl_bottom 1543 1549 "bottom-rim fillet (radius 2) Volume = 1546.24"
sxcheck F_cyl_exactno "mesh fallback (exact B-rep trim unavailable here" "old behaviour reachable: Exact=No keeps the approximate mesh fillet"
sxcheck F_cyl_toobig "exact cylinder-rim fillet not used (the radius is not smaller than the cylinder radius)" "a radius larger than the cylinder: exact refused with the reason, fallback runs"
sxcheck F_box_control "FilletEdge: edge 10 of object 1 replaced with an exact fillet" "control: a box edge is still the kernel's exact planar fillet"
sxvol F_box_control 990.5 992.3 "box edge fillet Volume = 991.4"
if grep -q "^FAIL" <<<"$SXOUT"; then echo "FAIL solidsx script reported an in-script FAIL"; fail=1; fi

# ---------------------------------------------------------------------------
# Viewport display: per-object display modes + view-dependent adaptive
# tessellation (PARITY_MAP.md "Viewport display, rendering & visualization":
# "Per-object display mode override" and "View-dependent adaptive
# tessellation"). tests/viewport_lod_script.txt runs both against the real
# app: part 1 zooms one sphere through several levels and reads back what
# each viewport's last frame drew (LodStats); part 2 cycles one box through
# every per-object mode in Rendered/Shaded/Wireframe viewports and captures
# bitmaps, then queries (ObjectDisplayModes) and round-trips through .3dm.
# ---------------------------------------------------------------------------
mkdir -p "$TMPW/vpl"
sed "s|@TMP@|$TMPW/vpl|g" "$HERE/viewport_lod_script.txt" > "$TMPW/viewport_lod_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  VPL="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/viewport_lod_script.txt" 2>&1)" || { echo "$VPL"; echo "FAIL: viewport_lod script exited non-zero"; exit 1; }
else
  VPL="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/viewport_lod_script.txt" 2>&1)" || { echo "$VPL"; echo "FAIL: viewport_lod script exited non-zero"; exit 1; }
fi
vplcheck() { if grep -q "$1" <<<"$VPL"; then echo "ok   $2"; else echo "FAIL $2"; near "$VPL" "$1"; fail=1; fi; }
# vplval SECTION VIEWPORT FIELD: FIELD of the "LodStats: viewport VIEWPORT object" line in the SECTION-th LodStats call.
vplval() {
  awk -v n="$1" -v v="$2" -v f="$3" '
    /LodStats: adaptive=/ { k++ }
    k == n && index($0, "LodStats: viewport " v " object ") { if (match($0, f "=[-0-9.e+]+")) { s = substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); print s; exit } }' <<<"$VPL"
}
# vplhdr SECTION FIELD: FIELD of the SECTION-th "LodStats: adaptive=" header line.
vplhdr() {
  awk -v n="$1" -v f="$2" '
    /LodStats: adaptive=/ { k++; if (k == n) { if (match($0, f "=[a-z0-9]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPL"
}
vplnum() { # DESC EXPR : EXPR is an awk expression over already-substituted numbers
  local r; r="$(awk "BEGIN { print ($2) ? \"yes\" : \"no\" }")"
  if [ "$r" = yes ]; then echo "ok   $1"; else echo "FAIL $1 [$2]"; fail=1; fi
}
vplcheck "^ok   expect_objects 2" "viewport_lod script left exactly the two boxes"
vplcheck "gl_error=0" "viewport_lod script ran without OpenGL errors"
VP_P0="$(vplval 1 Perspective tris)"; VP_P3="$(vplval 2 Perspective tris)"; VP_P9="$(vplval 3 Perspective tris)"; VP_PB="$(vplval 4 Perspective tris)"
VP_T0="$(vplval 1 Top tris)"; VP_T3="$(vplval 2 Top tris)"; VP_T9="$(vplval 3 Top tris)"
echo "     Perspective triangles at zoom 0 / 3 / 9 / back to 3 steps: $VP_P0 / $VP_P3 / $VP_P9 / $VP_PB;  Top (never zoomed): $VP_T0 / $VP_T3 / $VP_T9"
vplnum "zooming the Perspective viewport in 3 steps re-tessellates the sphere finer (more triangles than at zoom 0)" "$VP_P3 > $VP_P0"
vplnum "...and 9 steps in is denser still, more than 3x the zoom-0 triangle count" "$VP_P9 > 3 * $VP_P0 && $VP_P9 > $VP_P3"
vplnum "the Top viewport, never zoomed, keeps its own level through all of it (each viewport has its OWN LOD, not one shared finest value)" "$VP_T0 == $VP_T3 && $VP_T3 == $VP_T9 && $VP_T0 < $VP_P9"
vplnum "zooming back out to the 3-step zoom restores exactly that zoom's mesh (same triangle count as before)" "$VP_PB == $VP_P3"
VP_E0="$(vplval 1 Perspective nominal_err_px)"; VP_E9="$(vplval 3 Perspective nominal_err_px)"
echo "     NOMINAL on-screen chord error (tolerance / pixel size; the mesher really leaves ~2.1x this, see test_adaptive_display) Perspective: $VP_E0 px at zoom 0, $VP_E9 px at zoom 9"
vplnum "the screen-space error stays ~0.5 px even 9 zoom steps in (past the old 0.2x clamp, where it grew to ~1.8 px and beyond)" "$VP_E9 < 0.6 && $VP_E9 > 0.4"
vplnum "9 zoom steps in is past the OLD clamp (lod_scale < 0.2) yet the scale still keeps refining" "$(vplval 3 Perspective surface_tol) < 0.05 * 0.2 * 0.9"
vplnum "the multi-level cache swapped levels instead of re-tessellating every time: stash_hits counter > 0" "$(vplhdr 6 stash_hits) > 0"
vplcheck "LodStats: object 1 polysurface stashed_levels=[1-3] budget_floor=0$" "LodStats reports the stashed levels and no budget floor for a modest sphere"
vplcheck "LodStats: adaptive=off" "AdaptiveTessellation Off is reported by LodStats"
VP_OFF_TRIS="$(awk '/LodStats: adaptive=/ { k++ } k == 5 && /LodStats: viewport [A-Za-z]+ object / && match($0, /tris=[0-9]+/) { print substr($0, RSTART + 5, RLENGTH - 5) }' <<<"$VPL" | sort -u | tr '\n' ' ')"
echo "     adaptive OFF: distinct triangle counts across the four viewports: $VP_OFF_TRIS"
vplnum "adaptive OFF: all four viewports draw one identical fixed-tolerance mesh (a single distinct triangle count)" "$(wc -w <<<"$VP_OFF_TRIS") == 1"
vplnum "adaptive OFF: the tolerances are exactly the Options values (surface 0.05, curve 0.02)" "$(vplval 5 Perspective surface_tol) == 0.05 && $(vplval 5 Perspective curve_tol) == 0.02"
vplnum "adaptive ON again: Perspective (zoomed) is finer than the fixed-tolerance mesh it just had" "$(vplval 6 Perspective tris) > $(vplval 5 Perspective tris)"
vplnum "switching adaptive off does not itself count as a zoom-driven re-tessellation (rebuilds counter unchanged)" "$(vplhdr 5 rebuilds) == $(vplhdr 4 rebuilds)"

# Part 2: per-object modes, pixel level + query + .3dm round trip.
python3 - "$TMPW/vpl" <<'PY' && echo "ok   per-object display modes carry their FULL style: Wireframe stays visible in a Rendered viewport, Pen/Arctic/Technical/Artistic/Rendered each draw their own edge colour (and no wires for Rendered) over their own fill, Box A never changes" || { echo "FAIL per-object display mode pixel check"; fail=1; }
import struct, sys
d = sys.argv[1]
def read_bmp(name):
    b = open(f'{d}/{name}.bmp', 'rb').read()
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', b[2:30])
    assert hdr == 40 and planes == 1 and bpp == 24, (name, hdr, planes, bpp)
    row = (w * 3 + 3) & ~3
    px = b[off:]
    def get(x, y):
        r = h - 1 - y
        i = r * row + x * 3
        return px[i + 2], px[i + 1], px[i]
    return w, h, get
w, h, rb = read_bmp('r_base')
y = h // 2 + 40   # a row inside both boxes, off the X axis line
blue = [x for x in range(w) if rb(x, y)[2] > rb(x, y)[0] + 80]
bx0, bx1 = blue[0], blue[-1]; cx = (bx0 + bx1) // 2
red = [x for x in range(w) if rb(x, y)[0] > rb(x, y)[2] + 80 and rb(x, y)[0] > 150]
ax = (red[0] + red[-1]) // 2
def probe(name):
    _, _, g = read_bmp(name)
    return dict(edge=g(bx0, y), fill=g(cx, y), A=g(ax, y), out=g(bx0 - 3, y))
r_base, r_wire = probe('r_base'), probe('r_wire')
s = {n: probe(n) for n in ('s_base', 's_pen', 's_arctic', 's_technical', 's_artistic', 's_rendered')}
for k, v in list(s.items()) + [('r_base', r_base), ('r_wire', r_wire)]:
    print(f'{k:12s} edge={v["edge"]} fill={v["fill"]} A={v["A"]}')
# Box A (never overridden) is identical across captures of the same viewport mode.
assert r_wire['A'] == r_base['A'], 'Box A changed in the Rendered viewport'
for n, v in s.items(): assert v['A'] == s['s_base']['A'], f'Box A changed in {n}'
# Wireframe override in a RENDERED viewport (edges and isocurves both off there): used to vanish entirely.
assert r_wire['fill'] == r_wire['out'], 'Wireframe override still filled in a Rendered viewport'
assert r_wire['edge'] != r_wire['out'] and r_wire['edge'][2] > r_wire['edge'][0] + 80, f'Wireframe override has no visible blue outline in a Rendered viewport: {r_wire}'
# Pen: black edge, unlit flat white fill.   Arctic: grey (150) edge, lit white fill.
assert s['s_pen']['edge'] == (0, 0, 0) and s['s_pen']['fill'] == (245, 245, 245), s['s_pen']
assert s['s_arctic']['edge'] == (150, 150, 150) and all(c < 245 and c > 200 for c in s['s_arctic']['fill']), s['s_arctic']
# Technical vs Artistic: same lit flat grey fill, different line work.
assert s['s_technical']['edge'] == (20, 20, 20), s['s_technical']
assert s['s_artistic']['edge'] == (60, 50, 40), s['s_artistic']
assert s['s_technical']['fill'] == s['s_artistic']['fill'] and abs(s['s_technical']['fill'][0] - s['s_technical']['fill'][2]) < 12, 'Technical/Artistic fills differ or are not grey'
assert s['s_technical']['fill'] != s['s_base']['fill'], 'Technical fill equals the plain blue object fill'
# Rendered override in a Shaded viewport: no wires at all (edge == fill == the Rendered look), unlike Shaded's darker outline.
assert s['s_rendered']['edge'] == s['s_rendered']['fill'] == r_base['fill'], s['s_rendered']
assert s['s_base']['edge'] != s['s_base']['fill'], 'plain Shaded object lost its outline'
PY
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Rendered" "ObjectDisplayModes reports the Rendered override by name"
vplcheck "ObjectDisplayModes: 1 of 2 object(s) carry a per-object display mode Rendered=1" "...and the per-mode tally"
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Technical" "ObjectDisplayModes reports Technical (a mode that used to be refused)"
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = UseViewport" "ObjectDisplayModes All also lists the objects that follow the viewport"
# RayTraced used to be refused here ("a whole-frame path-traced image"); it is now a real per-object mode
# (tests/viewport_close_script.txt, section "viewport close" at the end of this file proves it on pixels).
if grep -q "RayTraced is a whole-frame path-traced image" <<<"$VPL"; then echo "FAIL the old RayTraced per-object refusal is still printed"; fail=1; else echo "ok   RayTraced is no longer refused as a per-object display mode"; fi
vplcheck "SetObjectDisplayMode: unknown mode 'Bogus' - nothing changed" "an unknown mode name is refused and changes nothing"
VP_QT="$(grep -c 'ObjectDisplayModes: 1 of 2 object(s) carry a per-object display mode Technical=1' <<<"$VPL")"
vplnum "Technical survives the refused RayTraced/Bogus attempts and a Save/New/Open round trip through .3dm (query shows it 4 times: before, All, after RayTraced, after reopen)" "$VP_QT == 4"
VP_TV="$(grep -c 'ObjectDisplayModes: object [0-9]* polysurface = Technical (viewport [A-Za-z]*)' <<<"$VPL")"
vplnum "SetObjectDisplayMode defaults to the ACTIVE viewport only (Rhino's scope): every Technical query line carries '(viewport NAME)', and it survives the .3dm round trip (4 lines)" "$VP_TV == 4"

# Part 3: scope, pixel level. Pen pinned to Top only must leave Front untouched (byte-identical bitmap); Pen All reaches Front too.
python3 - "$TMPW/vpl" <<'PY' && echo "ok   per-VIEWPORT scope: Pen set in Top changes Top but leaves Front's whole bitmap byte-identical; 'Pen All' then changes Front too, and Top keeps it" || { echo "FAIL per-viewport scope pixel check"; fail=1; }
import struct, sys
d = sys.argv[1]
def load(name):
    b = open(f'{d}/{name}.bmp', 'rb').read()
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', b[2:30])
    row = (w * 3 + 3) & ~3
    px = b[off:]
    def get(x, y):
        r = h - 1 - y
        i = r * row + x * 3
        return px[i + 2], px[i + 1], px[i]
    return w, h, px, get
def diff_centre(a, b):
    w, h, pa, ga = a; _, _, pb, gb = b
    pts = [(x, y) for y in range(h) for x in range(w) if sum(abs(p - q) for p, q in zip(ga(x, y), gb(x, y))) > 15]
    assert pts, 'captures do not differ'
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return (min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2
t_base, t_pen, t_all = load('t_base'), load('t_pen'), load('t_all')
f_base, f_scoped, f_all = load('f_base'), load('f_scoped'), load('f_all')
cx, cy = diff_centre(t_base, t_pen)
print('Top: B centre', (cx, cy), 'base', t_base[3](cx, cy), 'pen', t_pen[3](cx, cy), 'after Pen All', t_all[3](cx, cy))
assert t_pen[3](cx, cy) == (245, 245, 245), 'Pen not applied in Top'
assert t_base[3](cx, cy) != (245, 245, 245)
assert f_base[2] == f_scoped[2], 'Front changed although Pen was pinned to Top only'
fx, fy = diff_centre(f_base, f_all)
print('Front: B centre', (fx, fy), 'base', f_base[3](fx, fy), 'scoped', f_scoped[3](fx, fy), 'Pen All', f_all[3](fx, fy))
assert f_all[3](fx, fy) == (245, 245, 245), 'Pen All did not reach Front'
assert f_scoped[3](fx, fy) == f_base[3](fx, fy)
assert t_all[3](cx, cy) == (245, 245, 245), 'Top lost Pen after Pen All'
PY
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Pen (viewport Top)" "a viewport-scoped override is listed with its viewport"
vplcheck "ObjectDisplayModes: object [0-9]* polysurface = Pen$" "Pen All is listed as an all-viewports override (no viewport suffix)"
vplcheck "ClearAllObjectDisplayModes: 1 object(s) reset to the viewport display mode" "ClearAllObjectDisplayModes (Rhino's command, extended to the display-mode overrides) removes them and reports how many objects"
vplcheck "ObjectDisplayModes: 0 of 2 object(s) carry a per-object display mode$" "...and the query then shows none"



# ---------------------------------------------------------------------------
# Named macro OBJECTS (cmd_macros.cpp, app/MacroLibrary.h) - PARITY_MAP.md's
# "VBA-style macro recorder and editor" item: a saved macro is a recorded,
# editable object with properties (name, description, tags, parameters,
# structured steps, created/modified), not ';'-separated text. Three real app
# processes against PRIVATE config directories (so the library starts empty
# and the persisted state is exactly what these scripts wrote):
#   A  macro_objects_script.txt          save/list/show/edit/run-with-args/
#                                        errors/prompt/duplicate/rename/delete/
#                                        export-import/binding/in-process reload
#   B  macro_objects_persist_script.txt  same config dir, NEW process: the
#                                        library, alias and toolbar button
#                                        survived the restart
#   C  macro_objects_migrate_script.txt  a settings.json from before macro
#                                        objects (macros map + macro_text)
#   D  the Macro Editor panel is opened and rendered (no crash); its widgets
#      cannot be driven headlessly - see the PARITY_MAP.md note.
mo_exec() {  # mo_exec <config home> <script>
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    XDG_CONFIG_HOME="$1" APPDATA="$1" timeout 900 "$BIN" --smoke 100 --script "$2" 2>&1
  else
    XDG_CONFIG_HOME="$1" APPDATA="$1" timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$2" 2>&1
  fi
}
mo_chk() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
mo_cnt() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$4" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $4)"; near "$1" "$2"; fail=1; fi; }
# The lines a command printed: everything after its exact "Command: ..." echo
# line up to the next "Command:" line; $3 picks the Nth occurrence.
mo_block() { sed "s/^history: //" <<<"$1" | awk -v n="$3" -v cmd="Command: $2" '$0==cmd{c++; on=(c==n); next} /^Command:/{on=0} on'; }
if [ "$IS_WINDOWS" = 1 ]; then MO_SETTINGS_SUB="Dino8"; else MO_SETTINGS_SUB="dino8"; fi
MO_DIR="$TMP/mo"; mkdir -p "$MO_DIR"
if command -v cygpath >/dev/null 2>&1; then MO_DIRW="$(cygpath -m "$MO_DIR")"; else MO_DIRW="$MO_DIR"; fi
printf '%s\n' '{"format": "something-else", "version": 1, "macros": []}' > "$MO_DIR/bad_format.json"
printf '%s\n' '{"format": "dino8-macro-library", "version": 99, "macros": []}' > "$MO_DIR/future.json"
printf '%s\n' 'this is { not json' > "$MO_DIR/garbage.json"
MO_CFG_A="$TMP/mo_cfg_a"; mkdir -p "$MO_CFG_A"
sed "s#@MODIR@#$MO_DIRW#g" "$HERE/macro_objects_script.txt" > "$TMPW/mo_a.txt"
sed "s#@MODIR@#$MO_DIRW#g" "$HERE/macro_objects_persist_script.txt" > "$TMPW/mo_b.txt"
sed "s#@MODIR@#$MO_DIRW#g" "$HERE/macro_objects_migrate_script.txt" > "$TMPW/mo_c.txt"
MO_A="$(mo_exec "$MO_CFG_A" "$TMPW/mo_a.txt")" || { echo "$MO_A"; echo "FAIL: macro-objects script A exited non-zero"; exit 1; }
grep -E "^(ok|FAIL)" <<<"$MO_A" || true
if grep -q "^FAIL" <<<"$MO_A"; then fail=1; fi
grep -q "^smoke:" <<<"$MO_A" || { echo "$MO_A"; echo "FAIL: macro-objects script A produced no smoke line"; fail=1; }

# -- SaveMacro from the recorder, then structured EditMacro ----------------
mo_chk "$MO_A" "Saved macro 'cube': 1 step(s), no parameters" "SaveMacro turns the recorder buffer (one recorded Box line) into a named macro object with one structured step"
mo_chk "$MO_A" "EditMacro 'cube': replaced step 1 (was: Box 0,0,0 2,2,0 2) with: Box 0,0,0 {size},{size},0 {size} (1 step(s)); new parameter(s): {size}" "EditMacro Replace 1 swaps the recorded numbers for {size} and auto-declares the parameter"
mo_chk "$MO_A" "EditMacro 'cube': inserted step 2: SelNone (4 step(s))" "EditMacro Insert 2 puts a new step at position 2 (the macro now has 4 steps)"
mo_chk "$MO_A" "EditMacro 'cube': deleted step 5 (was: ZoomExtents) (4 step(s))" "EditMacro Delete 5 removes exactly that step"
MO_SHOW1="$(mo_block "$MO_A" "ShowMacro cube" 1)"
mo_chk "$MO_SHOW1" "  Description: Draws a cube and reads its volume" "ShowMacro: the description given to SaveMacro"
mo_chk "$MO_SHOW1" "  Tags: geometry, demo" "ShowMacro: the tags given to SaveMacro"
mo_chk "$MO_SHOW1" "    {size}  required" "ShowMacro: {size} is a declared, required parameter"
mo_chk "$MO_SHOW1" "    1: Box 0,0,0 {size},{size},0 {size}" "ShowMacro: step 1 is the edited Box line with its placeholders"
mo_chk "$MO_SHOW1" "    2: SelNone" "ShowMacro: step 2 is the inserted SelNone"
mo_chk "$MO_SHOW1" "    4: Volume" "ShowMacro: step 4 is Volume (the deleted ZoomExtents is gone)"
mo_chk "$MO_A" "Macro library: 1 macro(s)" "ListMacros counts the library"
mo_chk "$MO_A" "  cube  [4 step(s); params {size}; tags geometry, demo]  Draws a cube and reads its volume" "ListMacros row: name, step count, parameters, tags, description"
MO_T_CREATED1="$(grep -F '  Created: ' <<<"$MO_SHOW1" | head -1 || true)"
if grep -Eq '^  Created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$' <<<"$MO_T_CREATED1"; then echo "ok   Created is an ISO-8601 UTC timestamp ($MO_T_CREATED1)"; else echo "FAIL Created is not an ISO-8601 timestamp: $MO_T_CREATED1"; fail=1; fi

# -- run with arguments: Volume reads size^3 -------------------------------
mo_chk "$MO_A" "RunMacro 'cube': running 4 step(s) with size=2" "RunMacro size=2 substitutes {size} in all steps"
mo_cnt "$MO_A" "Volume = 8 cubic" "RunMacro cube size=2 draws a 2-edge box whose Volume reads 2^3 = 8 (once here; again after the rename below)" 2
mo_cnt "$MO_A" "Volume = 125 cubic" "RunMacro cube size=5: Volume reads 5^3 = 125 (a different argument gives a different measured result; the second is the by-name-bound alias cube5 below)" 2
mo_cnt "$MO_A" "Volume = 27 cubic" "RunMacro cube with NO argument uses the parameter's default (3): Volume reads 3^3 = 27 (again for the bound alias after the macro is edited)" 2
mo_chk "$MO_A" "Volume = 64 cubic" "RunMacro cube 4 (bare value fills the next parameter): Volume reads 4^3 = 64"
mo_chk "$MO_A" "EditMacro 'cube': parameter {size}=3, prompt \"Edge length\"" "EditMacro Param sets a default and a prompt"
MO_SHOW2="$(mo_block "$MO_A" "ShowMacro cube" 2)"
mo_chk "$MO_SHOW2" "    {size}  default \"3\", prompt \"Edge length\"" "ShowMacro reflects the default and prompt"
MO_T_CREATED2="$(grep -F '  Created: ' <<<"$MO_SHOW2" | head -1 || true)"
MO_T_MOD1="$(grep -F '  Modified: ' <<<"$MO_SHOW1" | head -1 || true)"
MO_T_MOD2="$(grep -F '  Modified: ' <<<"$MO_SHOW2" | head -1 || true)"
if [ "$MO_T_CREATED1" = "$MO_T_CREATED2" ] && [[ "$MO_T_MOD2" > "$MO_T_MOD1" ]]; then echo "ok   an edit leaves Created alone and strictly advances Modified ($MO_T_MOD1 -> $MO_T_MOD2)"; else echo "FAIL Created/Modified did not behave: [$MO_T_CREATED1|$MO_T_CREATED2] [$MO_T_MOD1|$MO_T_MOD2]"; fail=1; fi

# -- bad calls change/run nothing -------------------------------------------
mo_chk "$MO_A" "RunMacro: macro 'cube' has no parameter 'bogus' (parameters: size)" "an unknown key=value is refused and names the real parameters"
mo_chk "$MO_A" "RunMacro: too many values for macro 'cube' (1 parameter(s): size)" "too many bare values are refused"
mo_chk "$MO_A" "RunMacro: no saved macro named 'nosuch'" "RunMacro of an unknown macro warns"
mo_chk "$MO_A" "EditMacro: step number 99 is out of range (macro 'cube' has 4 step(s); valid here: 1..4)" "Delete 99 is refused with the valid range"
mo_chk "$MO_A" "EditMacro: step number 9 is out of range (macro 'cube' has 4 step(s); valid here: 1..5)" "Insert 9 is refused (valid insert positions are 1..steps+1)"
mo_chk "$MO_A" "EditMacro: no macro named 'nosuch'" "EditMacro of an unknown macro warns"
mo_chk "$MO_A" "SaveMacro: a macro named 'cube' already exists" "SaveMacro will not silently replace an existing macro"
mo_chk "$MO_A" "Replaced the steps of macro 'spare': 1 step(s), no parameters" "SaveMacro Overwrite=Yes replaces the steps"
MO_SPARE="$(mo_block "$MO_A" "ShowMacro spare" 1)"
mo_chk "$MO_SPARE" "    1: SelNone" "...and the new step list is what ShowMacro reads back"

# -- a required parameter is prompted for -----------------------------------
mo_chk "$MO_A" "RunMacro 'tall': needs a value for {h}" "RunMacro with a required parameter and no value prompts for it"
mo_chk "$MO_A" "RunMacro 'tall': running 4 step(s) with h=7" "the value typed at the prompt (7) is substituted"
mo_chk "$MO_A" "Volume = 7 cubic" "...and the box it drew has Volume 1*1*7 = 7"
mo_chk "$MO_A" "RunMacro: cancelled - no value given for {h}; nothing was run" "Enter at the prompt cancels the run without running any step"
mo_chk "$MO_A" "Volume = 9 cubic" "RunMacro tall h=9 (no prompt) draws the 1*1*9 box: Volume 9"

# -- the recorder does not record what a macro runs ---------------------------
mo_chk "$MO_A" "  RunMacro cube size=11" "with the recorder On, the typed RunMacro line is recorded"
mo_cnt "$MO_A" "  Box 0,0,0 11,11,0 11" "...but the Box line the macro ran is NOT also recorded (0 lines in the buffer dump)" 0
mo_chk "$MO_A" "Volume = 1331 cubic" "...although the macro did run (11^3 = 1331)"

# -- duplicate / rename / delete ----------------------------------------------
mo_chk "$MO_A" "Duplicated macro 'cube' as 'cube2'" "DuplicateMacro copies a macro"
mo_chk "$MO_A" "Renamed macro 'cube2' to 'cube_b' (0 alias binding(s) updated)" "RenameMacro renames"
mo_chk "$MO_A" "RenameMacro: a macro named 'cube' already exists" "RenameMacro refuses a clashing name"
mo_chk "$MO_A" "RenameMacro: no macro named 'nosuch'" "RenameMacro of an unknown macro warns"
MO_SHOW_B="$(mo_block "$MO_A" "ShowMacro cube_b" 1)"
mo_chk "$MO_SHOW_B" "  Description: the copy" "the duplicate's own description was edited..."
mo_chk "$MO_SHOW_B" "    1: Box 0,0,0 {size},{size},0 {size}" "...and it carries the original's steps"
MO_SHOW3="$(mo_block "$MO_A" "ShowMacro cube" 3)"
mo_chk "$MO_SHOW3" "  Description: Draws a cube and reads its volume" "editing the copy did not change the original"
mo_chk "$MO_A" "Macro library: 1 macro(s) shown of" "ListMacros Tag=copy filters to the tagged macro"
mo_chk "$MO_A" "Deleted macro 'cube_b'" "DeleteMacro removes it"
mo_chk "$MO_A" "ShowMacro: no macro named 'cube_b'" "...and ShowMacro then warns"
mo_chk "$MO_A" "DeleteMacro: no macro named 'cube_b'" "deleting it twice warns"

# -- quotes and braces in steps -----------------------------------------------
MO_QUOTED="$(mo_block "$MO_A" "ShowMacro quoted" 1)"
mo_chk "$MO_QUOTED" '    2: Echo "hello"' '\q in EditMacro text is stored as a literal double quote'
mo_chk "$MO_QUOTED" "    3: = print('\\{lit}')" "\\{ keeps a brace literal"
mo_chk "$MO_QUOTED" "Parameters (0):" "...and an escaped brace is not mistaken for a parameter"

# -- recursion guard ------------------------------------------------------------
mo_chk "$MO_A" "Command nesting too deep (a macro or alias that runs itself?)" "a macro that runs itself is stopped by the nesting guard instead of overflowing the stack"

# -- export / import round trip --------------------------------------------------
if [ -f "$MO_DIR/cube.json" ] && grep -qF '"format": "dino8-macro-library"' "$MO_DIR/cube.json" && grep -qF '"version": 1' "$MO_DIR/cube.json"; then echo "ok   ExportMacro wrote a file tagged format dino8-macro-library, version 1"; else echo "FAIL ExportMacro did not write a versioned library file"; fail=1; fi
if command -v python3 >/dev/null 2>&1; then
  MO_PY="$(python3 -I - "$MO_DIR/cube.json" "$MO_DIR/library.json" <<'PYEOF'
import json, sys
one = json.load(open(sys.argv[1], encoding="utf-8"))
lib = json.load(open(sys.argv[2], encoding="utf-8"))
m = one["macros"][0]
print("one:", one["format"], one["version"], len(one["macros"]), m["name"], len(m["steps"]), m["steps"][0], [p["name"] for p in m["parameters"]], m["parameters"][0]["default"], m["tags"])
print("lib:", lib["format"], lib["version"], sorted(x["name"] for x in lib["macros"]))
PYEOF
)" || MO_PY="python failed"
  mo_chk "$MO_PY" "one: dino8-macro-library 1 1 cube 4 Box 0,0,0 {size},{size},0 {size} ['size'] 3 ['geometry', 'demo']" "an independent JSON parser reads the exported macro: name, 4 steps, the {size} parameter with default 3, tags"
  mo_chk "$MO_PY" "lib: dino8-macro-library 1 ['cube', 'loopy', 'quoted', 'tall']" "ExportMacro * wrote the whole library (4 macros) in one versioned file"
fi
MO_SHOW5="$(mo_block "$MO_A" "ShowMacro cube" 4)"
MO_SHOW6="$(mo_block "$MO_A" "ShowMacro cube" 5)"
if [ -n "$MO_SHOW5" ] && [ "$MO_SHOW5" = "$MO_SHOW6" ]; then echo "ok   Export -> Delete -> Import round trip: ShowMacro is byte-identical (steps, parameters, tags, description, created AND modified times)"; else echo "FAIL the export/import round trip changed the macro"; echo "--- before"; echo "$MO_SHOW5"; echo "--- after"; echo "$MO_SHOW6"; fail=1; fi
mo_chk "$MO_A" "1 renamed to avoid a name clash" "ImportMacro of a clashing name renames it (default Conflict=Rename)"
mo_chk "$MO_A" "0 added (0 renamed to avoid a name clash), 0 replaced, 1 skipped" "ImportMacro Conflict=Skip skips it"
mo_chk "$MO_A" "0 added (0 renamed to avoid a name clash), 1 replaced, 0 skipped" "ImportMacro Conflict=Replace replaces it"
mo_chk "$MO_A" "  cube (2)  [4 step(s)" "the renamed import is in the library as 'cube (2)'"
mo_chk "$MO_A" "ImportMacro: cannot read $MO_DIRW/missing.json" "ImportMacro of a missing file warns"
mo_chk "$MO_A" "not a Dino 8 macro library file" "ImportMacro refuses a file of another format"
mo_chk "$MO_A" "written by a newer Dino 8 (macro format version 99; this build reads up to 1)" "ImportMacro refuses a file written by a newer version"
mo_chk "$MO_A" "is not valid JSON" "ImportMacro refuses garbage"

# -- binding by NAME to an alias and a toolbar button -----------------------------
mo_chk "$MO_A" "Bound macro 'cube' to alias 'cubea' (-> RunMacro \"cube\")" "BindMacro creates an alias that names the macro, not its text"
mo_chk "$MO_A" "added 'cubea' to the Standard toolbar" "BindMacro Toolbar=Yes adds a toolbar button"
mo_chk "$MO_A" "BindMacro: 'box' is a command name; pick a different alias" "BindMacro will not shadow a real command"
mo_chk "$MO_A" "Bound macro 'cube' to alias 'cube5' (-> RunMacro \"cube\" size=5)" "BindMacro Args= bakes arguments into the binding"
mo_chk "$MO_A" "Volume = 216 cubic" "the alias takes run-time arguments: 'cubea size=6' -> Volume 6^3 = 216"
mo_chk "$MO_A" "Area = 54 square" "after EditMacro Append Area the SAME alias (cubea size=3) runs the edited macro: the box's Area 6*3^2 = 54 (bindings are by name, so edits flow through)"
mo_chk "$MO_A" "Area = 24 square" "after RenameMacro cube cubic the alias still works (cubea size=2 -> Area 6*2^2 = 24, Volume 8 again)"
mo_chk "$MO_A" "Renamed macro 'cube' to 'cubic' (2 alias binding(s) updated)" "RenameMacro re-points both bound aliases"
MO_SHOW_BOUND="$(mo_block "$MO_A" "ShowMacro cubic" 1)"
mo_chk "$MO_SHOW_BOUND" "cubea (alias + toolbar button)" "ShowMacro lists the alias with its toolbar button"
mo_chk "$MO_SHOW_BOUND" "cube5 (alias)" "...and the second alias"
if grep '"toolbar":' "$MO_DIR/opts_bound.json" | grep -qF '"cubea"'; then echo "ok   OptionsExport: the bound alias is a button in the saved toolbar"; else echo "FAIL the toolbar array does not contain the bound alias"; fail=1; fi
if grep -qF '"cubea": "RunMacro \"cubic\""' "$MO_DIR/opts_bound.json"; then echo "ok   OptionsExport: the alias target follows the rename (RunMacro \"cubic\")"; else echo "FAIL the alias target did not follow the rename"; grep -F '"cubea"' "$MO_DIR/opts_bound.json" | head -3; fail=1; fi
mo_chk "$MO_A" "also removed the alias/toolbar binding(s): doomedalias" "DeleteMacro on a bound macro removes its alias..."
mo_chk "$MO_A" "Unknown command: doomedalias" "...so the dead alias is gone"
if grep '"toolbar":' "$MO_DIR/opts_after.json" | grep -qF '"doomedalias"'; then echo "FAIL the deleted macro's toolbar button is still in the toolbar"; fail=1; else echo "ok   ...and its toolbar button is gone from the saved toolbar"; fi
if grep '"toolbar":' "$MO_DIR/opts_after.json" | grep -qF '"cubea"'; then echo "ok   ...while the other macro's toolbar button is untouched"; else echo "FAIL the surviving toolbar button disappeared"; fail=1; fi
mo_chk "$MO_A" "Unbound alias 'cube5' from macro 'cubic'" "UnbindMacro removes just the alias"
mo_chk "$MO_A" "UnbindMacro: 'cube5' is not an alias bound to a macro" "...and a second UnbindMacro warns"
# In-process settings reload: OptionsImport restores a deleted macro.
MO_TEMP_SHOW="$(mo_block "$MO_A" "ShowMacro temp" 2)"
mo_chk "$MO_TEMP_SHOW" "Macro 'temp'" "OptionsExport -> DeleteMacro -> OptionsImport brings the deleted macro back (settings reload restores the library)"
mo_chk "$(mo_block "$MO_A" "ShowMacro temp" 1)" "ShowMacro: no macro named 'temp'" "...it really was gone in between"

# -- the older commands are the same store -------------------------------------------
mo_chk "$MO_A" "Saved macro 'oldstyle'" "the older MacroSave still works"
mo_chk "$MO_A" "  oldstyle  [1 step(s)]" "...and its macro shows up in ListMacros as an object"
mo_chk "$MO_A" "  Circle 0,0,0 3" "...MacroLoad puts it back in the plain-text editor buffer"

# -- B: persistence across a restart ----------------------------------------------------
MO_B="$(mo_exec "$MO_CFG_A" "$TMPW/mo_b.txt")" || { echo "$MO_B"; echo "FAIL: macro-objects script B exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$MO_B" || { echo "$MO_B"; echo "FAIL: macro-objects script B produced no smoke line"; fail=1; }
mo_chk "$MO_B" "  cubic  [5 step(s); params {size}=3; tags geometry, demo]  Draws a cube and reads its volume" "NEW PROCESS: the macro (renamed, edited, with its default) is in the library"
MO_B_SHOW="$(mo_block "$MO_B" "ShowMacro cubic" 1)"
mo_chk "$MO_B_SHOW" "    5: Area" "NEW PROCESS: the structured steps persisted, including the edit"
mo_chk "$MO_B_SHOW" "    {size}  default \"3\", prompt \"Edge length\"" "NEW PROCESS: the parameter default and prompt persisted"
mo_chk "$MO_B_SHOW" "cubea (alias + toolbar button)" "NEW PROCESS: the by-name alias binding and its toolbar button persisted"
mo_chk "$MO_B" "Volume = 343 cubic" "NEW PROCESS: the persisted alias runs the persisted macro: cubea size=7 -> Volume 7^3 = 343"
MO_B_CREATED="$(grep -F '  Created: ' <<<"$MO_B_SHOW" | head -1 || true)"
MO_A_CREATED="$(grep -F '  Created: ' <<<"$(mo_block "$MO_A" "ShowMacro cubic" 1)" | head -1 || true)"
if [ -n "$MO_B_CREATED" ] && [ "$MO_B_CREATED" = "$MO_A_CREATED" ]; then echo "ok   NEW PROCESS: Created survived the restart exactly ($MO_B_CREATED)"; else echo "FAIL Created changed across the restart: [$MO_A_CREATED] [$MO_B_CREATED]"; fail=1; fi
if grep -qF '"macro_library"' "$MO_CFG_A/$MO_SETTINGS_SUB/settings.json" && ! grep -qF '"macros": {' "$MO_CFG_A/$MO_SETTINGS_SUB/settings.json"; then echo "ok   settings.json carries the library under \"macro_library\" (and no longer writes the old \"macros\" text map)"; else echo "FAIL settings.json does not carry the macro library"; fail=1; fi

# -- C: migration of a pre-objects settings file -------------------------------------------
MO_CFG_C="$TMP/mo_cfg_c"; mkdir -p "$MO_CFG_C/$MO_SETTINGS_SUB"
printf '%s\n' '{"macro_text": "Line 0,0,0 4,0,0\nCircle 10,0,0 2\n", "macros": {"oldone": "Box 0,0,0 3,3,0 3;SelLast;Volume"}}' > "$MO_CFG_C/$MO_SETTINGS_SUB/settings.json"
MO_C="$(mo_exec "$MO_CFG_C" "$TMPW/mo_c.txt")" || { echo "$MO_C"; echo "FAIL: macro-objects script C exited non-zero"; exit 1; }
grep -E "^(ok|FAIL)" <<<"$MO_C" || true
if grep -q "^FAIL" <<<"$MO_C"; then fail=1; fi
grep -q "^smoke:" <<<"$MO_C" || { echo "$MO_C"; echo "FAIL: macro-objects script C produced no smoke line"; fail=1; }
mo_chk "$MO_C" "  Scratch  [2 step(s)]  Migrated from the Macro Editor's single text buffer" "MIGRATION: the old single macro_text buffer became a macro named 'Scratch' with 2 steps"
mo_chk "$MO_C" "  oldone  [3 step(s)]  Migrated from a saved macro (MacroSave)" "MIGRATION: an old saved ';'-text macro became an object, split into 3 steps"
mo_chk "$MO_C" "    2: Circle 10,0,0 2" "MIGRATION: Scratch's steps are the buffer's lines"
mo_chk "$MO_C" "Volume = 27 cubic" "MIGRATION: the migrated 'oldone' runs (Box 3x3x3 -> Volume 27)"
mo_chk "$MO_C" "  Line 0,0,0 4,0,0" "the plain-text editor buffer still holds the old text (RecordMacro dumps it)"
mo_chk "$MO_C" "  SelLast" "MacroLoad oldone puts the migrated macro's steps back into the plain-text editor buffer"
if grep -qF '"macro_text"' "$MO_DIR/opts_migrated.json" && grep -qF '"macro_library"' "$MO_DIR/opts_migrated.json" && ! grep -qF '"macros": {' "$MO_DIR/opts_migrated.json"; then echo "ok   after migration the settings carry both macro_text (the editor buffer) and macro_library"; else echo "FAIL migrated settings lack macro_text/macro_library"; fail=1; fi

# -- D: the panel renders (widgets themselves cannot be driven headlessly) --------------------
printf 'MacroEditor\nShowMacro cubic\n' > "$TMPW/mo_d.txt"
MO_D="$(mo_exec "$MO_CFG_A" "$TMPW/mo_d.txt")" || { echo "$MO_D"; echo "FAIL: macro-objects script D (panel) exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$MO_D" && echo "ok   the Macro Editor panel, with the library populated, renders for 100 frames without crashing or an ImGui assertion" || { echo "$MO_D"; echo "FAIL: macro editor panel run produced no smoke line"; fail=1; }

# Registry-based construction history (cmd_history.cpp / history_rebuild.h):
# one dispatch table re-executes every recorded construction through
# UpdateHistory in dependency order - Extrude/ExtrudeSrf/ExtrudeCrvTapered/
# ExtrudeCrvAlongCrv/PlanarSrf/NetworkSrf (3-4 curves)/EdgeSrf/Offset/OffsetSrf/
# RailRevolve and the four booleans, on top of the older ones. See
# tests/history_registry_script.txt: every UpdateHistory is followed by a
# MEASURED Volume/Area/Length, never just an object count.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HRG="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_registry_script.txt" 2>&1)" || { echo "$HRG"; echo "FAIL: history-registry script exited non-zero"; exit 1; }
else
  HRG="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_registry_script.txt" 2>&1)" || { echo "$HRG"; echo "FAIL: history-registry script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HRG"
if grep -q "^FAIL" <<<"$HRG"; then fail=1; fi
grep -q "^smoke:" <<<"$HRG" || { echo "$HRG"; echo "FAIL: history-registry script produced no smoke line"; fail=1; }
hrgcheck() { if grep -qF -- "$1" <<<"$HRG"; then echo "ok   $2"; else echo "FAIL $2"; near "$HRG" "$1"; fail=1; fi; }
HRGSEQ="$(grep -oE '^history: (Volume = [0-9.]+|Area = [0-9.]+|Curve [0-9]+ length = [0-9.]+|UpdateHistory: [0-9]+ object\(s\) re-evaluated|BooleanUnion: exact)' <<<"$HRG" | sed 's/^history: //' | tr '\n' '|' | sed -E 's/Volume = 224\.[56]\|/Volume = 224.6|/g; s/Volume = 180[12]\|/Volume = 1802|/g')"
HRGWANT="Volume = 250|Volume = 500|UpdateHistory: 2 object(s) re-evaluated|Volume = 500|Volume = 500|Volume = 500|BooleanUnion: exact|Volume = 1500|UpdateHistory: 3 object(s) re-evaluated|Volume = 1700|Volume = 500|UpdateHistory: 3 object(s) re-evaluated|Volume = 700|Volume = 1500|UpdateHistory: 3 object(s) re-evaluated|Volume = 1700|Volume = 250|UpdateHistory: 0 object(s) re-evaluated|Volume = 250|BooleanUnion: exact|Volume = 1500|UpdateHistory: 1 object(s) re-evaluated|Volume = 4000|Volume = 1000|Volume = 500|UpdateHistory: 2 object(s) re-evaluated|Volume = 2000|Area = 400|Volume = 1436|UpdateHistory: 1 object(s) re-evaluated|Volume = 6009|Area = 50|UpdateHistory: 1 object(s) re-evaluated|Area = 100|Area = 100|UpdateHistory: 1 object(s) re-evaluated|Area = 400|Area = 50|UpdateHistory: 1 object(s) re-evaluated|Area = 200|Curve 50 length = 18.85|Volume = 112.9|UpdateHistory: 2 object(s) re-evaluated|Curve 50 length = 50.27|Volume = 803.8|Volume = 1728|UpdateHistory: 2 object(s) re-evaluated|Volume = 5808|Volume = 224.6|UpdateHistory: 1 object(s) re-evaluated|Volume = 1802|Volume = 1802|BooleanUnion: exact|Volume = 2368|UpdateHistory: 2 object(s) re-evaluated|Volume = 2128|"
if [ "$HRGSEQ" = "$HRGWANT" ]; then echo "ok   history-registry: every measured value before/after each UpdateHistory is the analytic one (curve->Extrude->BooleanIntersection 250->500 after moving the curve; ->BooleanUnion 1500->1700; BooleanDifference 500->700; Boolean2Objects 1500->1700; root deleted keeps 250; PlanarSrf->ExtrudeSrf 500->2000 and area 100->400; ExtrudeCrvTapered 1436->6009; ExtrudeCrvAlongCrv 50->100; NetworkSrf 4 curves 100->400; EdgeSrf 3 curves 50->200; Offset length 18.85->50.27 and its extrusion 112.9->803.8; Extrude->OffsetSrf 1728->5808; RailRevolve 224.6->1802 = the fresh construction; exact Box->OffsetSrf->BooleanUnion 2368->2128)"; else echo "FAIL history-registry measured sequence differs"; echo "got:  $HRGSEQ"; echo "want: $HRGWANT"; fail=1; fi
hrgcheck "object 4: BooleanIntersection <- 2,3" "the History report lists the boolean with its two recorded operand ids (the operands are hidden sources, not deleted)"
hrgcheck "object 10: BooleanUnion <- 8,9" "...and a 3-deep curve -> Extrude -> BooleanUnion chain is listed with each link's sources"
hrgcheck "object 63: OffsetSrf <- 61" "...and OffsetSrf records its source solid"
hrgcheck "object 64: BooleanUnion <- 62,63" "...and the exact-B-rep boolean records both operands"
hrgcheck "! UpdateHistory: object 22 (Extrude) kept as it was: source object 21 no longer exists" "deleting the root curve: the extrusion is not rebuilt and the printed reason names the missing source"
hrgcheck "! UpdateHistory: object 24 (BooleanIntersection) kept as it was: it depends on object 22, which was not rebuilt (source object 21 no longer exists)" "...and the boolean built from it is skipped with the upstream reason instead of being rebuilt from a half-updated chain"
hrgcheck "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry, 2 skipped" "...and the summary counts both as skipped"
hrgcheck "History recording: off. 0 object(s) with live construction history" "History Off: a boolean made while Off recorded nothing"
hrgcheck "BooleanUnion: exact B-rep boolean (no tessellation), 14 face(s)" "...and (History Off) it still deletes its operands: 24 objects, the expect_objects in the script"
hrgcheck "Object 64 (polysurface) layer Default" "the exact-boolean result is still a polysurface after UpdateHistory (it did not degrade to a mesh)"
hrgcheck "  36 faces, 72 edges, closed solid" "...with the new shape's own topology (42 faces before the box moved, 36 after) and still a closed solid"

# Automatic history propagation + EditHistory (cmd_history.cpp, Document::
# JoinPendingChange, tests/history_auto_script.txt): with History On, editing a
# SOURCE object (Move/Scale/Delete/Undo/Redo here, no UpdateHistory call in the
# A sections) rebuilds every recorded dependent in dependency order inside the
# same undo step; EditHistory re-runs a recorded construction with new options.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HAU="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_auto_script.txt" 2>&1)" || { echo "$HAU"; echo "FAIL: history-auto script exited non-zero"; exit 1; }
else
  HAU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_auto_script.txt" 2>&1)" || { echo "$HAU"; echo "FAIL: history-auto script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HAU" || true
if grep -q "^FAIL" <<<"$HAU"; then fail=1; fi
grep -q "^smoke:" <<<"$HAU" || { echo "$HAU"; echo "FAIL: history-auto script produced no smoke line"; fail=1; }
haucheck() { if grep -qF -- "$1" <<<"$HAU"; then echo "ok   $2"; else echo "FAIL $2"; near "$HAU" "$1"; fail=1; fi; }
haucheckre() { if grep -qE -- "$1" <<<"$HAU"; then echo "ok   $2"; else echo "FAIL $2"; near "$HAU" "$1"; fail=1; fi; }
haucount() { local n; n="$(grep -cF -- "$1" <<<"$HAU" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HAU" "$1"; fail=1; fi; }
HAUSEQ="$(grep -oE '^history: (! )?(Volume = [0-9.]+|Bounding box min [^ ]+ max [^ ]+|History: source object\(s\) [0-9,]+ changed - [0-9]+ dependent\(s\) re-evaluated( \([0-9,]+\))?|UpdateHistory: [0-9]+ object\(s\) re-evaluated)' <<<"$HAU" | sed 's/^history: //' | tr '\n' '|')"
HAUWANT="Volume = 1728|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)|Bounding box min 4,-1,-1 max 16,11,11|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)|Volume = 5808|Volume = 1728|Volume = 5808|Volume = 250|History: source object(s) 6 changed - 2 dependent(s) re-evaluated (7,9)|Volume = 500|Volume = 250|Volume = 500|! History: source object(s) 6 changed - 0 dependent(s) re-evaluated|Volume = 500|History: source object(s) 6 changed - 2 dependent(s) re-evaluated (7,9)|Volume = 250|Volume = 1000|Volume = 1000|UpdateHistory: 1 object(s) re-evaluated|Volume = 4000|Volume = 3168|Volume = 6048|Volume = 3168|Volume = 1728|Volume = 3168|"
if [ "$HAUSEQ" = "$HAUWANT" ]; then echo "ok   history-auto: with NO UpdateHistory call, Moving/Scaling a curve rebuilds its extrusion and the offset solid built from it (2-deep chain: offset solid box -1..11 -> 4..16 after Move, volume 1728 -> 5808 after Scale 2x, back to 1728 on Undo and 5808 on Redo - one undo step covers the curve AND both dependents); the same for curve -> Extrude -> BooleanIntersection (250 -> 500, Undo 250, Redo 500); Delete of the root curve keeps the old geometry and prints the reason; Undo of the Delete + Move rebuilds again (250); History Off propagates nothing (1000) until UpdateHistory (4000)"; else echo "FAIL history-auto measured sequence differs"; echo "got:  $HAUSEQ"; echo "want: $HAUWANT"; fail=1; fi
haucheck "! History: source object(s) 6 changed - 0 dependent(s) re-evaluated, 2 kept as they were: object 7 - source object 6 no longer exists; object 9 - it depends on object 7, which was not rebuilt (source object 6 no longer exists)" "failure case: deleting the root curve prints ONE summary line naming each kept object and its reason (the dependent of the failed extrusion is skipped with the upstream reason)"
haucheck "Automatic updates this session: 4 dependent rebuild(s), 0 kept as they were" "an unrelated edit (Move of a box nothing depends on) rebuilt nothing: still the 4 rebuilds from the two curve edits"
haucheck "Automatic updates this session: 8 dependent rebuild(s), 2 kept as they were" "...and the session totals at the end: 4 + 2 + 2 rebuilt, the 2 kept from the Delete"
haucount "History: source object(s)" 5 "exactly five automatic-update lines in the whole run (2 + 1 + the failed Delete + 1): no other edit, including the unrelated Move, the Hide/Show, selection and EditHistory, triggered one"
haucheck "EditHistory: object 13 (Extrude) <- 12 - editable parameters (EditHistory 13 name=value ...):" "EditHistory with no key=value lists the object's editable parameters"
haucheck "  distance = 10   - extrusion distance along the recorded direction (non-zero; negative flips the direction)" "...with the current value and the valid range"
haucheck "  bothsides = no   - extrude symmetrically to both sides of the curve [yes|no]" "...and choice options with their choices"
haucheck "EditHistory: object 13 (Extrude): distance 10 -> 20." "EditHistory distance=20 reports the change"
haucheck "  before: bbox 0,50,0 to 10,60,10, volume 1000" "...with the measured geometry before (10x10x10 prism, volume 1000)"
haucheck "  after:  bbox 0,50,0 to 10,60,20, volume 2000" "...and after (z 0..20, volume 2000)"
haucheck "  dependents re-evaluated: 14" "...and the offset solid built from the extrusion is re-evaluated in the same step"
haucheck "  after:  bbox 0,50,-20 to 10,60,20, volume 4000" "bothsides=yes: the extrusion becomes symmetric about the curve (z -20..20, volume 4000; the offset solid follows to 6048, see the sequence)"
haucheck "EditHistory: object 13 unchanged - distance: distance must be non-zero" "a zero distance is refused and changes nothing"
haucheck "EditHistory: object 13 unchanged - 'bogus' is not an editable parameter of Extrude (valid: distance, bothsides, solid)" "an unknown parameter is refused, listing the valid names"
haucheck "EditHistory: object 13 unchanged - bothsides: 'maybe' is not one of: yes, no" "a bad choice value is refused, listing the choices"
haucheck "EditHistory: object 12 has no recorded construction history" "EditHistory on an object with no history says so"
haucheck "EditHistory: object 99 does not exist" "EditHistory on a missing id says so"
haucount "  distance = 10   - extrusion distance along the recorded direction" 2 "after Undo the RECORD is restored with the geometry: the parameter listing reads distance=10 originally, and again after the second Undo (the listing of 20 sits between them)"
haucount "  distance = 20   - extrusion distance along the recorded direction" 1 "...and reads distance=20 after the first Undo (undoing only the bothsides edit)"
haucheck "ListHistory: 1 object(s) with construction history:" "ListHistory names the recorded objects"
haucheck "  object 14 (mesh): OffsetSrf <- 13  [distance=1, solid=no]" "...with each record's sources and parameters"
haucheck "      input 13 (polysurface)" "ShowHistory also names each input object"
haucheck "  after:  bbox -10,-10,0 to 10,10,5, volume 1302" "tapered extrusion: draft 10 -> 20 degrees measurably narrows the solid (1436 -> 1302)"
haucheck "  after:  bbox -10,-10,0 to 10,10,10, volume 3140" "...distance 10 draft 0 is the straight cylinder pi*100*10 = 3141.6"
haucheck "EditHistory: object 16 unchanged - draft: draft must be between -90 and 90 degrees (exclusive)" "an out-of-range draft is refused"
haucheck "EditHistory: object 18 (Revolve): angle 360 -> 180." "revolve angle 360 -> 180"
haucheck "volume 224.6" "...from the full-revolve volume 224.6"
haucheckre "volume 112\.[1-4]" "...to half of it (112.1 on Linux, 112.3 on the Windows tessellation)"
haucheck "EditHistory: object 18 unchanged - angle: angle must be greater than 0 and at most 360 degrees" "an angle over 360 is refused"
haucheck "EditHistory: object 20 (Pipe): radius 1 -> 2." "pipe radius 1 -> 2"
haucheckre "volume 31\.2[89]" "...volume pi*1*10 = 31.4 (tessellated 31.29 on Linux, 31.28 on Windows)"
haucheck "volume 125.4" "...to pi*4*10 = 125.7 (tessellated 125.4)"
haucheck "EditHistory: object 20 unchanged - radius: radius must be positive" "a negative radius is refused"
haucheck "EditHistory: object 24 (Loft): style normal -> straight." "loft style Normal -> Straight"
haucheck "  before: bbox 0,0,300 to 10,10,302.9, area 120.4" "...Normal interpolates smoothly through the middle line (area 120.4, z peak 302.9)"
haucheck "  after:  bbox 0,0,300 to 10,10,303, area 116.6" "...Straight is the ruled loft 2 * 10 * sqrt(5^2+3^2) = 116.6"
haucheck "EditHistory: object 26 (Offset): distance -2 -> -1." "curve offset distance -2 -> -1"
haucheck "length 18.85" "...inward offset circle r=3 has length 18.85"
haucheck "length 25.13" "...r=4 has length 25.13"
haucheck "length 37.7" "...and distance +1 flips to the outside, r=6: length 37.7"
haucount "operand groups swapped" 2 "boolean swap=yes twice"
haucheck "  after:  bbox 10,150,0 to 12,160,10, volume 200" "BooleanDifference swap=yes: A-B (800) becomes B-A (200)"
haucheck "  after:  bbox 0,150,0 to 12,160,10, volume 1200" "operation=union: 800 + 400 - 200 = 1200"
haucheck "  after:  bbox 8,150,0 to 10,160,10, volume 200" "operation=intersection: the 2 x 10 x 10 overlap, volume 200"
haucheck "  object 30: BooleanDifference <- 28,29  [operation=intersection]" "the History report names each record's parameters: the edited boolean now reads operation=intersection"
haucheck "  object 24: Loft <- 21,22,23  [style=normal, cap=yes]" "...and the loft's style/cap"


# Automatic history propagation, part 2 (tests/history_auto2_script.txt): the
# other ways a source is edited (Rotate, Mirror Copy=No, ScaleNU, a boolean
# OPERAND moved directly) rebuild the dependents with no UpdateHistory, inside
# the same undo step; every claim is a measured Volume.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  HA2="$(timeout 900 "$BIN" --smoke 100 --script "$HERE/history_auto2_script.txt" 2>&1)" || { echo "$HA2"; echo "FAIL: history-auto2 script exited non-zero"; exit 1; }
else
  HA2="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$HERE/history_auto2_script.txt" 2>&1)" || { echo "$HA2"; echo "FAIL: history-auto2 script exited non-zero"; exit 1; }
fi
grep -E "^(ok|FAIL)" <<<"$HA2" || true
if grep -q "^FAIL" <<<"$HA2"; then fail=1; fi
grep -q "^smoke:" <<<"$HA2" || { echo "$HA2"; echo "FAIL: history-auto2 script produced no smoke line"; fail=1; }
ha2check() { if grep -qF -- "$1" <<<"$HA2"; then echo "ok   $2"; else echo "FAIL $2"; near "$HA2" "$1"; fail=1; fi; }
ha2count() { local n; n="$(grep -cF -- "$1" <<<"$HA2" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$HA2" "$1"; fail=1; fi; }
HA2SEQ="$(grep -oE '^history: (Volume = [0-9.]+|History: source object\(s\) [0-9,]+ changed - [0-9]+ dependent\(s\) re-evaluated( \([0-9,]+\))?)' <<<"$HA2" | sed 's/^history: //' | tr '\n' '|')"
HA2WANT="Volume = 500|History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,4)|Volume = 457.1|Volume = 500|Volume = 457.1|Volume = 600|History: source object(s) 5 changed - 2 dependent(s) re-evaluated (6,8)|Volume = 400|Volume = 1000|History: source object(s) 9 changed - 1 dependent(s) re-evaluated (10)|Volume = 3000|Volume = 500|History: source object(s) 13 changed - 1 dependent(s) re-evaluated (14)|Volume = 200|Volume = 500|"
if [ "$HA2SEQ" = "$HA2WANT" ]; then echo "ok   history-auto2: with NO UpdateHistory call a Rotate of the source square rebuilds the extrusion AND the boolean built from it (overlap with a fixed box 500 -> 457.1 = 10*(50-4.289), the diamond clipped to the box), Undo restores 500 and Redo 457.1 in single steps; Mirror Copy=No across x=10 moves it 600 -> 400; ScaleNU 3,1,1 takes an extrusion 1000 -> 3000; moving a boolean's OPERAND (the box, not its curve) rebuilds the boolean 500 -> 200 and Undo gives 500"; else echo "FAIL history-auto2 measured sequence differs"; echo "got:  $HA2SEQ"; echo "want: $HA2WANT"; fail=1; fi
ha2count "History: source object(s)" 4 "exactly four automatic-update lines (Rotate, Mirror, ScaleNU, operand Move): Undo/Redo, Show, selection and Volume triggered none"
ha2check "Automatic updates this session: 6 dependent rebuild(s), 0 kept as they were" "...and the session total is 2 + 2 + 1 + 1 rebuilds, none kept"
ha2count "History rebuild of a boolean: exact B-rep boolean declined" 3 "a boolean rebuilt automatically prints the same engine-decline reason the live command printed (3 mesh-path rebuilds)"

# ---------------------------------------------------------------------------
# viewport close (PARITY_MAP.md app_display "Per-object display mode override" +
# "View-dependent adaptive tessellation"): per-object RayTraced composited with
# rasterized objects (pixels), face-level brep refinement (triangle counts and
# sagitta vs an exact cylinder/sphere, no rebuild thrash), curve/SubD/mesh deep zoom,
# and the adaptive on/off setting persisted in settings.json.
# tests/viewport_close_script.txt builds everything; the checks are below.
# ---------------------------------------------------------------------------
mkdir -p "$TMPW/vpc"
sed "s|@TMP@|$TMPW/vpc|g" "$HERE/viewport_close_script.txt" > "$TMPW/viewport_close_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  VPC="$(timeout 900 env DINO8_RT_FRAMES=1 "$BIN" --smoke 30 --script "$TMPW/viewport_close_script.txt" 2>&1)" || { echo "$VPC"; echo "FAIL: viewport_close script exited non-zero"; exit 1; }
else
  VPC="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" env DINO8_RT_FRAMES=1 "$BIN" --smoke 30 --script "$TMPW/viewport_close_script.txt" 2>&1)" || { echo "$VPC"; echo "FAIL: viewport_close script exited non-zero"; exit 1; }
fi
vpccheck() { if grep -q "$1" <<<"$VPC"; then echo "ok   $2"; else echo "FAIL $2"; near "$VPC" "$1"; fail=1; fi; }
vpcnum() { # DESC EXPR : EXPR is an awk expression over already-substituted numbers
  local r; r="$(awk "BEGIN { print ($2) ? \"yes\" : \"no\" }")"
  if [ "$r" = yes ]; then echo "ok   $1"; else echo "FAIL $1 [$2]"; fail=1; fi
}
# vpchdr N FIELD: FIELD of the N-th "LodStats: adaptive=" header line.
vpchdr() {
  awk -v n="$1" -v f="$2" '
    /LodStats: adaptive=/ { k++; if (k == n) { if (match($0, f "=[a-z0-9]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPC"
}
# vpcval N VIEWPORT FIELD: FIELD of the first object line of viewport VIEWPORT in the N-th LodStats call.
vpcval() {
  awk -v n="$1" -v v="$2" -v f="$3" '
    /LodStats: adaptive=/ { k++ }
    k == n && index($0, "LodStats: viewport " v " object ") { if (match($0, f "=[-0-9.e+]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } }' <<<"$VPC"
}
# vpcsag N FIELD: FIELD of the N-th "LodSagitta:" line.
vpcsag() {
  awk -v n="$1" -v f="$2" '
    /^LodSagitta: / || /history: LodSagitta: / { k++; if (k == n) { if (match($0, f "=[-0-9.e+]+")) { print substr($0, RSTART + length(f) + 1, RLENGTH - length(f) - 1); exit } } }' <<<"$VPC"
}
vpccheck "gl_error=0" "viewport_close script ran without OpenGL errors"

# ---- Part A: per-object RayTraced, pixel level --------------------------------
python3 - "$TMPW/vpc" <<'PY' && echo "ok   per-object display modes work in a RayTraced viewport and RayTraced works per object: rasterized objects are depth-composited with the traced frame in BOTH directions (sphere in front hides the Pen box; Pen box in front hides the sphere)" || { echo "FAIL per-object RayTraced pixel check"; fail=1; }
import struct, sys
d = sys.argv[1]
def load(name):
    b = open(f'{d}/{name}.bmp', 'rb').read()
    size, off, hdr, w, h, planes, bpp = struct.unpack('<IxxxxIIiiHH', b[2:30])
    assert hdr == 40 and planes == 1 and bpp == 24, (name, hdr, planes, bpp)
    row = (w * 3 + 3) & ~3
    px = b[off:]
    def get(x, y):
        r = h - 1 - y
        i = r * row + x * 3
        return px[i + 2], px[i + 1], px[i]
    return w, h, get
def white(p): return all(c >= 235 for c in p)
all_t, front, back = load('a_all_traced'), load('a_sphere_front'), load('a_sphere_back')
sh_base, sh_rt = load('a_shaded_base'), load('a_shaded_rtsphere')
w, h, gb = back
ws = [(x, y) for y in range(h) for x in range(w) if white(gb(x, y))]
assert ws, 'no Pen-white pixels in a_sphere_back: the rasterized Pen box is missing from the RayTraced viewport'
xs, ys = [p[0] for p in ws], [p[1] for p in ws]
x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
s = (x1 - x0) / 8.6            # pixels per world unit (box B is 8.6 wide)
bx = int(cx + 3.8 * s)         # a point on B outside the sphere's radius-3 silhouette
ax = int(cx - 30 * s)          # centre of box A (x=-15)
print(f'B white bbox x {x0}..{x1} y {y0}..{y1} centre ({cx},{cy}) scale {s:.2f} px/unit; probes: B-edge ({bx},{cy}) A ({ax},{cy})')
def show(tag, im, pts):
    print(f'{tag:18s}', ' '.join(f'{n}={im[2](*p)}' for n, p in pts.items()))
pts = {'Bcentre': (cx, cy), 'Bside': (bx, cy), 'A': (ax, cy)}
for tag, im in (('all_traced', all_t), ('sphere_front', front), ('sphere_back', back), ('shaded_base', sh_base), ('shaded_rtsphere', sh_rt)): show(tag, im, pts)
g = lambda im, p: im[2](*p)
# NOTE: this environment's software GL (xvfb/llvmpipe) shows the GPU trace's OWN pixels as the dark background even for a
# plain box (the pre-existing RayTraced viewport has no pixel assertion anywhere), so what is measured here is what the
# composite itself decides: which objects the rasterizer draws, and depth occlusion between rasterized and traced objects.
# 1. B -> Pen (rasterized, flat white) while the sphere in FRONT is traced: B is visible beside the sphere, and the TRACED sphere
#    (whose depth the composite wrote) hides B's centre - there the traced frame shows through instead of the flat white
assert white(g(front, (bx, cy))), f'Pen box not rasterized beside the sphere: {g(front, (bx, cy))}'
assert not white(g(front, (cx, cy))), f'traced sphere in front does not hide the rasterized box centre: {g(front, (cx, cy))}'
# 2. sphere BEHIND the Pen box: the rasterized box hides the traced sphere
assert white(g(back, (cx, cy))), f'rasterized Pen box does not hide the traced sphere behind it: {g(back, (cx, cy))}'
# 3. A (never overridden) is traced in a RayTraced viewport, so the rasterizer must NOT draw it: it is not its Shaded red
assert g(front, (ax, cy)) != g(sh_base, (ax, cy)) and not white(g(front, (ax, cy))), 'box A was rasterized in the RayTraced viewport'
# 4. Shaded viewport + sphere overridden to RayTraced: the sphere is no longer rasterized-green, A and B (still rasterized) are
#    byte-identical to the all-Shaded capture
assert g(sh_base, (cx, cy))[1] > g(sh_base, (cx, cy))[0] + 40, 'shaded base sphere is not green'
assert g(sh_rt, (cx, cy)) != g(sh_base, (cx, cy)) and not (g(sh_rt, (cx, cy))[1] > g(sh_rt, (cx, cy))[0] + 40), 'sphere still rasterized after the RayTraced override'
assert g(sh_base, (ax, cy)) == g(sh_rt, (ax, cy)), 'rasterized box A changed when only the sphere was overridden to RayTraced'
assert g(sh_base, (bx, cy)) == g(sh_rt, (bx, cy)), 'rasterized box B changed when only the sphere was overridden to RayTraced'
PY
vpccheck "ObjectDisplayModes: object [0-9]* polysurface = Pen (viewport Top)" "ObjectDisplayModes lists the Pen override in the RayTraced viewport"
vpccheck "ObjectDisplayModes: object [0-9]* polysurface = RayTraced (viewport Top)" "ObjectDisplayModes lists RayTraced as a per-object (per-viewport) mode"
vpccheck "SetObjectDisplayMode: 1 object(s) now always shown RayTraced" "SetObjectDisplayMode RayTraced is accepted (no longer refused)"
VPC_RT_RT="$(grep -c 'ObjectDisplayModes: object [0-9]* polysurface = RayTraced (viewport Top)' <<<"$VPC" || true)"
vpcnum "RayTraced survives Save/New/Open through the .3dm (listed before and after the round trip)" "$VPC_RT_RT == 2"
if grep -q "GpuRaytracer::Init failed" <<<"$VPC"; then echo "FAIL GpuRaytracer::Init failed in the viewport_close script"; fail=1; else echo "ok   GpuRaytracer::Init did not fail in the viewport_close script"; fi

# ---- Part B: face-level refinement (sphere R500 + cylinder R100 through it, Front view) ----
V_OLD_TRIS="$(vpcval 2 Front tris)"; V_NEW_TRIS="$(vpcval 3 Front tris)"
V_OLD_FF="$(vpcval 2 Front fine_faces)"; V_NEW_FF="$(vpcval 3 Front fine_faces)"; V_TOT="$(vpcval 3 Front total_faces)"
V_OLD_MAX="$(vpcsag 1 max_sagitta)"; V_NEW_MAX="$(vpcsag 2 max_sagitta)"
V_OLD_MEAN="$(vpcsag 1 mean_sagitta)"; V_NEW_MEAN="$(vpcsag 2 mean_sagitta)"
V_OLD_IN="$(vpcsag 1 in_region)"; V_NEW_IN="$(vpcsag 2 in_region)"
echo "     visible-corner deep zoom on the +Z cylinder tip: whole-object (old) $V_OLD_TRIS tris, $V_OLD_IN in view, max/mean sagitta $V_OLD_MAX / $V_OLD_MEAN;  face-level (new) $V_NEW_TRIS tris ($V_NEW_FF of $V_TOT faces fine), $V_NEW_IN in view, max/mean sagitta $V_NEW_MAX / $V_NEW_MEAN"
vpcnum "face-level: only the visible faces are fine (fine_faces < total_faces, >= 1); the old whole-object build has fine_faces=0 (all faces at one level)" "$V_NEW_FF >= 1 && $V_NEW_FF < $V_TOT && $V_OLD_FF == 0"
vpcnum "face-level: the whole mesh is much smaller than the whole-object build ($V_NEW_TRIS < $V_OLD_TRIS)" "$V_NEW_TRIS < $V_OLD_TRIS"
vpcnum "face-level: the visible corner is MORE accurate (max sagitta new $V_NEW_MAX <= old $V_OLD_MAX) with the same budget" "$V_NEW_MAX <= $V_OLD_MAX"
vpcnum "face-level: and has at least as many triangles in the visible region (new $V_NEW_IN >= old $V_OLD_IN)" "$V_NEW_IN >= $V_OLD_IN"
vpcnum "the per-object budget still holds in both builds (<= 150000 triangles + 10%)" "$V_NEW_TRIS <= 165000 && $V_OLD_TRIS <= 165000"
# no thrash: steady frames never rebuild; moving to another face is ONE rebuild; returning is a stash hit
R3="$(vpchdr 3 rebuilds)"; R4="$(vpchdr 4 rebuilds)"; R5="$(vpchdr 5 rebuilds)"; R6="$(vpchdr 6 rebuilds)"; R7="$(vpchdr 7 rebuilds)"; R8="$(vpchdr 8 rebuilds)"
H3="$(vpchdr 3 stash_hits)"; H7="$(vpchdr 7 stash_hits)"
echo "     rebuilds across the face-level steps: after build $R3, +10 frames $R4, other face $R5, +10 frames $R6, back $R7, +10 frames $R8;  stash_hits $H3 -> $H7"
vpcnum "no per-frame rebuild thrash: ten more frames at the same view rebuild nothing" "$R4 == $R3"
vpcnum "...also after moving the view to a different face and after returning" "$R6 == $R5 && $R8 == $R7"
vpcnum "moving to another face rebuilds (at most 2 levels), returning is served from the stash (rebuilds unchanged, stash_hits up)" "$R5 - $R4 <= 2 && $R7 == $R6 && $H7 > $H3"
vpcnum "the other face is the fine one there (sphere view: fine_faces >= 1 and < total)" "$(vpcval 5 Front fine_faces) >= 1 && $(vpcval 5 Front fine_faces) < $(vpcval 5 Front total_faces)"
echo "     sphere face in view (R500, one face, nothing to cull inside it): $(vpcval 5 Front tris) tris, max/mean sagitta in the 25x30 window $(vpcsag 3 max_sagitta) / $(vpcsag 3 mean_sagitta) (the face alone exhausts the budget; a face this big is not refined only where visible)"
vpcnum "the single visible face may use the whole budget (>100000 triangles, <= 165000) - the other four faces stay at their small off-screen cap" "$(vpcval 5 Front tris) > 100000 && $(vpcval 5 Front tris) <= 165000"

# measurement commands do not depend on the camera: BoundingBox/Volume/Area at zoom-extents and at the deepest zoom agree exactly
VPC_BBN="$(grep -ac 'Bounding box min' <<<"$VPC" || true)"; VPC_BBD="$(grep -a 'Bounding box min' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"
VPC_VOD="$(grep -a 'Volume = ' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"; VPC_ARD="$(grep -a 'Area = ' <<<"$VPC" | sed 's/^history: //' | sort -u | wc -l || true)"
vpcnum "BoundingBox, Volume and Area read the same at zoom-extents and at a 12-unit deep zoom with the face-level mesh built (each printed twice, one distinct value)" "$VPC_BBN == 2 && $VPC_BBD == 1 && $VPC_VOD == 1 && $VPC_ARD == 1"

# ---- Part D: curves, SubD, mesh ------------------------------------------------
C0_N="$(vpcsag 5 total)"; C0_S="$(vpcsag 5 max_sagitta)"; C1_N="$(vpcsag 6 total)"; C1_S="$(vpcsag 6 max_sagitta)"
echo "     circle R500: whole view $C0_N segments max sagitta $C0_S;  deep zoom (12-unit window) $C1_N segments max sagitta $C1_S"
vpcnum "curve: deep zoom re-samples the circle finer (more segments) and the chord error drops with the zoom" "$C1_N > $C0_N && $C1_S < $C0_S"
vpcnum "curve: at deep zoom the chord error is below half a pixel of that zoom ($(vpcval 9 Top surface_tol) units)" "$C1_S < $(vpcval 9 Top surface_tol)"
S0="$(vpcval 10 Top tris)"; S1="$(vpcval 11 Top tris)"
echo "     SubD box 1000: smooth display triangles at zoom-extents $S0, in a 4-unit window $S1"
vpcnum "SubD: smooth display is subdivided deeper on zoom (more triangles at deep zoom), within the 150000-triangle budget" "$S1 > $S0 && $S1 <= 165000"
M0="$(vpcval 12 Top tris)"; M1="$(vpcval 13 Top tris)"
M0S="$(vpcsag 7 max_sagitta)"; M1S="$(vpcsag 8 max_sagitta)"
echo "     MeshSphere R500 (528 faces): display triangles at extents $M0 and at deep zoom $M1; sagitta of the mesh itself vs the exact sphere $M0S / $M1S"
vpcnum "mesh: the display level IS the mesh (same triangle count at every zoom; nothing re-tessellated)" "$M0 == $M1"

# ---- Part C: the adaptive on/off setting persists in settings.json -------------
mkdir -p "$TMPW/vpc_persist"
printf 'AdaptiveTessellation Off\n' > "$TMPW/vpc_persist/off.txt"
printf 'LodStats\n' > "$TMPW/vpc_persist/status.txt"
printf 'AdaptiveTessellation On\n' > "$TMPW/vpc_persist/on.txt"
run_vpc_persist() {
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 300 "$BIN" --smoke 10 --script "$1" 2>&1
  else
    timeout 300 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 10 --script "$1" 2>&1
  fi
}
VPC_P1="$(run_vpc_persist "$TMPW/vpc_persist/off.txt")" || { echo "$VPC_P1"; echo "FAIL: persist-off launch exited non-zero"; fail=1; }
if grep -q '"adaptive_tessellation": false' "$CONFIG_DIR/settings.json"; then echo "ok   settings.json stores \"adaptive_tessellation\": false after AdaptiveTessellation Off"; else echo "FAIL settings.json has no adaptive_tessellation=false"; grep -n adaptive "$CONFIG_DIR/settings.json"; fail=1; fi
VPC_P2="$(run_vpc_persist "$TMPW/vpc_persist/status.txt")" || { echo "$VPC_P2"; echo "FAIL: persist-status launch exited non-zero"; fail=1; }
if grep -q "LodStats: adaptive=off" <<<"$VPC_P2"; then echo "ok   a fresh launch reads adaptive tessellation OFF back from settings.json (the toggle survives sessions)"; else echo "FAIL fresh launch did not restore adaptive=off"; near "$VPC_P2" "LodStats: adaptive"; fail=1; fi
VPC_P3="$(run_vpc_persist "$TMPW/vpc_persist/on.txt")" || { echo "$VPC_P3"; echo "FAIL: persist-on launch exited non-zero"; fail=1; }
if grep -q '"adaptive_tessellation": true' "$CONFIG_DIR/settings.json"; then echo "ok   turning it back On is persisted too (\"adaptive_tessellation\": true)"; else echo "FAIL settings.json has no adaptive_tessellation=true"; fail=1; fi

# SetObjectDisplayMode is an undo step (independent review found it mutated the
# object with no BeginChange): Undo returns the object to the viewport's own mode,
# Redo reapplies it. (display_mode_undo_script.txt)
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  DMU="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/display_mode_undo_script.txt" 2>&1)" || { echo "$DMU"; echo "FAIL: display-mode undo script exited non-zero"; exit 1; }
else
  DMU="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/display_mode_undo_script.txt" 2>&1)" || { echo "$DMU"; echo "FAIL: display-mode undo script exited non-zero"; exit 1; }
fi
dmu_count() { grep -c -- "$1" <<<"$DMU" || true; }
[ "$(dmu_count 'ObjectDisplayModes: 1 of 1 object(s) carry a per-object display mode Pen=1')" = "2" ] \
  && echo "ok   SetObjectDisplayMode Pen was applied, and Redo applied it again (two reports of Pen=1)" \
  || { echo "FAIL SetObjectDisplayMode Pen / Redo did not report Pen=1 twice"; fail=1; }
[ "$(dmu_count 'ObjectDisplayModes: 0 of 1 object(s) carry a per-object display mode')" = "1" ] \
  && echo "ok   Undo reverted SetObjectDisplayMode: the object is back on the viewport's own mode" \
  || { echo "FAIL Undo did not revert SetObjectDisplayMode"; fail=1; }

# ---------------------------------------------------------------------------
# SATS: SubD app-toolset QC (subd_apptoolset_script.txt) - two app-level gaps
# of the SubD bullets, measured through the real app:
#  (1) SubD booleans: SplitByObject with a SubD target or cutter returns two
#      SubD pieces (creased seam) instead of two flat Meshes.
#  (2) SubD symmetry: Symmetry Mode=Radial / TwoPlane on NON-SubD objects
#      (used to be skipped / a single plain mirror) builds live image copies.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SATS="$(timeout 900 "$BIN" --smoke 300 --script "$HERE/subd_apptoolset_script.txt" 2>&1)" || { echo "$SATS"; echo "FAIL: subd app-toolset script exited non-zero"; exit 1; }
else
  SATS="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 300 --script "$HERE/subd_apptoolset_script.txt" 2>&1)" || { echo "$SATS"; echo "FAIL: subd app-toolset script exited non-zero"; exit 1; }
fi
sats_check() { if grep -q -- "$1" <<<"$SATS"; then echo "ok   $2"; else echo "FAIL $2"; near "$SATS" "$1"; fail=1; fi; }
sats_absent() { if grep -q -- "$1" <<<"$SATS"; then echo "FAIL $2"; near "$SATS" "$1"; fail=1; else echo "ok   $2"; fi; }
sats_count() { local n; n="$(grep -c -- "$1" <<<"$SATS" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3 ($n)"; else echo "FAIL $3 (found '$n', expected $2)"; near "$SATS" "$1"; fail=1; fi; }
# (2a) Radial, Brep box, Count=4 about the Z axis: three rotated images (90/180/270 degrees)
sats_check "Symmetry: 3 live radial copies created" "Symmetry Mode=Radial Count=4 on a non-SubD Brep makes 3 live rotated copies (before: skipped, radial needed a SubD cage)"
sats_check "Bounding box: (-2, 8, 0) to (2, 12, 4)" "radial image 1 of the box (8..12, -2..2) is the exact 90 degree rotation (-2..2, 8..12)"
sats_check "Bounding box: (-12, -2, 0) to (-8, 2, 4)" "radial image 2 is the exact 180 degree rotation (-12..-8, -2..2)"
sats_check "Bounding box: (-2, -12, 0) to (2, -8, 4)" "radial image 3 is the exact 270 degree rotation (-2..2, -12..-8)"
sats_check "Bounding box: (-7, 8, 0) to (-3, 12, 4)" "moving the source +5 in y live-moved image 1 to (-7..-3, 8..12): a live link, not a one-time bake"
sats_check "Bounding box: (3, -12, 0) to (7, -8, 4)" "moving the source +5 in y live-moved image 3 to (3..7, -12..-8)"
sats_count "Bounding box: (-7, 8, 0) to (-3, 12, 4)" 2 "after RemoveSymmetry a further source move did NOT move image 1 (still (-7..-3, 8..12))"
sats_absent "Bounding box: (-12, 8, 0) to (-8, 12, 4)" "the freed image never followed the post-removal move"
sats_check "RemoveSymmetry: 3 live symmetry link(s) removed" "RemoveSymmetry on the source removed all 3 radial image links"
# (2b) TwoPlane, Brep box: reflections across plane 1, plane 2 and both
sats_check "Symmetry: 3 live two-plane copies created" "Symmetry Mode=TwoPlane on a non-SubD Brep makes 3 live copies (reflect plane 1, plane 2, both)"
sats_check "Bounding box: (46, 2, 0) to (48, 4, 3)" "two-plane image 1: reflection across x=50 of (52..54, 2..4)"
sats_check "Bounding box: (52, -4, 0) to (54, -2, 3)" "two-plane image 2: reflection across y=0"
sats_check "Bounding box: (46, -4, 0) to (48, -2, 3)" "two-plane image 3: both reflections"
sats_check "Bounding box: (46, -5, 0) to (48, -3, 3)" "moving the source +1 in y live-moved the double image to (46..48, -5..-3)"
# (2c) Radial on a curve, Count=3: 120 and 240 degrees
sats_check "Symmetry: 2 live radial copies created" "Symmetry Mode=Radial Count=3 on a Line makes 2 live copies"
sats_check "Bounding box: (-5, 8.66025, 0) to (-5, 8.66025, 5)" "the Line (10,0,0)-(10,0,5) rotated 120 degrees lands at (-5, 8.66025)"
sats_check "Bounding box: (-5, -8.66025, 0) to (-5, -8.66025, 5)" "rotated 240 degrees lands at (-5, -8.66025)"
# (1) SplitByObject with SubD operands
sats_check "SplitByObject: 1 solid(s) split into 2 piece(s) (SubD boolean: the pieces are editable SubDs, 1108 face(s) in all, 322 crease edge(s) on the cut seams)" "SplitByObject of a SubD box by an overlapping SubD box: 2 SubD pieces, 1108 faces, 322 seam crease edges"
sats_check "Object 14 (SubD) layer Default" "the inside piece is a SubD object (before: a Mesh)"
sats_check "469 faces, 823 edges, 356 vertices, 162 creases" "inside piece: 469 faces, 162 creases (Euler 356 - 823 + 469 = 2, one closed body)"
sats_check "639 faces, 1165 edges, 528 vertices, 160 creases" "outside piece: 639 faces, 160 creases (Euler 528 - 1165 + 639 = 2, one closed body)"
sats_check "SplitByObject: 1 solid(s) split into 2 piece(s) (SubD boolean: the pieces are editable SubDs, 67[56] face(s) in all, 144 crease edge(s) on the cut seams)" "a SubD cutter through a Brep box target also yields SubD pieces (675 or 676 faces - the mesh boolean under it tessellates one triangle differently on Windows - and 144 seam creases)"
sats_check "does not intersect the cutting object(s)" "a SubD cutter that misses the target splits nothing"
sats_check "Object 20 (SubD) layer Default name 'MissTarget'" "the missed SubD target is still there, unchanged"
sats_check "Object 21 (SubD) layer Default name 'MissCutter'" "the missing cutter is not consumed"
sats_absent "(mesh boolean; results are meshes)" "no SubD-involving split fell through to the Mesh pipeline"
mapfile -t SATS_VOLS < <(grep -o "Volume = [0-9.e+-]*" <<<"$SATS" | awk '{print $3}')
if [ "${#SATS_VOLS[@]}" -ge 5 ]; then
  echo "ok   subd app-toolset script printed ${#SATS_VOLS[@]} volumes"
  if awk -v a="${SATS_VOLS[1]}" 'BEGIN{exit !(a>11.99 && a<12.01)}'; then echo "ok   the two-plane reflected Brep copy has positive volume ${SATS_VOLS[1]} (box 2x2x3 = 12)"; else echo "FAIL two-plane copy volume ${SATS_VOLS[1]}"; fail=1; fi
  # outside piece (Volume #4) = A - B, inside piece (#5) = A and B; together they are the smooth 4-cube blob (0.327 x 64 = 20.9, +- 3%)
  if awk -v o="${SATS_VOLS[3]}" -v i="${SATS_VOLS[4]}" 'BEGIN{t=o+i; exit !(o>12.3 && o<12.5 && i>8.7 && i<8.95 && t>20.3 && t<21.6)}'; then echo "ok   SplitByObject pieces: outside ${SATS_VOLS[3]} + inside ${SATS_VOLS[4]} = $(awk -v o="${SATS_VOLS[3]}" -v i="${SATS_VOLS[4]}" 'BEGIN{printf "%.3f", o+i}') (the whole SubD box blob ~20.9; BooleanDifference/Intersection of the same boxes gave 12.43 / 8.829)"; else echo "FAIL SplitByObject piece volumes outside ${SATS_VOLS[3]}, inside ${SATS_VOLS[4]}"; fail=1; fi
else
  echo "FAIL subd app-toolset script printed only ${#SATS_VOLS[@]} volumes (expected 5)"; fail=1
fi
sats_check "gl_error=0" "subd app-toolset script ran without OpenGL errors"
sats_check "smoke: frames=[0-9]* objects=17 " "subd app-toolset script produced the expected object count"

# Patch with HOLES (patch_holes_script.txt): a non-planar Patch used to trim the
# fitted surface only when EXACTLY ONE closed curve was selected; with several the
# result was the untrimmed rectangle-extent surface. Now the closed curve enclosing
# the most area is the outer loop (Brep::TrimmedPatchFace) and every other closed
# curve wholly inside it is an inner loop of the same face. Data: the saddle
# z = 0.06 (x^2 - y^2); outer ring r = 5 (closed cubic, 24 control points), hole
# rings on the same surface. The areas are tessellation-derived, so they are
# range-checked (Windows tessellates slightly differently); the topology counts
# (faces/edges) and the kernel-measured deviations are exact/numeric.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  PHL_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$HERE/patch_holes_script.txt" 2>&1)" || { echo "$PHL_OUT"; echo "FAIL: patch-holes script exited non-zero"; exit 1; }
else
  PHL_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$HERE/patch_holes_script.txt" 2>&1)" || { echo "$PHL_OUT"; echo "FAIL: patch-holes script exited non-zero"; exit 1; }
fi
phl_check() { if grep -q "$1" <<<"$PHL_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$PHL_OUT" "$1"; fail=1; fi; }
phl_count() { local n; n="$(grep -c "$1" <<<"$PHL_OUT" || true)"; if [ "$n" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (found $n, expected $2)"; near "$PHL_OUT" "$1"; fail=1; fi; }
# nth "Area = X" value (1-based) as a bare number
phl_area() { { grep -o 'Area = [0-9.]* square' <<<"$PHL_OUT" || true; } | sed -n "${1}p" | sed 's/Area = //; s/ square//'; }
# awk range test: phl_in_range VALUE LO HI
phl_in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }'; }
if grep -q "^FAIL" <<<"$PHL_OUT"; then echo "FAIL patch-holes script printed a FAIL line"; fail=1; fi
phl_count "^ok   expect_objects 0 (got 0)" 8 "patch-holes script: every case cleaned up after itself (8 sections, none left an object behind)"
phl_count "Patch: non-planar data - kernel least-squares NURBS" 5 "all five Patch cases reached the kernel's least-squares fit (no-hole reference, one hole, hole ring alone, two holes, overlapping negative control)"
phl_check "trimmed by the closed curve; the face's edge is within [0-9.e-]* of the curve" "a single closed non-planar curve keeps the original single-loop wording and trim (the no-hole reference, and the hole ring patched alone)"
phl_check "(9 x 9 net, worst data deviation [0-9.e-]* vs tolerance 0.001: met; the best-fit plane misses the data by 1.5) trimmed by the closed curve with 1 hole(s) cut by the other closed curve(s); the worst of the 2 trimmed edges is within [0-9.e-]* of its curve" "outer ring + one inner ring: the larger curve is the boundary, the smaller one a hole, 2 trimmed edges, fit within the 0.001 tolerance"
phl_check "with 2 hole(s) cut by the other closed curve(s); the worst of the 3 trimmed edges is within [0-9.e-]* of its curve" "outer ring + two inner rings: 2 holes, 3 trimmed edges"
# Numeric: every kernel-measured figure is within the document tolerance 0.001 (measured 0.00016 and 0.00041 here)
PHL_DEV1="$({ grep -o 'the worst of the 2 trimmed edges is within [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* within //')"
PHL_DEV2="$({ grep -o 'the worst of the 3 trimmed edges is within [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* within //')"
if phl_in_range "$PHL_DEV1" 0 0.001; then echo "ok   one-hole face: worst trimmed-edge-to-curve deviation $PHL_DEV1 <= 0.001 (measured by the kernel, 0.00016 when written)"; else echo "FAIL one-hole face deviation '$PHL_DEV1' not in 0..0.001"; fail=1; fi
if phl_in_range "$PHL_DEV2" 0 0.001; then echo "ok   two-hole face: worst trimmed-edge-to-curve deviation $PHL_DEV2 <= 0.001 (0.00041 when written)"; else echo "FAIL two-hole face deviation '$PHL_DEV2' not in 0..0.001"; fail=1; fi
# Topology of the single resulting face (exact, not tessellation): List counts
phl_check "  1 faces, 2 edges, open" "one hole: ONE face with two edges (outer loop + hole loop), not a second face"
phl_check "  1 faces, 3 edges, open" "two holes: ONE face with three edges (outer loop + 2 hole loops)"
phl_count "Object [0-9]*: valid" 3 "Check reports the two hole faces and the five-curve NetworkSrf face valid"
# Areas (tessellation-derived: ranges). Closed form for the annulus on z = 0.06 (x^2 - y^2) between r = 4.97 and r = 1.98 is about 71.3;
# the unholed reference measured 84.93, the hole ring alone 12.55 (closed form for r = 1.98: 12.6).
PHL_A_REF="$(phl_area 1)"; PHL_A_HOLE="$(phl_area 2)"; PHL_A_RING="$(phl_area 3)"; PHL_A_TWO="$(phl_area 4)"
if phl_in_range "$PHL_A_REF" 83 87; then echo "ok   no-hole reference area $PHL_A_REF in 83..87 (84.93 when written)"; else echo "FAIL no-hole reference area '$PHL_A_REF'"; fail=1; fi
if phl_in_range "$PHL_A_HOLE" 70 73; then echo "ok   outer ring with the centre hole: area $PHL_A_HOLE in 70..73 (71.43 when written; closed form of the annulus 71.3)"; else echo "FAIL one-hole area '$PHL_A_HOLE' not in 70..73"; fail=1; fi
if phl_in_range "$PHL_A_RING" 12 13.1; then echo "ok   the hole ring patched alone: area $PHL_A_RING in 12..13.1 (12.55 when written; closed form 12.6)"; else echo "FAIL hole-ring-alone area '$PHL_A_RING'"; fail=1; fi
if awk -v a="$PHL_A_REF" -v h="$PHL_A_HOLE" -v r="$PHL_A_RING" 'BEGIN { d = a - h; exit !(a != "" && h != "" && r != "" && d > 0.9 * r && d < 1.2 * r) }'; then echo "ok   the hole really removes area: unholed minus holed ($PHL_A_REF - $PHL_A_HOLE) is within 0.9..1.2 x the hole ring's own patch area $PHL_A_RING"; else echo "FAIL hole area removed is not about the hole ring's own area (ref $PHL_A_REF, holed $PHL_A_HOLE, ring $PHL_A_RING)"; fail=1; fi
if phl_in_range "$PHL_A_TWO" 73 78; then echo "ok   outer ring with two holes (r = 1.2 at y = +-2.5): area $PHL_A_TWO in 73..78 (75.72 when written; about 74.3 closed form for the ideal saddle minus two discs)"; else echo "FAIL two-hole area '$PHL_A_TWO' not in 73..78"; fail=1; fi
# Negative control: a second ring that crosses the outer one is reported and the surface stays untrimmed
phl_check "Patch: closed curve 2 is not wholly inside the outer boundary; keeping the untrimmed fitted surface" "a second closed curve crossing the outer one is refused as a hole with the reason printed"
phl_check "untrimmed, spanning the data's extent" "...and the fitted surface is returned untrimmed (the old behavior for that input)"

# NetworkSrf through FIVE curves (same script, case 3): the command used to keep only the
# first 4 curves. Now the curves are chained into a closed loop (any order or direction;
# here scrambled, two drawn backwards), joined, fitted by the kernel's least-squares
# NurbsSurface::FitPatch and trimmed by the joined loop: ONE face. It is approximate (not an
# interpolating Coons patch) and says so, printing the measured deviations.
phl_check "NetworkSrf: 5 curves chained into a closed loop; kernel least-squares NURBS patch ([0-9]* x [0-9]* net, worst deviation from the curves [0-9.e-]* vs tolerance 0.001: met) trimmed by the joined loop, trimmed edge within [0-9.e-]* of the loop (approximate: fitted through the boundary samples, not an interpolating Coons patch)" "NetworkSrf of five scrambled/reversed pieces of the saddle ring chains, joins, fits within the 0.001 tolerance and trims, and labels itself approximate"
PHL_NW_FIT="$({ grep -o 'worst deviation from the curves [0-9.e-]*' <<<"$PHL_OUT" || true; } | sed 's/.* curves //')"
PHL_NW_EDGE="$({ grep -o 'trimmed edge within [0-9.e-]* of the loop' <<<"$PHL_OUT" || true; } | sed 's/trimmed edge within //; s/ of the loop//')"
if phl_in_range "$PHL_NW_FIT" 0 0.001; then echo "ok   five-curve NetworkSrf: fit deviation from the curves $PHL_NW_FIT <= 0.001 (0.00018 when written)"; else echo "FAIL five-curve NetworkSrf fit deviation '$PHL_NW_FIT'"; fail=1; fi
if phl_in_range "$PHL_NW_EDGE" 0 0.001; then echo "ok   five-curve NetworkSrf: trimmed edge within $PHL_NW_EDGE of the loop <= 0.001 (0.00017 when written)"; else echo "FAIL five-curve NetworkSrf edge deviation '$PHL_NW_EDGE'"; fail=1; fi
phl_check "  1 faces, 1 edges, open" "the five-curve NetworkSrf is ONE face bounded by ONE joined edge (not 5 edges, not the first 4 curves only)"
PHL_A_NW="$(phl_area 5)"
if phl_in_range "$PHL_A_NW" 83 89; then echo "ok   five-curve NetworkSrf area $PHL_A_NW in 83..89 (86.01 when written; the single-closed-curve Patch of the same saddle ring measures 84.93)"; else echo "FAIL five-curve NetworkSrf area '$PHL_A_NW'"; fail=1; fi
phl_check "NetworkSrf: 5 curves could not be fitted (the 5 curves do not close into a loop within the document tolerance 0.001 (largest corner gap 0.5)); using the first 4 curves only" "five curves open by 0.5 (> tolerance) are NOT silently fitted: the measured gap is the printed reason and the old first-4 behavior runs"

# DXF importer coverage (File I/O > DXF): SOLID/TRACE, polygon-mesh POLYLINE,
# SOLID/3DFACE inside a BLOCK, edge-type (LINE/ARC) HATCH boundaries and HATCH
# islands (outer loop plus holes).
# Before this pass each was silently dropped on open: SOLID/TRACE had no case
# in DxfImporter::Entity at all, a POLYLINE with the polygon-mesh flag (70 bit
# 16) went straight to "skipped", a 3DFACE inside a BLOCK was deferred to the
# end-of-file per-layer mesh flush and so never reached Insert()'s placement
# transform (the block's instances came back empty), and a HATCH whose
# boundary is a chain of LINE/ARC edges (92 without bit 0x2 - what AutoCAD
# writes when the boundary was picked from separate objects) was skipped.
# A HATCH with more than one boundary path (islands/holes, group 91 > 1) was
# skipped too.
# The fixtures are hand-written (tests/dxf_solid_polymesh_fixture.dxf,
# dxf_solid_block_fixture.dxf, dxf_hatch_edges_fixture.dxf) with every
# expected number derived by hand, independent of Dino 8's own exporter;
# dxf_solid_hatch_script.txt then also exports to DXF and reopens that in a
# fresh document to compare before/after area and bounding box.
# Hatch/curve numbers that come from tessellation use tolerance ranges (the
# Windows CI tessellates slightly differently); mesh numbers are exact.
cp "$HERE/dxf_solid_polymesh_fixture.dxf" "$TMPW/dxf_solid_polymesh_fixture.dxf"
cp "$HERE/dxf_solid_block_fixture.dxf" "$TMPW/dxf_solid_block_fixture.dxf"
cp "$HERE/dxf_hatch_edges_fixture.dxf" "$TMPW/dxf_hatch_edges_fixture.dxf"
cp "$HERE/dxf_hatch_islands_solid_fixture.dxf" "$TMPW/dxf_hatch_islands_solid_fixture.dxf"
cp "$HERE/dxf_hatch_islands_pattern_plain_fixture.dxf" "$TMPW/dxf_hatch_islands_pattern_plain_fixture.dxf"
cp "$HERE/dxf_hatch_islands_pattern_hole_fixture.dxf" "$TMPW/dxf_hatch_islands_pattern_hole_fixture.dxf"
sed "s|@TMP@|$TMPW|g" "$HERE/dxf_solid_hatch_script.txt" > "$TMPW/dxf_solid_hatch_script.txt"
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  FIOX_OUT="$(timeout 900 "$BIN" --smoke 30 --script "$TMPW/dxf_solid_hatch_script.txt" 2>&1)" || { echo "$FIOX_OUT"; echo "FAIL: DXF SOLID/polymesh/hatch-edge script exited non-zero"; exit 1; }
else
  FIOX_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 30 --script "$TMPW/dxf_solid_hatch_script.txt" 2>&1)" || { echo "$FIOX_OUT"; echo "FAIL: DXF SOLID/polymesh/hatch-edge script exited non-zero"; exit 1; }
fi
# fiox_chk DESC GREP-O-PATTERN N ERE: the N-th (1-based) match of the -o
# pattern in the script output must match the ERE. The output order is
# fixed by the script (section 1 meshes, section 2 block, section 3 hatches).
fiox_chk() {
  local v
  v="$( (grep -o -- "$2" <<<"$FIOX_OUT" || true) | sed -n "${3}p" )"
  if grep -Eq -- "$4" <<<"$v"; then echo "ok   $1 ($v)"; else echo "FAIL $1 (got '$v', expected /$4/)"; near "$FIOX_OUT" "$2"; fail=1; fi
}
fiox_has() { if grep -qF -- "$1" <<<"$FIOX_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$FIOX_OUT" "$1"; fail=1; fi; }
FIOX_AREA='Area = [0-9.]*'
FIOX_BBOX='Bounding box min [^ ]* max [^ ]*'
# -- 1. SOLID + polygon meshes
fiox_has "DXF: 0 curves, 0 points, 3 meshes, 2 new layers; 1 unsupported entity skipped" "SOLID x3, a 3x3 polygon mesh and a closed 4x2 polygon mesh all import as meshes; the smooth-surface (group 75=6) polygon mesh is declined, not guessed at"
fiox_has "  9 vertices, 4 faces" "the 3x3 polygon mesh is 9 vertices / 2x2 = 4 quads"
fiox_has "  8 vertices, 4 faces" "the 4x2 polygon mesh closed in M (flag 1) wraps to 4 quads, not 3"
fiox_has "  11 vertices, 3 faces" "the three SOLIDs (quad, triangle, OCS-extruded quad) merge into one 3-face mesh"
fiox_chk "SOLID fills: total area = 50 (quad, stored 1-2-4-3 corner order) + 50 (triangle) + 12 (OCS quad)" "$FIOX_AREA" 1 '^Area = 112$'
fiox_chk "SOLID fills: bounding box, incl. the OCS extrusion (0,0,-1) mapping (x,y,z)->(-x,y,-z)" "$FIOX_BBOX" 1 '^Bounding box min -104,0,-2 max 30,10,0$'
fiox_chk "3x3 polygon mesh on plane z=(x+y)/10: area = 400*sqrt(1.02) = 403.98" "$FIOX_AREA" 2 '^Area = 40[34](\.[0-9]*)?$'
fiox_chk "3x3 polygon mesh bounding box" "$FIOX_BBOX" 2 '^Bounding box min 200,0,0 max 220,20,4$'
fiox_chk "closed 4x2 square tube (side 10, height 10): lateral area = 400" "$FIOX_AREA" 3 '^Area = 400$'
fiox_chk "closed 4x2 square tube bounding box" "$FIOX_BBOX" 3 '^Bounding box min 295,-5,0 max 305,5,10$'
fiox_chk "all three meshes: total area 112 + 403.98 + 400 = 916" "$FIOX_AREA" 4 '^Area = 91[56](\.[0-9]*)?$'
fiox_has "DXF: 0 curves, 0 points, 2 meshes, 2 new layers" "export -> reopen: the SOLID fills and the polygon meshes come back as 3DFACE meshes (one per layer)"
fiox_chk "round trip keeps the total mesh area (before == after)" "$FIOX_AREA" 5 '^Area = 91[56](\.[0-9]*)?$'
fiox_chk "round trip keeps the overall bounding box" "$FIOX_BBOX" 4 '^Bounding box min -104,-5,-2 max 305,20,10$'
# -- 2. SOLID + 3DFACE inside a BLOCK (2 instances: unscaled at 500,0,0; x2 scaled and rotated 90 deg at 600,0,0)
fiox_has "DXF: 0 curves, 0 points, 4 meshes, 2 block instances flattened" "a SOLID and a 3DFACE inside a BLOCK survive into both flattened INSERT instances (4 meshes, not 0)"
fiox_chk "block instances: area = (4+2) + (4+2)*2^2 = 30" "$FIOX_AREA" 6 '^Area = 30$'
fiox_chk "block instances: bounding box (instance 2 scaled x2, rotated 90 deg about its insert point)" "$FIOX_BBOX" 5 '^Bounding box min 500,0,0 max 600,4,4$'
# -- 3. edge-type HATCH boundaries
fiox_has "DXF: 0 curves, 0 points, 0 meshes, 4 hatches, 1 new layer; 2 unsupported entities skipped" "4 edge-boundary HATCHes import (3 solid + 1 pattern); the elliptic-arc-edge and the open-chain hatch are declined"
fiox_chk "hatch A (square + semicircle, LINE/ARC/LINE/LINE edges): area = 100 + 12.5*pi = 139.27" "$FIOX_AREA" 7 '^Area = (138\.[5-9]|139\.[0-3])[0-9]*$'
fiox_chk "hatch A bounding box (arc tessellated: max x ~15)" "$FIOX_BBOX" 6 '^Bounding box min 0,0,0 max 1[45](\.[0-9]*)?,10,0$'
fiox_chk "hatch B (shuffled, two edges stored reversed): area = 200" "$FIOX_AREA" 8 '^Area = 200$'
fiox_chk "hatch B bounding box" "$FIOX_BBOX" 7 '^Bounding box min 100,0,0 max 120,10,0$'
fiox_chk "hatch C (disc from a ccw AND a clockwise 73=0 arc edge): area = 16*pi = 50.27" "$FIOX_AREA" 9 '^Area = (49\.[5-9]|50\.[0-3])[0-9]*$'
fiox_chk "hatch C bounding box = the full disc (a wrong cw-arc sweep would collapse one half)" "$FIOX_BBOX" 8 '^Bounding box min 19[5-6](\.[0-9]*)?,-[34](\.[0-9]*)?,0 max 20[34](\.[0-9]*)?,[34](\.[0-9]*)?,0$'
fiox_chk "all three solid hatches: 139.27 + 200 + 50.27 = 389.54" "$FIOX_AREA" 10 '^Area = (388\.[5-9]|389\.[0-9]|390)[0-9]*$'
fiox_chk "pattern hatch D over a 30x20 line-edge loop: its hatch lines reach the far corner of the loop (x 330, y 20)" "$FIOX_BBOX" 9 '^Bounding box min 0,-[34](\.[0-9]*)?,0 max 330,20,0$'
fiox_has "DXF: 36 curves, 0 points, 0 meshes, 3 hatches, 1 new layer" "export -> reopen: the 3 solid hatches round-trip as real HATCH entities (the pattern hatch's lines return as 36 curves)"
fiox_chk "round trip keeps the solid-hatch area (before 389.5 / after within 1%)" "$FIOX_AREA" 11 '^Area = (38[5-9]|390)(\.[0-9]*)?$'
# -- 4. HATCH islands (several boundary paths: one outer loop plus holes)
fiox_has "DXF: 0 curves, 0 points, 0 meshes, 1 hatch, 1 new layer; 2 unsupported entities skipped" "islands: the 100x100 solid hatch with a polyline hole and an edge-type circular hole imports; the hole that pokes out of its outer loop and the two overlapping holes are declined, not filled wrongly"
fiox_chk "islands: solid fill area = 10000 - 400 (20x20 polyline hole) - 314.16 (r 10 circle hole) = 9285.84" "$FIOX_AREA" 12 '^Area = 928[0-9](\.[0-9]*)?$'
fiox_chk "islands: the filled face spans the full outer loop" "$FIOX_BBOX" 10 '^Bounding box min 0,0,0 max 100,100,0$'
fiox_has "DXF: 0 curves, 0 points, 0 meshes, 1 hatch, 1 new layer" "islands: export -> reopen: the holed solid fill is written as ONE HATCH with three boundary paths and read back as one hatch"
fiox_chk "islands: round trip keeps the holes (area after ~ area before 9285.84; without the holes it would be 10000)" "$FIOX_AREA" 13 '^Area = 928[0-9](\.[0-9]*)?$'
fiox_has "(113 objects)" "islands: ANSI31 over the plain 100x100 loop makes 113 hatch lines"
fiox_has "(170 objects)" "islands: the same pattern with a centred 50x50 hole makes 170 pieces (every line crossing the hole is split in two)"
FIOX_LEN_PLAIN="$( (grep -o 'Total length = [0-9.]*' <<<"$FIOX_OUT" || true) | sed -n 1p | sed 's/.*= //')"
FIOX_LEN_HOLE="$( (grep -o 'Total length = [0-9.]*' <<<"$FIOX_OUT" || true) | sed -n 2p | sed 's/.*= //')"
if awk -v a="${FIOX_LEN_PLAIN:-0}" -v b="${FIOX_LEN_HOLE:-0}" 'BEGIN { r = (a > 0) ? b / a : 0; exit !(a > 7900 && a < 8100 && r > 0.745 && r < 0.755) }'; then
  echo "ok   islands: hatch-line length with the 50x50 hole is 75% of the plain one, as the area ratio demands (plain $FIOX_LEN_PLAIN, holed $FIOX_LEN_HOLE)"
else
  echo "FAIL islands: hatch-line length ratio (plain '$FIOX_LEN_PLAIN', holed '$FIOX_LEN_HOLE', expected ~8000 and 0.75)"; near "$FIOX_OUT" "Total length = "; fail=1
fi

# SR: exact revolved-solid editing (solidsrev_script.txt) - closes two more
# sub-gaps of "Solid editing with B-rep results (booleans, fillet, shell,
# offset)": OffsetSrf Solid=Yes on a plain capped cylinder (the hollow wall
# between the original and the offset, two shells of one Brep) and OffsetSrf /
# Shell on a plain capped cone and cone frustum (the (radius, height) profile
# is offset with sharp corners and revolved: every face an exact revolved
# surface). All of these used to give meshes. Every case is bracketed by an
# SRBEGIN_<name> marker; srblock slices the app output into that case.
# Volumes are read from the display mesh, so the ranges carry that tessellation
# error (measured 0.05-0.15% low here; +-0.6% allowed for other platforms);
# face/edge counts and "closed solid" are topological, so those are exact.
# ---------------------------------------------------------------------------
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SROUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/solidsrev_script.txt" 2>&1)" || { echo "$SROUT"; echo "FAIL: solidsrev script exited non-zero"; exit 1; }
else
  SROUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/solidsrev_script.txt" 2>&1)" || { echo "$SROUT"; echo "FAIL: solidsrev script exited non-zero"; exit 1; }
fi
srblock() { awk -v name="$1" '$0 ~ ("Unknown command: SRBEGIN_" name "$") { on = 1; next } on && /Unknown command: SRBEGIN_|Unknown command: SREND/ { exit } on { print }' <<<"$SROUT"; }
srcheck() { local blk; blk="$(srblock "$1")"; if grep -q -- "$2" <<<"$blk"; then echo "ok   $3"; else echo "FAIL $3"; echo "     expected: $2"; grep -E "^history: (Shell|Offset|Object|  [0-9]|Volume|!)" <<<"$blk" | head -8 | sed 's/^/     actual:   /' || true; fail=1; fi; }
# srvol NAME MIN MAX DESC: the case's last "Volume = V" must lie in [MIN, MAX]
srvol() {
  local blk v; blk="$(srblock "$1")"
  v="$(grep -E "^history: Volume = " <<<"$blk" | tail -1 | sed -E 's/^history: Volume = ([0-9.eE+-]+).*/\1/' || true)"
  if [ -n "$v" ] && awk -v v="$v" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then echo "ok   $4 (Volume $v in [$2, $3])"; else echo "FAIL $4 (Volume '${v:-none}' not in [$2, $3])"; fail=1; fi
}
# --- OffsetSrf Solid=Yes on a plain cylinder
srcheck O_cyl_solid_out "OffsetSrf: distance 1, 1 object(s), solid, 1 exact B-rep" "cylinder Solid=Yes is an exact B-rep (before: a 13420-triangle mesh, reason 'planar-only B-rep boolean')"
srcheck O_cyl_solid_out "(polysurface)" "...a polysurface"
srcheck O_cyl_solid_out "6 faces, 6 edges, closed solid" "...6 faces (outer 3 + reversed inner 3), a closed solid"
srvol O_cyl_solid_out 912 922 "cylinder r5 h20 Solid=Yes +1: Volume = pi*(36*22 - 25*20) = 917.35"
srcheck O_cyl_solid_out "Object 2: valid" "...and Check reports the result valid"
srcheck O_cyl_solid_out "0 bad object(s) selected" "...SelBadObjects selects nothing"
srcheck O_cyl_solid_in "solid, 1 exact B-rep" "Solid=Yes inward (the offset cylinder is the inner shell) is exact too"
srcheck O_cyl_solid_in "6 faces, 6 edges, closed solid" "...6 faces, closed solid"
srvol O_cyl_solid_in 662 670 "cylinder Solid=Yes -1: Volume = pi*(25*20 - 16*18) = 666.0"
srcheck O_cyl_solid_in "Object 2: valid" "...valid"
srcheck O_cyl_plain "3 faces, 3 edges, closed solid" "control: Solid=No on a cylinder is still the single exact 3-face cylinder"
srvol O_cyl_plain 2473 2503 "control: grown cylinder Volume = pi*36*22 = 2488.1"
srcheck O_cyl_solid_collapse "exact B-rep offset not used (the cylinder would collapse at that offset)" "shrinking past the radius: exact refused WITH the reason"
srcheck O_cyl_solid_collapse "(mesh)" "...and the mesh offset runs"
srcheck O_cyl_solid_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
# --- OffsetSrf on a plain cone / frustum
srcheck O_cone "OffsetSrf: distance 1, 1 object(s), 1 exact B-rep" "cone offset is exact (before: a mesh)"
srcheck O_cone "2 faces, 3 edges, closed solid" "...the offset is again a 2-face cone"
srvol O_cone 603.5 610.5 "cone r5 h10 +1 = cone r6.618 h13.236: Volume = 607.08"
srcheck O_cone "Object 2: valid" "...valid"
srcheck O_cone_solid "solid, 1 exact B-rep" "cone Solid=Yes is exact"
srcheck O_cone_solid "4 faces, 6 edges, closed solid" "...4 faces (outer 2 + inner 2), closed solid"
srvol O_cone_solid 343 347.5 "cone Solid=Yes hollow wall Volume = 607.08 - 261.80 = 345.28"
srcheck O_cone_solid "Object 2: valid" "...valid"
srcheck O_tcone "1 exact B-rep" "frustum offset is exact"
srcheck O_tcone "3 faces, 5 edges, closed solid" "...3 faces, closed solid"
srvol O_tcone 962 974 "frustum r5->r3 h10 +1: Volume = 968.05"
srcheck O_tcone "Object 2: valid" "...valid"
srcheck O_tcone_solid_in "solid, 1 exact B-rep" "frustum Solid=Yes inward is exact"
srcheck O_tcone_solid_in "6 faces, 10 edges, closed solid" "...6 faces, closed solid"
srvol O_tcone_solid_in 282.8 286.3 "frustum hollow wall Volume = 513.13 - 228.58 = 284.55"
srcheck O_tcone_solid_in "Object 2: valid" "...valid"
srcheck O_cone_collapse "exact B-rep offset not used (the cone would collapse or self-intersect at that offset)" "shrinking a cone past its axial inradius: exact refused WITH the reason"
srcheck O_cone_exactno "(mesh)" "old behaviour reachable: Exact=No keeps the mesh offset"
# --- Shell of a plain cone / frustum
srcheck S_cone_closed "Shell: thickness 1, closed, exact B-rep" "cone closed shell is exact (before: a mesh)"
srcheck S_cone_closed "4 faces, 6 edges, closed solid" "...4 faces (outer 2 + inner 2), closed solid"
srvol S_cone_closed 179.5 182 "hollow cone Volume = 261.80 - 81.02 = 180.78"
srcheck S_cone_closed "Object 2: valid" "...valid"
srcheck S_cone_cap "open (1 face(s) removed), exact B-rep" "cone with its flat cap removed is an exact open cup"
srcheck S_cone_cap "3 faces, 5 edges, closed solid" "...3 faces (outer wall, inner wall, rim annulus), closed solid"
srvol S_cone_cap 138.3 140.3 "cone cup Volume = 139.28"
srcheck S_cone_cap "Object 2: valid" "...valid"
srcheck S_cone_wall "exact B-rep shell not used (only one flat cap of a cone can be removed exactly" "removing the cone's WALL: no exact construction, reason printed, mesh kept"
srcheck S_cone_wall "(mesh)" "...a mesh"
srcheck S_cone_thick "exact B-rep shell not used (the wall thickness is too large for this cone)" "a wall as thick as the cone: refused WITH the reason"
srcheck S_tcone_closed "Shell: thickness 1, closed, exact B-rep" "frustum closed shell is exact"
srcheck S_tcone_closed "6 faces, 10 edges, closed solid" "...6 faces, closed solid"
srvol S_tcone_closed 282.8 286.3 "hollow frustum Volume = 284.55"
srcheck S_tcone_closed "Object 2: valid" "...valid"
srcheck S_tcone_top "open (1 face(s) removed), exact B-rep" "frustum with the small (top) cap removed is an exact cup"
srcheck S_tcone_top "5 faces, 9 edges, closed solid" "...5 faces, closed solid"
srvol S_tcone_top 269.2 272.7 "frustum top-open cup Volume = 270.94"
srcheck S_tcone_top "Object 2: valid" "...valid"
srcheck S_tcone_bottom "open (1 face(s) removed), exact B-rep" "frustum with the big (bottom) cap removed is an exact cup"
srcheck S_tcone_bottom "5 faces, 9 edges, closed solid" "...5 faces, closed solid"
srvol S_tcone_bottom 235.7 238.8 "frustum bottom-open cup Volume = 237.24"
srcheck S_tcone_bottom "Object 2: valid" "...valid"
srcheck S_cone_exactno "(mesh)" "old behaviour reachable: Exact=No gives the mesh shell"
# --- ChamferEdge on the rim of a plain cone / frustum
srcheck C_tcone_bottom "replaced with an exact chamfer (radius 1; exact cone on the cylinder rim" "frustum bottom-rim chamfer is an exact revolved bevel (before: the approximate mesh fallback)"
srcheck C_tcone_bottom "(polysurface)" "...a polysurface"
srcheck C_tcone_bottom "4 faces, 7 edges, closed solid" "...4 faces (cap, bevel cone, wall, top cap), 7 edges, closed solid"
srvol C_tcone_bottom 496 501.5 "frustum r5->r3 h10 with a 1x1 bottom bevel: Volume = 498.95"
srcheck C_tcone_bottom "Object 1: valid" "...Check reports it valid"
srcheck C_tcone_top "replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "frustum top-rim chamfer with Distance2 (wall 1, cap 2) is exact: the two distances are honoured"
srcheck C_tcone_top "4 faces, 7 edges, closed solid" "...4 faces, closed solid"
srvol C_tcone_top 495.4 501.3 "frustum top bevel wall 1 / cap 2: Volume = 498.35"
srcheck C_tcone_top "Object 1: valid" "...valid"
srcheck C_cone_rim "replaced with an exact chamfer (distance1 1, distance2 2; exact cone on the cylinder rim" "plain cone rim chamfer with Distance2 is exact"
srcheck C_cone_rim "3 faces, 5 edges, closed solid" "...3 faces, closed solid"
srvol C_cone_rim 236.9 239.7 "cone r5 h10 rim bevel wall 1 / cap 2: Volume = 238.28"
srcheck C_cone_rim "Object 1: valid" "...valid"
srcheck C_cone_toobig "cone-rim attempt: a chamfer distance consumes the whole wall or cap" "a cap distance larger than the cap: refused WITH the cone-rim reason in the diagnostic"
srcheck C_cone_toobig "2 faces, 2 edges, closed solid" "...and the cone is left untouched"
if grep -q "^FAIL" <<<"$SROUT"; then echo "FAIL solidsrev script reported an in-script FAIL"; fail=1; fi

# --- SBX: ToSubD on a closed Brep box (sbx_script.txt) -------------------------
# MeshFromSelection's exact path (SubD::FromBrep) used to count every Brep it
# accepted as "verified" with worst deviation 0.000000 WITHOUT measuring, and
# FromBrep creases only naked edges, so a closed box became a 6-face cage with
# 0 creases whose Catmull-Clark limit surface is a rounded blob (ToNURBS
# volume 327.1 instead of 1000). The sharp Brep edges (dihedral > 35 degrees)
# are now creased and the limit surface is measured against the Brep.
if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
  SBX_OUT="$(timeout 900 "$BIN" --smoke 60 --script "$HERE/sbx_script.txt" 2>&1)" || { echo "$SBX_OUT"; echo "FAIL: sbx script exited non-zero"; exit 1; }
else
  SBX_OUT="$(timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$HERE/sbx_script.txt" 2>&1)" || { echo "$SBX_OUT"; echo "FAIL: sbx script exited non-zero"; exit 1; }
fi
sbxcheck() { if grep -q -- "$1" <<<"$SBX_OUT"; then echo "ok   $2"; else echo "FAIL $2"; near "$SBX_OUT" "$1"; fail=1; fi; }
# The first ToSubD line is the box's, the last is the sphere's (negative control).
SBX_BOX_LINE="$(grep -m1 "^history: ToSubD: created" <<<"$SBX_OUT" || true)"
SBX_SPH_LINE="$(grep "^history: ToSubD: created" <<<"$SBX_OUT" | tail -n 1 || true)"
SBX_BOX_VERIFIED="$(grep -o "([0-9]* of 1 limit-surface-fidelity" <<<"$SBX_BOX_LINE" | grep -o "[0-9]*" | head -n 1 || true)"
SBX_BOX_DEV="$(grep -o "worst measured deviation [0-9.]*" <<<"$SBX_BOX_LINE" | grep -o "[0-9.]*$" || true)"
# (1) the printed fidelity claim is consistent with the measured number: "1 of 1"
# only when the deviation is within the printed 0.001 tolerance, "0 of 1" otherwise.
if [ -n "$SBX_BOX_DEV" ] && [ -n "$SBX_BOX_VERIFIED" ] && awk -v d="$SBX_BOX_DEV" -v v="$SBX_BOX_VERIFIED" 'BEGIN{exit !((v==1 && d<=0.001) || (v==0 && d>0.001))}'; then
  echo "ok   sbx: the box's printed fidelity claim ($SBX_BOX_VERIFIED of 1, deviation $SBX_BOX_DEV) is consistent with the measured deviation vs tolerance 0.001"
else
  echo "FAIL sbx: the box's fidelity line is inconsistent or unparseable: $SBX_BOX_LINE"; fail=1
fi
sbxcheck "ToSubD: created 1 object(s) (1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); exact Brep-face cage (no tessellation), 12 sharp edge(s) creased (dihedral above 35 degrees), deviation measured at [1-9][0-9]* exact limit-surface points" "ToSubD on a 10x10x10 Brep box reports 1 of 1 verified from MEASURED limit-surface samples (not an unconditional claim), within 0.001, with 12 sharp edges creased"
# (2) crease count: the cage's 12 box edges are creases (was 0 creases).
sbxcheck "6 faces, 12 edges, 8 vertices, 12 creases" "the box's SubD cage has 12 creases (was 0)"
sbxcheck "Crease edges: 12" "What reports the box SubD's 12 crease edges"
# (3) the limit surface, converted to a NURBS solid, is a box again: volume 1000
# (measured 1000.0; asserted 995..1005 - tessellation-derived numbers differ
# slightly across platforms). With the old uncreased cage this was 327.1.
sbxcheck "closed solid: yes, manifold" "ToNURBS of the creased box SubD is a closed manifold solid"
SBX_VOL="$(grep -o "Volume = [0-9.e+-]*" <<<"$SBX_OUT" | head -n 1 | awk '{print $3}' || true)"
if [ -n "$SBX_VOL" ] && awk -v a="$SBX_VOL" 'BEGIN{exit !(a>995 && a<1005)}'; then echo "ok   sbx: ToNURBS of the converted 10x10x10 box encloses $SBX_VOL (true 1000, asserted 995..1005; the uncreased cage gave 327.1)"; else echo "FAIL sbx: ToNURBS volume of the converted box is '$SBX_VOL' (expected 995..1005)"; fail=1; fi
SBX_NVOL="$(grep -c "Volume = " <<<"$SBX_OUT" || true)"
if [ "$SBX_NVOL" = "1" ]; then echo "ok   sbx: exactly one Volume line was printed (the NURBS solid's)"; else echo "FAIL sbx: expected exactly one Volume line, got $SBX_NVOL"; fail=1; fi
# (4) negative control: a smooth shape keeps its existing tessellate-and-verify figure.
if grep -q "(1 of 1 limit-surface-fidelity verified within tolerance 0.001000, worst measured deviation 0\.000[0-9]*); cage interpolated onto the Brep surface (limit surface passes through every cage vertex: [0-9]* iteration(s), residual 0\.0000[0-9]*), 0 feature edge(s) creased" <<<"$SBX_SPH_LINE" && ! grep -q "exact Brep-face cage" <<<"$SBX_SPH_LINE"; then echo "ok   sbx: Sphere ToSubD still reports its tessellate-and-verify figure (1 of 1, 0.000x, 0 feature edges) and does not take the exact-cage path"; else echo "FAIL sbx: Sphere ToSubD line changed: $SBX_SPH_LINE"; fail=1; fi
sbxcheck "18240 faces, 27360 edges, 9122 vertices, 0 creases" "the Sphere SubD is still the 96 x 96 grid cage with 0 creases"

# ---------------------------------------------------------------------------
# Construction history persists in the .3dm (HPS_; hps_save_script.txt +
# hps_reopen_script.txt). Document::HistoryRecords() is written as the document
# user string "Dino8.HistoryMeta" (object uuids on disk, remapped to the fresh
# ids on Open), so after Save -> New -> Open, and in a brand-new process, moving a
# source object rebuilds its dependents automatically (no UpdateHistory).
# Phase 1 builds + saves three documents (History Off = negative control; root
# curve deleted before Save = dangling source; the real chain, whose saved ids
# are NOT 1,2,3.. because a throw-away box was deleted first) and reopens the
# chain in-process; phase 2 is a fresh process that opens the files. Volumes and
# bounding boxes come from measured Volume / BoundingBox output, compared with a
# tolerance (the Windows CI tessellates the mesh offset/boolean slightly
# differently).
# ---------------------------------------------------------------------------
HPS_DIR="$TMPW/hps"
mkdir -p "$HPS_DIR"
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_save_script.txt" > "$HPS_DIR/hps_save_script.txt"
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_reopen_script.txt" > "$HPS_DIR/hps_reopen_script.txt"
hps_run() {  # hps_run <script>: one app launch, output on stdout
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 100 --script "$1" 2>&1
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 100 --script "$1" 2>&1
  fi
}
HPS_S="$(hps_run "$HPS_DIR/hps_save_script.txt")" || { echo "$HPS_S"; echo "FAIL: hps save script exited non-zero"; exit 1; }
HPS_R="$(hps_run "$HPS_DIR/hps_reopen_script.txt")" || { echo "$HPS_R"; echo "FAIL: hps reopen script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$HPS_S" || { echo "$HPS_S"; echo "FAIL: hps save script produced no smoke line"; fail=1; }
grep -q "^smoke:" <<<"$HPS_R" || { echo "$HPS_R"; echo "FAIL: hps reopen script produced no smoke line"; fail=1; }
hps_ok() { if [ "$1" = "1" ]; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }
# hps_vol <output> <n>: the n-th "Volume = X" value; hps_bb <output> <n>: the n-th bounding box as "x0,y0,z0,x1,y1,z1"
hps_vol() { { grep -oE 'Volume = [-0-9.e+]+' <<<"$1" || true; } | sed -n "${2}p" | sed 's/Volume = //'; }
hps_bb() { { grep -oE 'Bounding box min [^ ]+ max [^ ]+' <<<"$1" || true; } | sed -n "${2}p" | sed -E 's/Bounding box min ([^ ]+) max ([^ ]+)/\1,\2/'; }
# hps_closev <a> <b> <tol> / hps_closebb <a-list> <b-list> <tol>: prints 1 when every number is within tol
hps_closev() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ if (a==""||b=="") {print 0; exit} d=a-b; if(d<0)d=-d; print (d<=t)?1:0 }'; }
hps_closebb() { awk -v a="${1:-}" -v b="${2:-}" -v t="$3" 'BEGIN{ n=split(a,x,","); m=split(b,y,","); if(n!=6||m!=6){print 0; exit} for(i=1;i<=6;i++){d=x[i]-y[i]; if(d<0)d=-d; if(d>t){print 0; exit}} print 1 }'; }
hps_sh() { hps_ok "$(hps_closev "$(hps_vol "$1" "$2")" "$3" "$4")" "$5 (measured $(hps_vol "$1" "$2"), expected $3 +/- $4)"; }
hps_sb() { hps_ok "$(hps_closebb "$(hps_bb "$1" "$2")" "$3" "$4")" "$5 (measured $(hps_bb "$1" "$2"), expected $3)"; }
hps_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
hps_count() { local n; n="$(grep -cF -- "$2" <<<"$1" || true)"; if [ "$n" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4 (found $n, expected $3)"; near "$1" "$2"; fail=1; fi; }

# --- phase 1: the building process (3 documents, then the chain reopened in-process)
hps_count "$HPS_S" "Saved $HPS_DIR/hps_" 3 "HPS_save: the three documents (History Off, deleted source, the chain) were written"
hps_has "$HPS_S" "History recording: off. 0 object(s) with live construction history" "HPS_off: built with History Off, nothing is recorded"
hps_has "$HPS_S" "History recording: on. 2 object(s) with live construction history" "HPS_del: extrude + offset recorded before the root curve was deleted"
hps_has "$HPS_S" "object 3: Extrude <- 2  [distance=10" "HPS_on: before Save the ids are shifted (the throw-away box took id 1): extrude 3 <- curve 2"
hps_has "$HPS_S" "object 2: Extrude <- 1  [distance=10" "HPS_on: after New + Open the same records are back with REMAPPED ids (extrude 2 <- curve 1)"
hps_has "$HPS_S" "object 7: BooleanIntersection <- 5,6  [operation=intersection]" "HPS_on: the two-source boolean record came back with both sources remapped (5,6) and its operation"
hps_count "$HPS_S" "History recording: on. 4 object(s) with live construction history:" 2 "HPS_on: the History report lists 4 records both before Save and after the in-process reopen"
# Volume order in phase 1: 1 off(1728) 2 del(1728) 3 on id4 before save(1728) 4 id8 before save(250), then after reopen 5 id3 after Move(1728) 6 id7 before(250) 7 id7 after Move(500)
hps_sh "$HPS_S" 3 1728 1 "HPS_on before Save: the offset solid (box 12^3) has the expected volume"
hps_sh "$HPS_S" 4 250 1 "HPS_on before Save: the boolean intersection volume"
hps_sb "$HPS_S" 1 "-1,-1,-1,11,11,11" 0.05 "HPS_on before Save: offset solid bounding box"
hps_sb "$HPS_S" 2 "-1,-1,-1,11,11,11" 0.05 "HPS_on after New + Open (before any edit): the SAME bounding box as before Save"
hps_sb "$HPS_S" 3 "4,-1,-1,16,11,11" 0.05 "HPS_on after reopen, curve moved +5 in X: the offset solid FOLLOWED (bbox moved with no UpdateHistory)"
hps_sh "$HPS_S" 5 1728 1 "HPS_on after reopen + Move: the rebuilt offset solid keeps its volume"
hps_sh "$HPS_S" 6 250 1 "HPS_on after reopen (before edit): boolean volume equals the value before Save"
hps_sh "$HPS_S" 7 500 2 "HPS_on after reopen, second source curve moved +5: the boolean rebuilt automatically (250 -> 500)"
hps_has "$HPS_S" "History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)" "HPS_on in-process reopen: automatic propagation line for the offset chain"
hps_has "$HPS_S" "History: source object(s) 4 changed - 2 dependent(s) re-evaluated (5,7)" "HPS_on in-process reopen: automatic propagation line for the boolean chain"

# --- phase 2: a FRESH process opens the files
hps_count "$HPS_R" "History recording: on. 4 object(s) with live construction history:" 1 "HPS_fresh: the records are read from the .3dm by a new process"
hps_has "$HPS_R" "object 5: Extrude <- 4  [distance=10" "HPS_fresh: remapped ids (second extrude 5 <- curve 4)"
hps_has "$HPS_R" "object 3: OffsetSrf <- 2  [distance=1, solid=no]" "HPS_fresh: numeric options survived (distance=1, solid=no)"
# Volumes in phase 2: 1 id3 before(1728) 2 after Scale 2x(5808) 3 after Undo(1728) 4 id7(250) 5 id7 after Move(500) 6 after Undo(250) 7 OFF(1728) 8 DEL before(1728) 9 DEL after UpdateHistory(1728)
hps_sb "$HPS_R" 1 "-1,-1,-1,11,11,11" 0.05 "HPS_fresh: opened offset solid bounding box"
hps_sb "$HPS_R" 2 "4,-1,-1,16,11,11" 0.05 "HPS_fresh: curve moved +5 in X, no UpdateHistory: the offset solid bounding box followed"
hps_sh "$HPS_R" 1 1728 1 "HPS_fresh: offset solid volume before any edit"
hps_sh "$HPS_R" 2 5808 6 "HPS_fresh: curve scaled 2x about (5,0,0): offset solid volume rebuilt (same value as the live-session test in history_auto_script.txt)"
hps_sh "$HPS_R" 3 1728 1 "HPS_fresh: Undo restores the offset solid (the rebuild is inside the edit's undo step)"
hps_sh "$HPS_R" 4 250 1 "HPS_fresh: boolean volume before the edit"
hps_sh "$HPS_R" 5 500 2 "HPS_fresh: second curve moved: the boolean rebuilt (250 -> 500)"
hps_sh "$HPS_R" 6 250 1 "HPS_fresh: Undo restores the boolean"
hps_count "$HPS_R" "History: source object(s)" 4 "HPS_fresh: exactly 4 automatic updates (Move, Scale, Move of the 2nd curve, and the Move after the SECOND Save/Open) - none for the controls"
hps_has "$HPS_R" "History: source object(s) 4 changed - 2 dependent(s) re-evaluated (5,7)" "HPS_fresh: boolean chain propagation line"
hps_sb "$HPS_R" 3 "4,4,-1,16,16,11" 0.05 "HPS_resave: records written from a LOADED document survive a second Save/New/Open (curve moved +5 in Y: bbox follows on top of the earlier +5 X)"
# negative control 1: saved with History Off
hps_has "$HPS_R" "History recording: on. 0 object(s) with live construction history" "HPS_off control: a document saved with History Off has no records to restore"
hps_sb "$HPS_R" 4 "-1,-1,-1,11,11,11" 0.05 "HPS_off control: the source curve was moved and NOTHING followed (bbox unchanged)"
hps_has "$HPS_R" "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry" "HPS_off control: UpdateHistory says it has nothing to re-evaluate"
hps_sb "$HPS_R" 5 "-1,-1,-1,11,11,11" 0.05 "HPS_off control: still unchanged after UpdateHistory"
hps_sh "$HPS_R" 7 1728 1 "HPS_off control: volume unchanged"
# negative control 2: the source curve was deleted before Save
hps_has "$HPS_R" "object 1: Extrude <- (deleted)" "HPS_del control: the extrude's record kept its slot but names its source as deleted"
hps_has "$HPS_R" "UpdateHistory: 0 object(s) re-evaluated from their source curve(s)' current geometry, 2 skipped" "HPS_del control: UpdateHistory re-evaluates nothing and reports 2 skipped"
hps_has "$HPS_R" "UpdateHistory: object 1 (Extrude) kept as it was: its source object was deleted before the file was saved" "HPS_del control: the reason is the deleted source"
hps_sb "$HPS_R" 6 "-1,-1,-1,11,11,11" 0.05 "HPS_del control: offset solid bounding box before UpdateHistory"
hps_sb "$HPS_R" 7 "-1,-1,-1,11,11,11" 0.05 "HPS_del control: ...and after UpdateHistory (geometry untouched)"
hps_sh "$HPS_R" 8 1728 1 "HPS_del control: volume before UpdateHistory"
hps_sh "$HPS_R" 9 1728 1 "HPS_del control: volume after UpdateHistory (unchanged)"

# --- part 3: Shell records history (hps_shell_script.txt). Plain Shell (closed solid,
# uniform thickness, no opened faces) hides its source and records {source,
# thickness}; the shell follows edits of the source, survives Save/New/Open and
# EditHistory thickness=..., and an opened-face Shell / History Off record nothing.
sed "s|@TMP@|$HPS_DIR|g" "$HERE/hps_shell_script.txt" > "$HPS_DIR/hps_shell_script.txt"
HPS_H="$(hps_run "$HPS_DIR/hps_shell_script.txt")" || { echo "$HPS_H"; echo "FAIL: hps shell script exited non-zero"; exit 1; }
grep -q "^smoke:" <<<"$HPS_H" || { echo "$HPS_H"; echo "FAIL: hps shell script produced no smoke line"; fail=1; }
# Volumes: 1 shell(1408) 2 source scaled 2x (6008) 3 after Undo(1408) 4 after reopen + EditHistory thickness=2 (2464)
#          5 curve->Extrude->Shell (1408) 6 same after the curve moved (1408) 7 History Off (1408) 8 opened-face Shell (1084)
# Bounding boxes: 1 shell (0..20) 2 source moved +5 X 3 reopened source moved +5 Y 4 extrude chain moved +7 X
hps_has "$HPS_H" "Shell: thickness 1, closed, exact B-rep, volume 1408" "HPS_shell: a plain Shell of a box still takes the exact B-rep path"
hps_has "$HPS_H" "object 2: Shell <- 1  [thickness=1]" "HPS_shell: with History On the Shell is recorded (source 1, thickness 1) and the source box is kept (hidden) not deleted"
hps_sh "$HPS_H" 1 1408 2 "HPS_shell: hollowed 20x20x10 box, wall 1 (4000 - 18*18*8)"
hps_sb "$HPS_H" 2 "5,0,0,25,20,10" 0.05 "HPS_shell: source box moved +5 in X, no UpdateHistory: the shell followed"
hps_sh "$HPS_H" 2 6008 6 "HPS_shell: source box scaled 2x: the shell was re-shelled with the same wall (40*40*20 - 38*38*18)"
hps_sh "$HPS_H" 3 1408 2 "HPS_shell: Undo restores the previous shell (the rebuild is in the edit's undo step)"
hps_has "$HPS_H" "History recording: on. 1 object(s) with live construction history:" "HPS_shell: the Shell record is read back from the .3dm after New + Open"
hps_sb "$HPS_H" 3 "5,5,0,25,25,10" 0.05 "HPS_shell: after Save/New/Open the shell follows its (reopened) source moved +5 in Y"
hps_has "$HPS_H" "EditHistory: object 2 (Shell): thickness 1 -> 2." "HPS_shell: EditHistory exposes and changes the recorded thickness"
hps_sh "$HPS_H" 4 2464 4 "HPS_shell: after EditHistory thickness=2 (4000 - 16*16*6)"
hps_has "$HPS_H" "Shell: object 2 - exact B-rep shell not used" "HPS_shell: curve -> Extrude -> Shell takes the mesh construction (the extrusion's faces are not recognised as planar) and says so, live and on rebuild"
hps_sh "$HPS_H" 5 1408 5 "HPS_shell: curve -> Extrude -> Shell (mesh path) volume before the edit"
hps_sb "$HPS_H" 4 "7,0,0,27,20,10" 0.05 "HPS_shell: source curve moved +7 in X: Extrude AND Shell followed (2-deep chain)"
hps_has "$HPS_H" "History: source object(s) 1 changed - 2 dependent(s) re-evaluated (2,3)" "HPS_shell: the chain propagation line names both dependents"
hps_sh "$HPS_H" 6 1408 5 "HPS_shell: ...and the mesh-path shell keeps its volume"
hps_has "$HPS_H" "History recording: off. 0 object(s) with live construction history" "HPS_shell control: Shell with History Off records nothing"
hps_sh "$HPS_H" 7 1408 2 "HPS_shell control: History Off Shell result unchanged from before"
hps_has "$HPS_H" "History recording: on. 0 object(s) with live construction history" "HPS_shell control: a Shell with an opened (clicked) face records nothing"
hps_sh "$HPS_H" 8 1084 2 "HPS_shell control: the opened-face Shell is the same exact open shell as before (volume 1084)"

# --- Tutorial video pipeline (tutorials/record.py, verify.py; docs/TUTORIALS.md).
# Records one real tutorial headless (the app's own ScreenCaptureToFile under
# Xvfb 1280x720, encoded with ffmpeg), then verifies the finished artifact from
# the files themselves: size, frame count, duration, resolution, non-blank
# frames (pixel variance, Python stdlib) and WebVTT validity/cue order.
# Skipped, loudly, where ffmpeg/ffprobe/python3 are missing or off Linux.
TUT_ID="04-extrude-revolve-vase"
TUT_OUT="$TMPW/tut_out"
if [ "$(uname -s)" = "Linux" ] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  TUT_SELF="$(python3 "$HERE/../tutorials/verify.py" --selftest 2>&1)" || true
  tut_has() { if grep -qF -- "$2" <<<"$1"; then echo "ok   $3"; else echo "FAIL $3"; near "$1" "$2"; fail=1; fi; }
  tut_has "$TUT_SELF" "TUT_selftest_flat_blank=1" "TUT_selftest: a flat frame is classified blank"
  tut_has "$TUT_SELF" "TUT_selftest_noisy_not_blank=1" "TUT_selftest: a textured frame is not blank"
  tut_has "$TUT_SELF" "TUT_selftest_good_vtt=1" "TUT_selftest: a valid WebVTT is accepted"
  tut_has "$TUT_SELF" "TUT_selftest_bad_order_rejected=1" "TUT_selftest: out-of-order cues are rejected"
  tut_has "$TUT_SELF" "TUT_selftest_no_header_rejected=1" "TUT_selftest: a file without the WEBVTT header is rejected"
  tut_has "$TUT_SELF" "TUT_selftest_too_long_rejected=1" "TUT_selftest: a cue running past the video end is rejected"
  TUT_REC="$(timeout 900 python3 "$HERE/../tutorials/record.py" --bin "$BIN" --id "$TUT_ID" --out "$TUT_OUT" 2>&1)" || { echo "$TUT_REC" | tail -20; echo "FAIL TUT_record: recorder exited non-zero"; fail=1; }
  tut_has "$TUT_REC" "record: $TUT_ID ->" "TUT_record: recorder reported the finished video"
  TUT_VER="$(python3 "$HERE/../tutorials/verify.py" "$TUT_OUT" "$TUT_ID" 2>&1)" || { echo "$TUT_VER" | tail -20; echo "FAIL TUT_verify: verifier crashed (no video produced?)"; fail=1; TUT_VER=""; }
  tut_val() { { grep "^$2=" <<<"$1" || true; } | head -1 | cut -d= -f2-; }
  TUT_BYTES="$(tut_val "$TUT_VER" TUT_video_bytes)"
  if [ -n "$TUT_BYTES" ] && [ "$TUT_BYTES" -gt 50000 ] && [ "$TUT_BYTES" -lt 40000000 ]; then echo "ok   TUT_size: video file is $TUT_BYTES bytes (plausible: 50 kB..40 MB)"; else echo "FAIL TUT_size: video file size '$TUT_BYTES' not in 50 kB..40 MB"; fail=1; fi
  TUT_PF="$(tut_val "$TUT_VER" TUT_probe_frames)"; TUT_EF="$(tut_val "$TUT_VER" TUT_expected_frames)"
  if [ -n "$TUT_PF" ] && [ "$TUT_PF" = "$TUT_EF" ]; then echo "ok   TUT_frames: decoded frame count $TUT_PF equals the count expected from tutorial.txt"; else echo "FAIL TUT_frames: decoded '$TUT_PF' != expected '$TUT_EF'"; fail=1; fi
  TUT_PD="$(tut_val "$TUT_VER" TUT_probe_duration)"; TUT_ED="$(tut_val "$TUT_VER" TUT_expected_duration)"
  if [ -n "$TUT_PD" ] && python3 -c "import sys; sys.exit(0 if abs(float('$TUT_PD')-float('$TUT_ED')) <= 0.2 else 1)"; then echo "ok   TUT_duration: container duration $TUT_PD s matches expected $TUT_ED s"; else echo "FAIL TUT_duration: '$TUT_PD' vs expected '$TUT_ED'"; fail=1; fi
  tut_has "$TUT_VER" "TUT_probe_size=1280x720" "TUT_size720: video is 1280x720"
  tut_has "$TUT_VER" "TUT_probe_fps=10/1" "TUT_fps: video is 10 fps"
  TUT_SAMP="$(tut_val "$TUT_VER" TUT_sampled_frames)"
  if [ -n "$TUT_SAMP" ] && [ "$TUT_SAMP" -ge 10 ]; then echo "ok   TUT_sample: $TUT_SAMP frames sampled for the variance check"; else echo "FAIL TUT_sample: only '$TUT_SAMP' frames could be sampled"; fail=1; fi
  tut_has "$TUT_VER" "TUT_blank_frames=0" "TUT_blank: no sampled frame is blank (luminance variance >= 4)"
  TUT_DIFF="$(tut_val "$TUT_VER" TUT_first_last_diff)"
  if [ -n "$TUT_DIFF" ] && python3 -c "import sys; sys.exit(0 if float('$TUT_DIFF') > 0.5 else 1)"; then echo "ok   TUT_progress: first and last sampled frames differ (mean abs diff $TUT_DIFF)"; else echo "FAIL TUT_progress: first and last frames are identical (diff '$TUT_DIFF')"; fail=1; fi
  tut_has "$TUT_VER" "TUT_vtt=ok" "TUT_vtt: captions are valid WebVTT with strictly increasing, non-overlapping cues inside the video"
  TUT_NC="$(tut_val "$TUT_VER" TUT_vtt_cues)"; TUT_XC="$(tut_val "$TUT_VER" TUT_expected_cues)"
  if [ -n "$TUT_NC" ] && [ "$TUT_NC" = "$TUT_XC" ] && [ "$TUT_NC" -ge 3 ]; then echo "ok   TUT_cues: $TUT_NC caption cues, one per #narrate: line"; else echo "FAIL TUT_cues: '$TUT_NC' cues vs expected '$TUT_XC'"; fail=1; fi
  TUT_TXT="$TUT_OUT/$TUT_ID/$TUT_ID.txt"
  if [ -s "$TUT_TXT" ]; then echo "ok   TUT_transcript: voice-over transcript written"; else echo "FAIL TUT_transcript: $TUT_TXT missing or empty"; fail=1; fi
  # The generated site lists every tutorial and is self-contained (no CDN/tracker).
  TUT_SITE_OUT="$(python3 "$HERE/../tutorials/build_site.py" 2>&1)" || { echo "$TUT_SITE_OUT"; echo "FAIL TUT_site: build_site.py failed"; fail=1; }
  tut_has "$TUT_SITE_OUT" "(10 tutorials)" "TUT_site: index.html built for all 10 tutorials"
  if [ -z "$({ grep -E 'src="https?://|href="https?://|<script' "$HERE/../tutorials/index.html" || true; })" ]; then echo "ok   TUT_site_selfcontained: index.html has no external URLs and no scripts"; else echo "FAIL TUT_site_selfcontained: index.html references an external URL or script"; fail=1; fi
else
  echo "skip TUT_*: tutorial pipeline checks need Linux with ffmpeg, ffprobe and python3 (see docs/TUTORIALS.md)"
fi

exit $fail
