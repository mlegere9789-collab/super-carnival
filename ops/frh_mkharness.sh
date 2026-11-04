#!/bin/bash
# usage: frh_mkharness.sh <tests dir> <start-marker regex> <out file>
T="$1"; PAT="$2"; OUT="$3"
a=$(grep -n "$PAT" "$T/smoke.sh" | head -1 | cut -d: -f1)
b=$(grep -n '^exit \$fail' "$T/smoke.sh" | tail -1 | cut -d: -f1)
{
  sed -n '1,128p' "$T/smoke.sh" | sed "s|^HERE=.*|HERE=$T|"
  sed -n "$((a-1)),$((b-1))p" "$T/smoke.sh"
  echo 'exit $fail'
} > "$OUT"
echo "section lines $a..$b"
