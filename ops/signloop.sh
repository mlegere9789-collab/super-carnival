#!/usr/bin/env bash
# Copy of the workflow's "Sign release files with cosign" run block, run in a staged dir with a stub cosign.
set -euo pipefail
cd /tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/rel2
flag=""
if cosign sign-blob --help 2>&1 | grep -q -e '--new-bundle-format'; then flag="--new-bundle-format"; fi
for f in $(ls -1 | grep -v -e '\.sha256$' -e '\.sigstore\.json$'); do
  echo "cosign sign-blob $f"
  cosign sign-blob --yes $flag --bundle "$f.sigstore.json" "$f" > /dev/null
done
ls -1
