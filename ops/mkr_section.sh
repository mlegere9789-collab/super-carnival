
# ---- MKR_: plug-in registry (a catalogue OF indexes), package install/uninstall, live updates -------------------
# Drives the real Dino8 binary headlessly. A loopback python3 http.server is the "registry host": it serves a
# registry file that lists several third-party index files (one corrupt, one missing) and the plug-in libraries
# themselves. Oracles are independent of the app: sha256sum / cmp / ls on the files the app wrote, and the
# libraries' bytes. Skipped on Windows (library naming and the server helper are unverified there).
mkr_ok() { echo "ok   MKR_$1"; }
mkr_bad() { echo "FAIL MKR_$1"; fail=1; }
mkr_has() { if grep -qF -- "$2" <<<"$MKR_OUT"; then mkr_ok "$1: $3"; else mkr_bad "$1: $3 (expected: $2)"; near "$MKR_OUT" "$2"; fi; }
mkr_not() { if grep -qF -- "$2" <<<"$MKR_OUT"; then mkr_bad "$1: $3 (unexpected: $2)"; else mkr_ok "$1: $3"; fi; }
mkr_run() {
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    MKR_OUT="$(XDG_CONFIG_HOME="$MKR_CFGROOT" APPDATA="$MKR_CFGROOT" timeout 900 "$BIN" --smoke 60 --script "$1" 2>&1)" || true
  else
    MKR_OUT="$(XDG_CONFIG_HOME="$MKR_CFGROOT" APPDATA="$MKR_CFGROOT" timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --smoke 60 --script "$1" 2>&1)" || true
  fi
}
MKR_LIBDIR="$(dirname "$BIN")/plugins"
MKR_HELLO=""; MKR_MESH=""; MKR_EXT=""
for ext in so dylib; do
  if [ -f "$MKR_LIBDIR/hello_dino.$ext" ]; then MKR_HELLO="$MKR_LIBDIR/hello_dino.$ext"; MKR_EXT="$ext"; fi
  if [ -f "$MKR_LIBDIR/mesh_tools.$ext" ]; then MKR_MESH="$MKR_LIBDIR/mesh_tools.$ext"; fi
done
if [ "$IS_WINDOWS" = 1 ] || ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1 || [ -z "$MKR_HELLO" ] || [ -z "$MKR_MESH" ]; then
  echo "skip MKR_*: needs Linux/macOS, python3, curl, sha256sum and the built sample plug-in libraries next to the binary"
else
  MKR_DIR="$TMPW/mkr"; MKR_SRV="$MKR_DIR/srv"; MKR_CFGROOT="$MKR_DIR/cfg"; MKR_CFG="$MKR_CFGROOT/dino8"
  mkdir -p "$MKR_SRV" "$MKR_CFGROOT"
  MKR_LOG="$MKR_DIR/server.log"
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$MKR_SRV" > "$MKR_LOG" 2>&1 &
  MKR_PID=$!
  MKR_PORT=""
  for _ in $(seq 1 100); do
    MKR_PORT="$(sed -n 's/^Serving HTTP on 127.0.0.1 port \([0-9]*\).*/\1/p' "$MKR_LOG" | head -1)"
    if [ -n "$MKR_PORT" ]; then break; fi
    sleep 0.1
  done
  if [ -z "$MKR_PORT" ]; then
    mkr_bad "server: loopback http.server did not start"
  else
    MKR_URL="http://127.0.0.1:$MKR_PORT"
    cp "$MKR_HELLO" "$MKR_SRV/hello_v2.so"                 # the package the winning (newest) listing points at
    cp "$MKR_MESH" "$MKR_SRV/old.so"                       # a DIFFERENT valid library: what the superseded listing points at
    head -c 1000 "$MKR_HELLO" > "$MKR_SRV/trunc.so"        # truncated in transit
    printf 'this is not a shared library\n' > "$MKR_SRV/garbage.so"
    MKR_H_SHA="$(sha256sum "$MKR_SRV/hello_v2.so" | awk '{print $1}')"
    MKR_M_SHA="$(sha256sum "$MKR_SRV/old.so" | awk '{print $1}')"
    MKR_G_SHA="$(sha256sum "$MKR_SRV/garbage.so" | awk '{print $1}')"
    MKR_Z_SHA="0000000000000000000000000000000000000000000000000000000000000000"
    mkr_entry() { # id name version url sha libname [extra json members]
      printf '{"id":"%s","name":"%s","version":"%s","author":"MKR","description":"mkr fixture","api_version":2,"download_url":"%s/%s","sha256":"%s","library_filename":"%s"%s}' "$1" "$2" "$3" "$MKR_URL" "$4" "$5" "$6" "${7:-}"
    }
    {
      printf '{"schema_version":1,"index_name":"Third Party A","updated":"2026-11-04","plugins":['
      mkr_entry hellodino HelloDino 1.0.0 old.so "$MKR_M_SHA" "tp_hello.$MKR_EXT"; printf ','
      mkr_entry badsha BadSha 1.0.0 hello_v2.so "$MKR_Z_SHA" "badsha.$MKR_EXT"; printf ','
      mkr_entry trunc Trunc 1.0.0 trunc.so "$MKR_H_SHA" "trunc.$MKR_EXT"; printf ','
      mkr_entry garbage Garbage 1.0.0 garbage.so "$MKR_G_SHA" "garbage.$MKR_EXT"; printf ','
      mkr_entry future FuturePkg 1.0.0 hello_v2.so "$MKR_H_SHA" "future.$MKR_EXT" ',"min_app_version":"99.0.0"'; printf ','
      mkr_entry needsdep NeedsDep 1.0.0 hello_v2.so "$MKR_H_SHA" "needsdep.$MKR_EXT" ',"dependencies":["hellodino@5.0.0"]'
      printf ']}'
    } > "$MKR_SRV/first.json"
    {
      printf '{"schema_version":1,"index_name":"Third Party B","updated":"2026-11-05","plugins":['
      mkr_entry hellodino HelloDino 1.2.0 hello_v2.so "$MKR_H_SHA" "tp_hello.$MKR_EXT"; printf ','
      mkr_entry extratool ExtraTool 0.3.0 old.so "$MKR_M_SHA" "extratool.$MKR_EXT"
      printf ']}'
    } > "$MKR_SRV/second.json"
    printf '{ this index is corrupt' > "$MKR_SRV/corrupt.json"
    printf '{"schema_version":1,"registry_name":"MKR Test Registry","indexes":["first.json",{"source":"second.json"},"corrupt.json","missing.json"]}' > "$MKR_SRV/registry.json"
    printf '{"schema_version":1,"registry_name":"All Bad","indexes":["corrupt.json","missing.json"]}' > "$MKR_SRV/allbad.json"

    # ---- run 1: registry load (+ negative controls), merged list, update check, refusals, one real install ----
    MKR_PRE="$(ls -A "$MKR_CFG/plugins" 2>/dev/null || true)"
    cat > "$MKR_DIR/run1.txt" <<EOS
PluginMarketplaceRegistry $MKR_SRV/first.json
PluginMarketplaceRegistry $MKR_SRV/nonexistent_registry.json
PluginMarketplaceIndex $MKR_SRV/registry.json
PluginMarketplaceRegistry $MKR_URL/registry.json
PluginMarketplaceList
PluginMarketplaceRegistry $MKR_URL/allbad.json
PluginMarketplaceList
PluginMarketplaceCheckUpdates
PluginMarketplaceInstall badsha
PluginMarketplaceInstall trunc
PluginMarketplaceInstall garbage
PluginMarketplaceInstall future
PluginMarketplaceInstall needsdep
PluginMarketplaceInstall hellodino
HelloDino RegistryTest
EOS
    mkr_run "$MKR_DIR/run1.txt"
    echo "$MKR_OUT" > "$MKR_DIR/run1.out"
    mkr_has A_plain_index_refused "PluginMarketplaceRegistry: this file is a plug-in index, not a registry" "a plain index handed to the registry loader is refused with a specific message"
    mkr_has A_missing_registry "PluginMarketplaceRegistry: could not open $MKR_SRV/nonexistent_registry.json" "a nonexistent registry file is refused"
    mkr_has A_registry_not_index "PluginMarketplaceIndex: index has no \"plugins\" array" "a registry handed to the single-index loader is refused (formats are not interchangeable)"
    mkr_has B_url_loaded "PluginMarketplaceRegistry: loaded \"MKR Test Registry\" - 7 plug-in(s) merged from 2 of 4 listed index(es)" "an http registry loads: 6 + 2 entries with one duplicate id merge to 7, from 2 of the 4 listed indexes"
    mkr_has B_index_a "PluginMarketplaceRegistry: index \"Third Party A\" (6 plug-in(s)) from $MKR_URL/first.json" "index A resolved relative to the registry URL and parsed (6 entries)"
    mkr_has B_index_b "PluginMarketplaceRegistry: index \"Third Party B\" (2 plug-in(s)) from $MKR_URL/second.json" "index B resolved and parsed (2 entries)"
    mkr_has B_corrupt_skipped "PluginMarketplaceRegistry: skipped $MKR_URL/corrupt.json:" "the corrupt listed index is reported and skipped"
    mkr_has B_missing_skipped "PluginMarketplaceRegistry: skipped $MKR_URL/missing.json:" "the missing (404) listed index is reported and skipped"
    mkr_has C_higher_version_wins "PluginMarketplaceRegistry: hellodino: 1.2.0 from \"Third Party B\" supersedes 1.0.0 from \"Third Party A\"" "the same id in two indexes resolves to the numerically higher version (and says so)"
    mkr_has C_list_winner "  hellodino: HelloDino 1.2.0 by MKR (api v2, compatible) [from \"Third Party B\"]" "PluginMarketplaceList shows the winning 1.2.0 entry with its origin index"
    mkr_has C_list_union "  extratool: ExtraTool 0.3.0 by MKR (api v2, compatible) [from \"Third Party B\"]" "an entry only in index B is in the merged catalogue"
    mkr_has C_list_a_only "  trunc: Trunc 1.0.0 by MKR (api v2, compatible) [from \"Third Party A\"]" "an entry only in index A is in the merged catalogue"
    mkr_not C_no_stale_hellodino "hellodino: HelloDino 1.0.0 by MKR" "the superseded 1.0.0 listing is not shown"
    if [ "$(grep -cF 'PluginMarketplaceList: 7 plug-in(s) in the loaded index' <<<"$MKR_OUT" || true)" = 2 ]; then
      mkr_ok "D_failed_reload_keeps_catalogue: a registry whose every index fails to load is refused AND leaves the previously loaded 7-entry catalogue intact"
    else mkr_bad "D_failed_reload_keeps_catalogue: expected the 7-entry list twice"; fi
    mkr_has D_all_bad_refused "PluginMarketplaceRegistry: none of the 2 index(es) listed by the registry could be loaded" "an all-bad registry reports that nothing could be loaded"
    mkr_has E_update_checker "  hellodino: HelloDino 1.0.0 -> 1.2.0" "the update checker runs against the merged catalogue: installed HelloDino 1.0.0 -> 1.2.0"
    mkr_has F_bad_sha_refused "PluginMarketplaceInstall: BadSha: sha256 mismatch (index says $MKR_Z_SHA" "a package whose bytes do not match the index sha256 is refused"
    mkr_has F_truncated_refused "PluginMarketplaceInstall: Trunc: sha256 mismatch" "a truncated download (index lists the full file's sha256) is refused"
    mkr_has F_garbage_refused "PluginMarketplaceInstall: " "garbage package produced an install error line"
    mkr_has F_version_mismatch "PluginMarketplaceInstall: FuturePkg needs Dino 8 99.0.0 or newer, this build is" "an entry needing a newer Dino 8 than this build is refused (version mismatch)"
    mkr_has G_install_ok "PluginMarketplaceInstall: installed hellodino" "the winning registry entry installs over http"
    mkr_has G_command_runs "HelloDino: hello, RegistryTest!" "the installed package's own command runs"
    MKR_INST="$MKR_CFG/plugins/tp_hello.$MKR_EXT"
    if [ -f "$MKR_INST" ] && [ "$(sha256sum "$MKR_INST" | awk '{print $1}')" = "$MKR_H_SHA" ] && cmp -s "$MKR_INST" "$MKR_SRV/hello_v2.so" && ! cmp -s "$MKR_INST" "$MKR_SRV/old.so"; then
      mkr_ok "G_installed_bytes: the installed file's independent sha256sum equals the winning (1.2.0) package and differs from the superseded listing's package"
    else mkr_bad "G_installed_bytes: installed file missing or wrong bytes"; fi
    MKR_LEFT="$(cd "$MKR_CFG/plugins" 2>/dev/null && ls -A | grep -v "^tp_hello\." || true)"
    if [ -z "$MKR_LEFT" ]; then mkr_ok "F_no_residue: refused packages left NO file in <config>/plugins (only the one real install is there)"
    else mkr_bad "F_no_residue: unexpected files in <config>/plugins: $MKR_LEFT"; fi
    if [ -z "$MKR_PRE" ]; then mkr_ok "G_pre_state: <config>/plugins was empty before the run (oracle for the uninstall check)"; else mkr_bad "G_pre_state: not empty: $MKR_PRE"; fi

    # ---- the catalogue is live: the host changes the published files; the SAME registry URL now yields new content ----
    {
      printf '{"schema_version":1,"index_name":"Third Party B","updated":"2026-11-06","plugins":['
      mkr_entry hellodino HelloDino 1.3.0 hello_v2.so "$MKR_H_SHA" "tp_hello.$MKR_EXT"; printf ','
      mkr_entry newtool NewTool 1.0.0 old.so "$MKR_M_SHA" "newtool.$MKR_EXT"
      printf ']}'
    } > "$MKR_SRV/second.json"
    cat > "$MKR_DIR/run2.txt" <<EOS
PluginMarketplaceRegistry $MKR_URL/registry.json
PluginMarketplaceList
PluginMarketplaceCheckUpdates
PluginMarketplaceUninstall hellodino
EOS
    mkr_run "$MKR_DIR/run2.txt"
    echo "$MKR_OUT" > "$MKR_DIR/run2.out"
    mkr_has H_live_new_entry "  newtool: NewTool 1.0.0 by MKR (api v2, compatible) [from \"Third Party B\"]" "after the host republished index B, the same registry URL shows the new entry"
    mkr_not H_live_old_gone "extratool" "the entry the host removed from index B is gone"
    mkr_has H_live_new_version "  hellodino: HelloDino 1.0.0 -> 1.3.0" "the update checker sees the host's new 1.3.0"
    mkr_has I_uninstall "PluginMarketplaceUninstall: uninstalled hellodino" "the installed package uninstalls"
    if [ ! -e "$MKR_INST" ] && [ -z "$(ls -A "$MKR_CFG/plugins" 2>/dev/null || true)" ]; then
      mkr_ok "I_uninstall_no_files: after uninstall <config>/plugins holds no files at all (independent ls)"
    else mkr_bad "I_uninstall_no_files: leftovers: $(ls -A "$MKR_CFG/plugins" 2>/dev/null || true)"; fi

    # ---- run 3: default location (<config>/plugin-registry.json) with a local registry, relative + absolute sources ----
    mkdir -p "$MKR_CFG"
    printf '{"schema_version":1,"index_name":"Local Extra","plugins":[{"id":"hellodino","name":"HelloDino","version":"0.5.0","bundled_path":"plugins/hello_dino"},{"id":"localtool","name":"LocalTool","version":"2.0.0","bundled_path":"plugins/mesh_tools"}]}' > "$MKR_CFG/local_extra.json"
    printf '{"schema_version":1,"registry_name":"Local Registry","indexes":["%s/../plugin-index/index.json","local_extra.json"]}' "$HEREW" > "$MKR_CFG/plugin-registry.json"
    cat > "$MKR_DIR/run3.txt" <<EOS
PluginMarketplaceRegistry
PluginMarketplaceList
EOS
    mkr_run "$MKR_DIR/run3.txt"
    mkr_has J_default_path "PluginMarketplaceRegistry: loaded \"Local Registry\" - 5 plug-in(s) merged from 2 of 2 listed index(es)" "with no argument the registry at <config>/plugin-registry.json loads: bundled reference index (4) + local file (2) with one duplicate = 5"
    mkr_has J_lower_ignored "PluginMarketplaceRegistry: hellodino: 0.5.0 from \"Local Extra\" ignored (keeping 1.0.0 from \"Dino 8 Reference Plugin Index\")" "a lower version in a later index does not displace the higher one"
    mkr_has J_local_entry "  localtool: LocalTool 2.0.0" "an entry only in the local index is merged in"
    rm -f "$MKR_CFG/plugin-registry.json"
    cat > "$MKR_DIR/run4.txt" <<EOS
PluginMarketplaceRegistry
EOS
    mkr_run "$MKR_DIR/run4.txt"
    mkr_has J_no_default_registry "PluginMarketplaceRegistry: could not open" "with no argument and no <config>/plugin-registry.json the command refuses instead of inventing one"
  fi
  kill "$MKR_PID" 2>/dev/null || true
  wait "$MKR_PID" 2>/dev/null || true
fi

exit $fail
