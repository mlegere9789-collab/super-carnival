// Plug-in index format: the JSON schema documented in
// plugin-index/SCHEMA.md, parsed and loaded here. Deliberately independent
// of app::Application/plugins::Manager (unlike plugins/Marketplace.h, which
// installs an entry) so it can be unit-tested on its own - see
// tests/test_plugin_marketplace.cpp.
#pragma once

#include <string>
#include <vector>

namespace dino8::plugins {

struct MarketplaceEntry {
  std::string id;           // unique slug, e.g. "hellodino" - used by Install
  std::string name;         // display name, e.g. "HelloDino"
  std::string version;
  std::string description;
  std::string author;
  std::string homepage;     // optional
  std::string min_app_version;  // optional; enforced by CheckCompatibility
  std::vector<std::string> tags;
  int api_version = 0;      // the DINO8_PLUGIN_API_VERSION this plug-in targets

  // ids of other entries in the same index that must be installed before
  // this one - see plugins::Marketplace::InstallById, which resolves and
  // installs each of these (skipping any already satisfied by a loaded
  // plug-in) ahead of this entry itself. Each entry is either a bare id
  // ("meshtools") or an id plus a minimum version required of it
  // ("meshtools@1.2.0") - see SplitDependencySpec.
  std::vector<std::string> dependencies;

  // Exactly one of these two identifies where the library comes from:
  std::string download_url;  // http:// or https:// - fetched with curl
  std::string bundled_path;  // path relative to the app's own exe directory,
                              // WITHOUT the platform's .so/.dll/.dylib
                              // suffix - for a plug-in already shipped
                              // alongside this build (plugin-index/index.json).

  std::string sha256;            // optional, only meaningful with download_url
  std::string library_filename;  // optional override for the installed file's name

  // Which index_name this entry came from. Empty for an entry read straight
  // from one index; filled by MergeIndexes/LoadRegistryAuto so a merged
  // catalogue still says where each entry was found.
  std::string origin;
};

struct MarketplaceIndex {
  int schema_version = 0;
  std::string index_name;
  std::string updated;
  std::vector<MarketplaceEntry> plugins;
};

enum class Compatibility { Compatible, ApiTooNew, AppTooOld, Unknown };

// Compares entry.api_version against DINO8_PLUGIN_API_VERSION, and - when
// `running_app_version` is given - entry.min_app_version against it too.
// The plug-in ABI is additive (see include/dino8_plugin.h's version-2
// comment), so any api_version <= this build's is expected to load; higher
// means this build is too old for it (ApiTooNew, checked first).
// Otherwise, if the entry declares a min_app_version and the caller passed a
// non-empty running_app_version, AppTooOld means this build's own version is
// older than the plug-in requires (compared numerically via
// CompareVersions, not lexically). `running_app_version` defaults to "",
// which skips that second check entirely - the same "informational only"
// behavior this function always had before min_app_version was enforced;
// callers that care (InstallEntry, the marketplace panel, PluginMarketplaceList)
// pass DINO8_VERSION.
Compatibility CheckCompatibility(const MarketplaceEntry& entry, const std::string& running_app_version = "");

// The specific reason CheckCompatibility(entry, running_app_version) returned
// anything other than Compatible - the same wording InstallEntry's own
// refusal already uses (Marketplace.cpp), just without the leading
// "<entry name>: " a caller that already shows the name elsewhere (a list
// row, a compatibility-badge tooltip) doesn't want repeated. Empty when
// CheckCompatibility(...) is Compatible (nothing to explain) or Unknown
// (api_version is simply absent/0 - not actually refused, just unrated).
// Lets a caller show *what* is required (an exact api_version or
// min_app_version) instead of a generic "needs newer Dino 8" label, without
// having to attempt - and fail - an install first.
std::string CompatibilityReason(const MarketplaceEntry& entry, const std::string& running_app_version = "");

// Splits one dependencies[] entry into the id it names and the minimum
// version it requires of that id, if any: "meshtools@1.2.0" splits to
// ("meshtools", "1.2.0"); a bare "meshtools" splits to ("meshtools", "").
// Used by Marketplace::InstallByIdChecked to decide whether an
// already-installed dependency still satisfies what depends on it, and by
// the marketplace panel/commands to look the id up in the loaded index and
// display the constraint.
void SplitDependencySpec(const std::string& spec, std::string& id, std::string& min_version);

// Compares two dotted-numeric version strings ("1.2.3", "1.10.0", ...)
// component by component as integers - not a lexical string compare, so
// "1.10.0" correctly orders above "1.2.0". A missing trailing component (or
// one whose leading characters aren't digits, e.g. a "-beta" suffix) counts
// as 0. This is a pragmatic dotted-integer comparison, not a full semver
// parser: pre-release/build-metadata tags are not given any special
// ordering. Returns <0 if a<b, 0 if a==b, >0 if a>b.
int CompareVersions(const std::string& a, const std::string& b);

enum class UpdateStatus { UpToDate, UpdateAvailable, Unknown };

// Compares an installed plug-in's version (e.g. LoadedPlugin::version, from
// PluginManager.h) against a marketplace entry's version. Unknown when
// either string is empty, since there's nothing meaningful to compare.
UpdateStatus CheckForUpdate(const std::string& installed_version, const std::string& available_version);

// True if `filter` (matched case-insensitively, as a substring) appears in
// `entry`'s id, name, author, description, or any one of its tags. An empty
// `filter` matches everything. Shared by the PluginMarketplaceList command
// and the marketplace panel's filter box, so typing "mesh" in either one
// finds the same plug-ins the same way.
bool MatchesFilter(const MarketplaceEntry& entry, const std::string& filter);

// Parses index JSON already read into memory. Returns false (with `error`
// set to a human-readable message) on malformed JSON, an unsupported
// schema_version, or a plugin entry missing a required field.
bool ParseIndex(const std::string& json_text, MarketplaceIndex& out, std::string& error);

// Reads and parses a local index file.
bool LoadIndexFromFile(const std::string& path, MarketplaceIndex& out, std::string& error);

// Fetches (via a real HTTP GET, see MarketplaceIndex.cpp) and parses a
// remote index. Only http:// and https:// are accepted.
bool LoadIndexFromUrl(const std::string& url, MarketplaceIndex& out, std::string& error);

// Dispatches to LoadIndexFromUrl or LoadIndexFromFile based on `source`'s
// scheme.
bool LoadIndexAuto(const std::string& source, MarketplaceIndex& out, std::string& error);

// Downloads `url` into a freshly created temp file (via the `curl` binary)
// and returns its path in `out_path`. Real network I/O - shared by
// LoadIndexFromUrl and, for a downloaded (non-bundled) entry, by
// plugins::InstallEntry (Marketplace.cpp).
bool FetchUrlToTempFile(const std::string& url, std::string& out_path, std::string& error);

// ---- Registry: a catalogue OF indexes --------------------------------------
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

}  // namespace dino8::plugins
