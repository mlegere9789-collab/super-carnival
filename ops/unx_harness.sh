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
HERE="$(cd "$(dirname "$0")" && pwd)"
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
# ===========================================================================
# UNX_: IGES / STEP unit declaration on export and unit conversion on import.
# Oracles are independent of the importer: 1 in = 25.4 mm, 1 m = 1000 mm,
# 1 cm = 10 mm, 1 yd = 914.4 mm (published definitions) applied to a 10-unit
# line; hand-patched Global sections / unit entities; refusals with reasons.
# ===========================================================================
unx_ok()  { echo "ok   UNX_$1"; }
unx_bad() { echo "FAIL UNX_$1"; fail=1; }
UNXD="$TMPW/unx"
mkdir -p "$UNXD"
cat > "$UNXD/inch.lua" <<'LUA'
rs.UnitSystem(8)
LUA
cat > "$UNXD/gen.txt" <<EOS
RunScript $UNXD/inch.lua
Line 0,0,0 10,0,0
SelAll
Export $UNXD/in.igs
Export $UNXD/in.stp
New
Line 0,0,0 10,0,0
SelAll
Export $UNXD/mm.igs
Export $UNXD/mm.stp
EOS
unx_run() {
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 900 "$BIN" --smoke 120 --script "$1" 2>&1 || true
  else
    timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 120 --script "$1" 2>&1 || true
  fi
}
UNX_GEN="$(unx_run "$UNXD/gen.txt")"
for f in in.igs in.stp mm.igs mm.stp; do
  if [ -s "$UNXD/$f" ]; then unx_ok "export_wrote_$f"; else unx_bad "export_wrote_$f"; echo "$UNX_GEN" | tail -5; fi
done
# Export side: the file declares the DOCUMENT's unit (an inch document used to write millimetres).
if grep -q "CONVERSION_BASED_UNIT('INCH'" "$UNXD/in.stp" && grep -q "LENGTH_MEASURE(25.4)" "$UNXD/in.stp"; then unx_ok "step_export_from_inch_document_declares_INCH_25.4mm"; else unx_bad "step_export_from_inch_document_declares_INCH_25.4mm"; fi
if grep -q "SI_UNIT(.MILLI.,.METRE.)" "$UNXD/mm.stp" && ! grep -q "CONVERSION_BASED_UNIT" "$UNXD/mm.stp"; then unx_ok "step_export_from_mm_document_declares_millimetre_only"; else unx_bad "step_export_from_mm_document_declares_millimetre_only"; fi
if grep -q "(10.,0.,0.)\|(10,0,0)\|10\.,0\.,0\." "$UNXD/in.stp"; then unx_ok "step_export_keeps_document_coordinates_10_not_254"; else unx_bad "step_export_keeps_document_coordinates_10_not_254"; fi
python3 - "$UNXD" <<'PY'
import re, sys, os
d = sys.argv[1]
def glob(text):
    lines = text.split('\n'); g = ''
    for l in lines:
        if len(l) >= 73 and l[72] == 'G': g += l[:72].rstrip()
    return g
def patch_iges(src, dst, frm, to):
    text = open(os.path.join(d, src)).read()
    g = glob(text)
    if frm not in g:
        open(os.path.join(d, dst + '.PATCHFAIL'), 'w').write(g); return
    g = g.replace(frm, to, 1)
    out = []; done = False
    for l in text.split('\n'):
        if len(l) >= 73 and l[72] == 'G':
            if done: continue
            done = True
            for i in range(0, len(g), 72):
                out.append('%-72sG%7d' % (g[i:i+72], i // 72 + 1))
        else:
            out.append(l)
    open(os.path.join(d, dst), 'w').write('\n'.join(out))
g = glob(open(os.path.join(d, 'in.igs')).read())
open(os.path.join(d, 'in.igs.global'), 'w').write(g)
m = re.search(r',1\.0,\s*2,\s*2HMM,', glob(open(os.path.join(d, 'mm.igs')).read()))
base = m.group(0) if m else ',1.0,2,2HMM,'
patch_iges('mm.igs', 'm.igs', base, ',1.0,6,1HM,')
patch_iges('mm.igs', 'cm.igs', base, ',1.0,10,2HCM,')
patch_iges('mm.igs', 'yard.igs', base, ',1.0,3,4HYARD,')
patch_iges('mm.igs', 'mils.igs', base, ',1.0,8,4HMILS,')
patch_iges('mm.igs', 'furlong.igs', base, ',1.0,3,7HFURLONG,')
patch_iges('mm.igs', 'noflag.igs', base, ',1.0,,,')
t = open(os.path.join(d, 'mm.igs')).read()
open(os.path.join(d, 'trunc.igs'), 'w').write(t[:len(t) // 2])
s = open(os.path.join(d, 'mm.stp')).read()
unit = '(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.))'
assert unit in s, 'mm.stp has no standard millimetre LENGTH_UNIT'
def variant(name, repl, extra=''):
    t = s.replace(unit, repl, 1)
    t = t.replace('ENDSEC;\nEND-ISO', extra + 'ENDSEC;\nEND-ISO') if extra else t
    # the data section's ENDSEC is the last one
    open(os.path.join(d, name), 'w').write(t)
variant('m.stp', '(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT($,.METRE.))')
variant('gram.stp', '(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.GRAM.))')
variant('exa.stp', '(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.EXA.,.METRE.))')
variant('inch2.stp', "(CONVERSION_BASED_UNIT('INCH',#9001)LENGTH_UNIT()NAMED_UNIT(#9002))",
        '#9001=LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(25.4),#9003);\n#9002=DIMENSIONAL_EXPONENTS(1.,0.,0.,0.,0.,0.,0.);\n#9003=(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.));\n')
variant('zero.stp', "(CONVERSION_BASED_UNIT('INCH',#9001)LENGTH_UNIT()NAMED_UNIT(#9002))",
        '#9001=LENGTH_MEASURE_WITH_UNIT(LENGTH_MEASURE(0.),#9003);\n#9002=DIMENSIONAL_EXPONENTS(1.,0.,0.,0.,0.,0.,0.);\n#9003=(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.));\n')
# two different declared units: add a second context naming metres
variant('two.stp', unit, '#9101=(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT($,.METRE.));\n#9102=(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNIT_ASSIGNED_CONTEXT((#9101))REPRESENTATION_CONTEXT(\'a\',\'b\'));\n')
# no unit at all: the unit entity is replaced by an angle unit so the context lists no length
variant('nounit.stp', '(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.))')
open(os.path.join(d, 'trunc.stp'), 'w').write(s[:len(s) * 6 // 10])
PY
if ls "$UNXD"/*.PATCHFAIL >/dev/null 2>&1; then unx_bad "iges_global_patch_found_the_millimetre_declaration"; else unx_ok "iges_global_patch_found_the_millimetre_declaration"; fi
if grep -Eq ',1\.0,\s*1,\s*2HIN,' "$UNXD/in.igs.global"; then unx_ok "iges_export_from_inch_document_declares_flag_1_IN"; else unx_bad "iges_export_from_inch_document_declares_flag_1_IN"; fi

cat > "$UNXD/imp.txt" <<EOS
New
Open $UNXD/in.igs
SelAll
Length
New
Open $UNXD/in.stp
SelAll
Length
New
Open $UNXD/mm.igs
SelAll
Length
New
Open $UNXD/mm.stp
SelAll
Length
New
Open $UNXD/m.igs
SelAll
Length
New
Open $UNXD/cm.igs
SelAll
Length
New
Open $UNXD/yard.igs
SelAll
Length
New
Open $UNXD/mils.igs
SelAll
Length
New
Open $UNXD/furlong.igs
SelAll
Length
New
Open $UNXD/noflag.igs
SelAll
Length
New
Open $UNXD/m.stp
SelAll
Length
New
Open $UNXD/inch2.stp
SelAll
Length
New
Open $UNXD/nounit.stp
SelAll
Length
New
Open $UNXD/gram.stp
@expect_objects 0
New
Open $UNXD/exa.stp
@expect_objects 0
New
Open $UNXD/zero.stp
@expect_objects 0
New
Open $UNXD/two.stp
@expect_objects 0
New
Open $UNXD/trunc.igs
New
Open $UNXD/trunc.stp
New
RunScript $UNXD/inch.lua
Open $UNXD/in.stp
SelAll
Length
New
RunScript $UNXD/inch.lua
Open $UNXD/m.stp
SelAll
Length
New
RunScript $UNXD/inch.lua
Open $UNXD/in.igs
SelAll
Length
New
Line 0,0,0 1,0,0
SelAll
Length
EOS
UNX_OUT="$(unx_run "$UNXD/imp.txt")"
mapfile -t UNX_LEN < <(grep "^Total length = " <<<"$UNX_OUT" || true)
unx_len() {  # unx_len <index> <regex> <name>
  if [ "${#UNX_LEN[@]}" -gt "$1" ] && grep -Eq "$2" <<<"${UNX_LEN[$1]}"; then unx_ok "$3"; else unx_bad "$3 (got: ${UNX_LEN[$1]:-<none>})"; fi
}
unx_len 0 '= 254 Millimeters' "iges_declared_in_inches_10_in_becomes_254_mm"
unx_len 1 '= 254 Millimeters' "step_declared_in_inches_10_in_becomes_254_mm"
unx_len 2 '= 10 Millimeters' "iges_declared_mm_into_mm_document_is_untouched"
unx_len 3 '= 10 Millimeters' "step_declared_mm_into_mm_document_is_untouched"
unx_len 4 '= 10000 Millimeters' "iges_flag_6_metres_10_m_becomes_10000_mm"
unx_len 5 '= 100 Millimeters' "iges_flag_10_centimetres_10_cm_becomes_100_mm"
unx_len 6 '= 9144 Millimeters' "iges_flag_3_YARD_10_yd_becomes_9144_mm"
unx_len 7 '= 10 Millimeters' "negative_control_iges_flag_8_mils_is_not_converted"
unx_len 8 '= 10 Millimeters' "negative_control_iges_flag_3_FURLONG_is_not_converted"
unx_len 9 '= 10 Millimeters' "negative_control_iges_with_no_units_flag_is_not_converted"
unx_len 10 '= 10000 Millimeters' "step_si_metre_10_m_becomes_10000_mm"
unx_len 11 '= 254 Millimeters' "step_hand_built_conversion_based_inch_becomes_254_mm"
unx_len 12 '= 10 Millimeters' "negative_control_step_with_no_length_unit_is_not_converted"
if grep -q "units flag 8 is not supported" <<<"$UNX_OUT"; then unx_ok "iges_mils_refusal_names_flag_8_in_the_import_summary"; else unx_bad "iges_mils_refusal_names_flag_8_in_the_import_summary"; fi
if grep -q "units flag 3 (FURLONG) is not supported" <<<"$UNX_OUT"; then unx_ok "iges_furlong_refusal_names_the_unit"; else unx_bad "iges_furlong_refusal_names_the_unit"; fi
if grep -q "units flag 1 -> document Millimeters, scaled x25.4" <<<"$UNX_OUT"; then unx_ok "iges_summary_reports_the_conversion_factor_25.4"; else unx_bad "iges_summary_reports_the_conversion_factor_25.4"; fi
if grep -q "file length unit 1 m -> document Millimeters, scaled x1000" <<<"$UNX_OUT"; then unx_ok "step_summary_reports_the_metre_factor_1000"; else unx_bad "step_summary_reports_the_metre_factor_1000"; fi
if grep -q "Unsupported STEP length unit (SI length unit .GRAM. is not a metre)" <<<"$UNX_OUT"; then unx_ok "step_non_metre_length_unit_refused_with_reason"; else unx_bad "step_non_metre_length_unit_refused_with_reason"; fi
if grep -q "Unsupported STEP length unit (SI prefix .EXA. is not supported)" <<<"$UNX_OUT"; then unx_ok "step_unknown_SI_prefix_refused_with_reason"; else unx_bad "step_unknown_SI_prefix_refused_with_reason"; fi
if grep -q "Unsupported STEP length unit (CONVERSION_BASED_UNIT conversion value is not a finite positive number)" <<<"$UNX_OUT"; then unx_ok "step_zero_conversion_factor_refused_with_reason"; else unx_bad "step_zero_conversion_factor_refused_with_reason"; fi
if grep -q "Unsupported STEP length unit (the file declares two different length units)" <<<"$UNX_OUT"; then unx_ok "step_two_different_units_refused_with_reason"; else unx_bad "step_two_different_units_refused_with_reason"; fi
if [ "$(grep -c '^ok   expect_objects 0' <<<"$UNX_OUT")" -ge 4 ]; then unx_ok "all_four_refused_step_files_added_zero_objects"; else unx_bad "all_four_refused_step_files_added_zero_objects"; fi
# truncated files did not take the app down: the later documents still ran.
unx_len 13 '= 10 Inches' "same_unit_inch_file_into_inch_document_is_untouched_10_in"
unx_len 14 '= 393\.70[0-9]* Inches' "step_10_m_into_inch_document_becomes_393.70_in"
unx_len 15 '= 10 Inches' "iges_inch_file_into_inch_document_is_untouched_10_in"
unx_len 16 '= 1 Millimeters' "app_survived_the_truncated_files_and_a_fresh_document_is_millimetres"

exit $fail
