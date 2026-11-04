import os
os.chdir('/home/user/miniature-pancake/.claude/worktrees/agent-ab6dd2aa413bb4a90/dino8-app')

p='src/plugins/MarketplaceIndex.h'
s=open(p).read()
s=s.replace("""  std::string library_filename;  // optional override for the installed file's name
};""","""  std::string library_filename;  // optional override for the installed file's name

  // Which index_name this entry came from. Empty for an entry read straight
  // from one index; filled by MergeIndexes/LoadRegistryAuto so a merged
  // catalogue still says where each entry was found.
  std::string origin;
};""")
s=s.replace("""}  // namespace dino8::plugins""","""// ---- Registry: a catalogue OF indexes --------------------------------------
// A registry file (plugin-index/SCHEMA.md, "Registry") lists any number of
// index sources - local paths or http(s) URLs, each one a plain index file
// as parsed by ParseIndex. LoadRegistryAuto loads every listed index
// independently and merges them into ONE catalogue (MergeIndexes), so a
// user points the marketplace at a single registry and sees every listed
// third-party index together, instead of typing each path/URL by hand.
struct MarketplaceRegistry {
  int schema_version = 0;
  std::string registry_name;
  std::vector<std::string> sources;  // as written in the file (not yet resolved)
};

// Outcome of loading ONE index listed by a registry.
struct RegistrySourceResult {
  std::string source;      // resolved (see ResolveRegistrySource)
  bool ok = false;
  std::string error;       // set when !ok
  std::string index_name;  // set when ok
  size_t plugin_count = 0; // set when ok
};

// Parses registry JSON: {"schema_version":1, "registry_name":"...",
// "indexes":[ "path-or-url", {"source":"path-or-url"}, ...]}. false (with
// `error`) on malformed JSON, schema_version != 1, a missing/empty
// "indexes" array, or an element that is neither a string nor an object with
// a non-empty "source". A plain index file (it has "plugins", not
// "indexes") is refused rather than silently read as an empty registry.
bool ParseRegistry(const std::string& json_text, MarketplaceRegistry& out, std::string& error);

// Resolves a registry-listed source against the location of the registry
// that listed it: an absolute path or http(s) URL is returned as is; a
// relative path resolves against the registry file's directory (or, for a
// registry fetched from a URL, against that URL up to its last '/').
std::string ResolveRegistrySource(const std::string& registry_location, const std::string& source);

// Merges indexes into one catalogue. When two indexes list the same plug-in
// id, the HIGHER version (CompareVersions) wins; on an exact tie the
// earlier index in the list wins. `notes` (optional) receives one line per
// displaced duplicate. Each surviving entry's `origin` is set to the
// index_name it came from. The result's index_name is `merged_name`.
MarketplaceIndex MergeIndexes(const std::vector<MarketplaceIndex>& indexes, const std::string& merged_name,
                               std::vector<std::string>* notes = nullptr);

// Loads the registry at `location` (local path or http(s) URL), then every
// index it lists. An index that cannot be fetched or fails ParseIndex is
// SKIPPED and reported in `results` (ok=false) - one bad third-party index
// never hides the others - but if NO listed index loads, returns false with
// `error`. `notes` as for MergeIndexes.
bool LoadRegistryAuto(const std::string& location, MarketplaceIndex& merged,
                       std::vector<RegistrySourceResult>& results, std::vector<std::string>& notes,
                       std::string& error);

}  // namespace dino8::plugins""")
open(p,'w').write(s)

p='src/plugins/MarketplaceIndex.cpp'
s=open(p).read().rstrip()
tail="}  // namespace dino8::plugins"
assert s.endswith(tail)
s=s[:-len(tail)]
s+=r'''bool ParseRegistry(const std::string& json_text, MarketplaceRegistry& out, std::string& error) {
  json::Value root;
  if (!json::Parse(json_text, root, error)) return false;
  if (!root.IsObject()) {
    error = "registry root is not a JSON object";
    return false;
  }
  const json::Value& sv = root["schema_version"];
  const int schema_version = sv.type == json::Value::Type::Number ? static_cast<int>(sv.number) : 0;
  if (schema_version != 1) {
    error = "unsupported registry schema_version " + std::to_string(schema_version) +
            " (this build reads schema_version 1 - see plugin-index/SCHEMA.md)";
    return false;
  }
  const json::Value& idxs = root["indexes"];
  if (!idxs.IsArray()) {
    error = root["plugins"].IsArray()
                ? "this file is a plug-in index, not a registry (it has \"plugins\", not \"indexes\") - use PluginMarketplaceIndex"
                : "registry has no \"indexes\" array";
    return false;
  }
  if (idxs.array.empty()) {
    error = "registry lists no indexes";
    return false;
  }
  MarketplaceRegistry reg;
  reg.schema_version = schema_version;
  reg.registry_name = root["registry_name"].AsString("Untitled Plugin Registry");
  for (size_t i = 0; i < idxs.array.size(); ++i) {
    const json::Value& e = idxs.array[i];
    std::string src;
    if (e.IsString()) src = e.string;
    else if (e.IsObject()) src = e["source"].AsString();
    if (src.empty()) {
      error = "indexes[" + std::to_string(i) + "] is neither a source string nor an object with a \"source\"";
      return false;
    }
    reg.sources.push_back(src);
  }
  out = std::move(reg);
  return true;
}

std::string ResolveRegistrySource(const std::string& registry_location, const std::string& source) {
  if (IsHttpUrl(source)) return source;
  if (IsHttpUrl(registry_location)) {
    // A relative entry in a URL registry is relative to that URL's directory.
    if (!source.empty() && source[0] == '/') {
      const size_t scheme = registry_location.find("://");
      const size_t host_end = registry_location.find('/', scheme + 3);
      return (host_end == std::string::npos ? registry_location : registry_location.substr(0, host_end)) + source;
    }
    const size_t slash = registry_location.find_last_of('/');
    return registry_location.substr(0, slash + 1) + source;
  }
  fs::path sp(source);
  if (sp.is_absolute()) return source;
  return (fs::path(registry_location).parent_path() / sp).generic_string();
}

MarketplaceIndex MergeIndexes(const std::vector<MarketplaceIndex>& indexes, const std::string& merged_name,
                               std::vector<std::string>* notes) {
  MarketplaceIndex out;
  out.schema_version = 1;
  out.index_name = merged_name;
  for (const MarketplaceIndex& idx : indexes) {
    if (out.updated.empty() || idx.updated > out.updated) out.updated = idx.updated;
    for (MarketplaceEntry e : idx.plugins) {
      e.origin = idx.index_name;
      auto it = std::find_if(out.plugins.begin(), out.plugins.end(),
                             [&](const MarketplaceEntry& x) { return x.id == e.id; });
      if (it == out.plugins.end()) {
        out.plugins.push_back(std::move(e));
        continue;
      }
      if (CompareVersions(e.version, it->version) > 0) {
        if (notes)
          notes->push_back(e.id + ": " + e.version + " from \"" + e.origin + "\" supersedes " + it->version + " from \"" +
                           it->origin + "\"");
        *it = std::move(e);
      } else if (notes) {
        notes->push_back(e.id + ": " + e.version + " from \"" + e.origin + "\" ignored (keeping " + it->version +
                         " from \"" + it->origin + "\")");
      }
    }
  }
  return out;
}

bool LoadRegistryAuto(const std::string& location, MarketplaceIndex& merged,
                       std::vector<RegistrySourceResult>& results, std::vector<std::string>& notes,
                       std::string& error) {
  results.clear();
  notes.clear();
  std::string text;
  if (IsHttpUrl(location)) {
    std::string tmp;
    if (!FetchUrlToTempFile(location, tmp, error)) return false;
    std::ifstream in(tmp, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    text = ss.str();
    in.close();
    std::error_code ec;
    fs::remove(tmp, ec);
  } else {
    std::ifstream in(location, std::ios::binary);
    if (!in) {
      error = "could not open " + location;
      return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    text = ss.str();
  }
  MarketplaceRegistry reg;
  if (!ParseRegistry(text, reg, error)) return false;

  std::vector<MarketplaceIndex> loaded;
  for (const std::string& raw : reg.sources) {
    RegistrySourceResult r;
    r.source = ResolveRegistrySource(location, raw);
    MarketplaceIndex idx;
    std::string e;
    if (LoadIndexAuto(r.source, idx, e)) {
      r.ok = true;
      r.index_name = idx.index_name;
      r.plugin_count = idx.plugins.size();
      loaded.push_back(std::move(idx));
    } else {
      r.error = e;
    }
    results.push_back(std::move(r));
  }
  if (loaded.empty()) {
    error = "none of the " + std::to_string(reg.sources.size()) + " index(es) listed by the registry could be loaded";
    return false;
  }
  merged = MergeIndexes(loaded, reg.registry_name, &notes);
  return true;
}

}  // namespace dino8::plugins
'''
open(p,'w').write(s)

p='src/plugins/Marketplace.h'
s=open(p).read()
s=s.replace("""  bool LoadFrom(const std::string& source, std::string& error);
""","""  bool LoadFrom(const std::string& source, std::string& error);
  // Loads a registry (MarketplaceIndex.h's LoadRegistryAuto) and makes the
  // merged catalogue the loaded index, so every other marketplace operation
  // (list/install/check-updates/...) works on it unchanged. On failure the
  // previously loaded index is left untouched.
  bool LoadRegistry(const std::string& location, std::vector<RegistrySourceResult>& results,
                     std::vector<std::string>& notes, std::string& error);
  // <config>/plugin-registry.json - where PluginMarketplaceRegistry looks
  // when given no argument.
  static std::string DefaultRegistryPath();
""",1)
open(p,'w').write(s)

p='src/plugins/Marketplace.cpp'
s=open(p).read()
s=s.replace("""bool Marketplace::InstallById(app::Application& app, const std::string& id, std::string& error) {""","""bool Marketplace::LoadRegistry(const std::string& location, std::vector<RegistrySourceResult>& results,
                                std::vector<std::string>& notes, std::string& error) {
  MarketplaceIndex merged;
  if (!LoadRegistryAuto(location, merged, results, notes, error)) return false;
  index_ = std::move(merged);
  source_ = location;
  return true;
}

std::string Marketplace::DefaultRegistryPath() {
  return (fs::path(app::ConfigDirectory()) / "plugin-registry.json").string();
}

bool Marketplace::InstallById(app::Application& app, const std::string& id, std::string& error) {""",1)
open(p,'w').write(s)

p='src/commands/cmd_flow.cpp'
s=open(p).read()
s=s.replace("""  Reg(e, "PluginMarketplaceList", Immediate(""","""  Reg(e, "PluginMarketplaceRegistry", Immediate([](CommandContext& ctx) {
        std::vector<std::string> toks;
        while (auto tok = ctx.Engine().TakePendingInput()) toks.push_back(*tok);
        // No argument: the user's own registry, <config>/plugin-registry.json.
        const std::string location = toks.empty() ? plugins::Marketplace::DefaultRegistryPath() : toks[0];
        std::vector<plugins::RegistrySourceResult> results;
        std::vector<std::string> notes;
        std::string error;
        if (!plugins::Marketplace::Get().LoadRegistry(location, results, notes, error)) {
          ctx.Warn("PluginMarketplaceRegistry: " + error);
          for (const auto& r : results)
            if (!r.ok) ctx.Warn("PluginMarketplaceRegistry: skipped " + r.source + ": " + r.error);
          return;
        }
        size_t loaded = 0;
        for (const auto& r : results) {
          if (r.ok) {
            ++loaded;
            ctx.Print("PluginMarketplaceRegistry: index \\"" + r.index_name + "\\" (" + std::to_string(r.plugin_count) +
                      " plug-in(s)) from " + r.source);
          } else {
            ctx.Warn("PluginMarketplaceRegistry: skipped " + r.source + ": " + r.error);
          }
        }
        for (const std::string& n : notes) ctx.Print("PluginMarketplaceRegistry: " + n);
        const auto& idx = plugins::Marketplace::Get().Index();
        ctx.Print("PluginMarketplaceRegistry: loaded \\"" + idx.index_name + "\\" - " + std::to_string(idx.plugins.size()) +
                  " plug-in(s) merged from " + std::to_string(loaded) + " of " + std::to_string(results.size()) +
                  " listed index(es)");
      }));

  Reg(e, "PluginMarketplaceList", Immediate(""",1)
s=s.replace('''          std::string line = "  " + p.id + ": " + p.name + " " + p.version + " by " + p.author + " (api v" +
                              std::to_string(p.api_version) + ", " + compat_label + ")";''','''          std::string line = "  " + p.id + ": " + p.name + " " + p.version + " by " + p.author + " (api v" +
                              std::to_string(p.api_version) + ", " + compat_label + ")";
          if (!p.origin.empty()) line += " [from \\"" + p.origin + "\\"]";''',1)
open(p,'w').write(s)
