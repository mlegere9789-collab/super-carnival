import os, json
os.chdir('/home/user/miniature-pancake/.claude/worktrees/agent-aa3cc9045c22c4ab3/dino8-app/plugin-templates')
D = '{{cookiecutter.plugin_slug}}'

common_cmake = '''cmake_minimum_required(VERSION 3.16)
project({{cookiecutter.plugin_slug}} VERSION {{cookiecutter.version}} LANGUAGES C)

# The ONLY dependency is the Dino 8 plug-in SDK. Point CMake at it with
#   -DCMAKE_PREFIX_PATH=<sdk prefix>      (the prefix you installed the SDK to)
find_package(Dino8PluginSdk 2 REQUIRED)

dino8_add_plugin({{cookiecutter.plugin_slug}} SOURCES src/plugin.c)
'''

manifest = '''{
  "name": "{{cookiecutter.plugin_name}}",
  "version": "{{cookiecutter.version}}",
  "author": "{{cookiecutter.author}}",
  "description": "{{cookiecutter.description}}"
}
'''

index_entry = '''{
  "id": "{{cookiecutter.plugin_slug}}",
  "name": "{{cookiecutter.plugin_name}}",
  "version": "{{cookiecutter.version}}",
  "description": "{{cookiecutter.description}}",
  "author": "{{cookiecutter.author}}",
  "tags": [{{cookiecutter.index_tags}}],
  "api_version": 2,
  "min_app_version": "0.1.0",
  "download_url": "https://example.invalid/REPLACE-ME/{{cookiecutter.plugin_slug}}.so",
  "sha256": "REPLACE-WITH-package_plugin.py-OUTPUT"
}
'''

gitignore = "build/\n*.so\n*.dll\n*.dylib\n"

readme_tpl = '''# {{cookiecutter.plugin_name}}

{{cookiecutter.description}}

Generated from the Dino 8 `%(kind)s` plug-in template. It builds against the
Dino 8 plug-in SDK only - no Dino 8 source tree needed.

```sh
# 1. get the SDK once (from a Dino 8 source checkout; skip if you already have one):
cmake -S <dino8>/dino8-app/plugin-sdk -B sdk-build && cmake --install sdk-build --prefix ~/dino8-sdk
# 2. build this plug-in:
cmake -S . -B build -DCMAKE_PREFIX_PATH=~/dino8-sdk
cmake --build build
# 3. load it: copy build/{{cookiecutter.plugin_slug}}.so (.dll / .dylib) into Dino 8's
#    <config>/plugins folder, or run   GrasshopperFolders add <folder containing it>
# 4. try it:
%(try)s
```

* `src/plugin.c` - the plug-in.
* `manifest.json` - the Package Manager manifest (name/version/author/description).
* `index-entry.json` - a marketplace index entry to paste into your own plug-in index.
* Package it for distribution with `plugin-templates/package_plugin.py`; the
  full story (versioning, listing, review) is in `docs/PLUGIN_GUIDE.md`.
'''

compat = '''  if (!api) return 1;
  /* ABI rule: Dino 8 only ever ADDS to Dino8PluginApi, so a plug-in built
   * against API version N runs on any host that offers version >= N. Refuse
   * (politely, with a reason in the command history) on an older host. */
  if (api->api_version < DINO8_PLUGIN_API_VERSION) {
    char msg[160];
    snprintf(msg, sizeof msg, "{{cookiecutter.plugin_slug}}: needs plug-in API v%d, this Dino 8 offers v%d",
             DINO8_PLUGIN_API_VERSION, api->api_version);
    if (api->print) api->print(msg);
    return 2;
  }
  g_api = api;
'''
tail = '''
DINO8_PLUGIN_EXPORT const char* dino8_plugin_name(void) { return "{{cookiecutter.plugin_name}}"; }
DINO8_PLUGIN_EXPORT const char* dino8_plugin_version(void) { return "{{cookiecutter.version}}"; }
DINO8_PLUGIN_EXPORT const char* dino8_plugin_description(void) { return "{{cookiecutter.description}}"; }
'''

src_command = '''/* {{cookiecutter.plugin_name}}: a Dino 8 command plug-in.
 * Registers one command, {{cookiecutter.command_name}} [x y z], that drops a point (default: the origin)
 * and reports it in the command history. Plain C against dino8_plugin.h only. */
#include <stdio.h>
#include <stdlib.h>

#include "dino8_plugin.h"

static const Dino8PluginApi* g_api = NULL;

static int Run{{cookiecutter.command_name}}(int argc, const char** argv, Dino8CommandContext* ctx) {
  (void)ctx;
  double p[3] = {0.0, 0.0, 0.0};
  if (argc == 2) {
    /* "1,2,3" typed as one token */
    sscanf(argv[1], "%lf,%lf,%lf", &p[0], &p[1], &p[2]);
  } else {
    for (int i = 1; i < argc && i <= 3; ++i) p[i - 1] = atof(argv[i]);
  }
  const unsigned long long id = g_api->add_point(p[0], p[1], p[2]);
  if (!id) {
    g_api->print("{{cookiecutter.plugin_slug}}: could not add the point");
    return 1;
  }
  char line[200];
  snprintf(line, sizeof line, "{{cookiecutter.plugin_slug}}: {{cookiecutter.command_name}} placed a point at (%g, %g, %g)", p[0], p[1], p[2]);
  g_api->print(line);
  return 0;
}

DINO8_PLUGIN_EXPORT int dino8_plugin_init(const Dino8PluginApi* api) {
''' + compat + '''  return api->register_command("{{cookiecutter.command_name}}", "{{cookiecutter.description}}", Run{{cookiecutter.command_name}}, NULL);
}
''' + tail

src_impexp = '''/* {{cookiecutter.plugin_name}}: a Dino 8 import/export plug-in.
 * {{cookiecutter.command_name}}Import <file>  reads "x y z" lines (# comments allowed) and adds a point for each.
 * {{cookiecutter.command_name}}Export <file>  writes the bounding-box centre of every selected object, one "x y z" line each.
 * Plain C against dino8_plugin.h only. */
#include <stdio.h>
#include <string.h>

#include "dino8_plugin.h"

static const Dino8PluginApi* g_api = NULL;

/* Command tokens arrive split on spaces; rejoin them so a path with spaces works. */
static void JoinPath(int argc, const char** argv, char* out, size_t cap) {
  out[0] = 0;
  for (int i = 1; i < argc; ++i) {
    if (i > 1 && strlen(out) + 1 < cap) strcat(out, " ");
    if (strlen(out) + strlen(argv[i]) + 1 < cap) strcat(out, argv[i]);
  }
}

static int RunImport(int argc, const char** argv, Dino8CommandContext* ctx) {
  (void)ctx;
  char path[1024];
  JoinPath(argc, argv, path, sizeof path);
  if (!path[0]) { g_api->print("{{cookiecutter.command_name}}Import: usage: {{cookiecutter.command_name}}Import <file>"); return 1; }
  FILE* f = fopen(path, "r");
  if (!f) { g_api->print("{{cookiecutter.command_name}}Import: cannot open the file"); return 1; }
  char line[512];
  int count = 0;
  while (fgets(line, sizeof line, f)) {
    double x, y, z;
    if (line[0] == '#') continue;
    if (sscanf(line, "%lf %lf %lf", &x, &y, &z) != 3) continue;
    if (g_api->add_point(x, y, z)) ++count;
  }
  fclose(f);
  char msg[1200];
  snprintf(msg, sizeof msg, "{{cookiecutter.plugin_slug}}: imported %d point(s) from %s", count, path);
  g_api->print(msg);
  return 0;
}

static int RunExport(int argc, const char** argv, Dino8CommandContext* ctx) {
  (void)ctx;
  char path[1024];
  JoinPath(argc, argv, path, sizeof path);
  if (!path[0]) { g_api->print("{{cookiecutter.command_name}}Export: usage: {{cookiecutter.command_name}}Export <file>"); return 1; }
  unsigned long long ids[4096];
  const int n = g_api->get_selection(ids, 4096);
  FILE* f = fopen(path, "w");
  if (!f) { g_api->print("{{cookiecutter.command_name}}Export: cannot write the file"); return 1; }
  fprintf(f, "# x y z  ({{cookiecutter.plugin_name}} export)\\n");
  int written = 0;
  for (int i = 0; i < n && i < 4096; ++i) {
    double lo[3], hi[3];
    if (!g_api->get_object_bbox(ids[i], lo, hi)) continue;
    fprintf(f, "%.9g %.9g %.9g\\n", (lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5);
    ++written;
  }
  fclose(f);
  char msg[1200];
  snprintf(msg, sizeof msg, "{{cookiecutter.plugin_slug}}: exported %d object(s) to %s", written, path);
  g_api->print(msg);
  return 0;
}

DINO8_PLUGIN_EXPORT int dino8_plugin_init(const Dino8PluginApi* api) {
''' + compat + '''  if (api->register_command("{{cookiecutter.command_name}}Import", "Imports x y z lines from a text file as points.", RunImport, NULL)) return 3;
  if (api->register_command("{{cookiecutter.command_name}}Export", "Exports the centre of each selected object to a text file.", RunExport, NULL)) return 3;
  return 0;
}
''' + tail

src_panel = '''/* {{cookiecutter.plugin_name}}: a Dino 8 report ("panel") plug-in.
 * {{cookiecutter.command_name}} prints a read-only table about the current selection - id, bounding-box
 * size - plus totals, in the command history.
 *
 * Honest scope note: plug-in API v2 has no hook for ImGui/dockable widgets;
 * a plug-in's visible surface is the command history (api->print), the
 * document (add_*), user text on objects and Dino Flow nodes. This template
 * is the supported way to present a panel-like report today, and a Dino Flow
 * node mirrors it so the same numbers can feed a graph. */
#include <stdio.h>

#include "dino8_plugin.h"

static const Dino8PluginApi* g_api = NULL;

static int Run{{cookiecutter.command_name}}(int argc, const char** argv, Dino8CommandContext* ctx) {
  (void)argc; (void)argv; (void)ctx;
  unsigned long long ids[2048];
  const int n = g_api->get_selection(ids, 2048);
  g_api->print("== {{cookiecutter.plugin_name}} ==");
  if (n <= 0) { g_api->print("{{cookiecutter.plugin_slug}}: nothing selected"); return 0; }
  double total = 0.0;
  int rows = 0;
  for (int i = 0; i < n && i < 2048; ++i) {
    double lo[3], hi[3];
    if (!g_api->get_object_bbox(ids[i], lo, hi)) continue;
    const double sx = hi[0] - lo[0], sy = hi[1] - lo[1], sz = hi[2] - lo[2];
    char line[200];
    snprintf(line, sizeof line, "  id %llu  size %g x %g x %g  box volume %g", ids[i], sx, sy, sz, sx * sy * sz);
    g_api->print(line);
    total += sx * sy * sz;
    ++rows;
  }
  char sum[200];
  snprintf(sum, sizeof sum, "{{cookiecutter.plugin_slug}}: %d object(s), total box volume %g", rows, total);
  g_api->print(sum);
  return 0;
}

/* Dino Flow node: Box Volume (X, Y, Z sizes in, volume out). */
static int BoxVolumeEval(const Dino8FlowValue* in, int in_n, Dino8FlowValue* out, int out_n, char* err, int err_n, void* ud) {
  (void)err; (void)err_n; (void)ud;
  if (in_n < 3 || out_n < 1) return 1;
  out[0].kind = DINO8_FLOW_NUMBER;
  out[0].number = in[0].number * in[1].number * in[2].number;
  return 0;
}

DINO8_PLUGIN_EXPORT int dino8_plugin_init(const Dino8PluginApi* api) {
''' + compat + '''  if (api->register_command("{{cookiecutter.command_name}}", "Prints a report about the selection.", Run{{cookiecutter.command_name}}, NULL)) return 3;
  Dino8FlowPort ins[3] = { {"X", NULL, DINO8_FLOW_NUMBER, 1.0}, {"Y", NULL, DINO8_FLOW_NUMBER, 1.0}, {"Z", NULL, DINO8_FLOW_NUMBER, 1.0} };
  Dino8FlowPort outs[1] = { {"Volume", NULL, DINO8_FLOW_NUMBER, 0.0} };
  api->register_flow_node("{{cookiecutter.plugin_name}} Box Volume", "Plug-ins", "Volume of an X by Y by Z box.", ins, 3, outs, 1, BoxVolumeEval, NULL);
  return 0;
}
''' + tail

kinds = {
 'command': dict(cc={'plugin_name':'My Command Plugin','plugin_slug':'my_command_plugin','command_name':'MyCommand','version':'1.0.0','author':'Your Name','description':'Drops a point and says hello.','index_tags':'"command"'},
                 src=src_command, kind='command', tryit='#    MyCommand 1 2 3   ->  places a point and prints a line in the command history'),
 'import-export': dict(cc={'plugin_name':'My Xyz Exchange','plugin_slug':'my_xyz_exchange','command_name':'MyXyz','version':'1.0.0','author':'Your Name','description':'Imports and exports point lists as plain x y z text files.','index_tags':'"import", "export"'},
                 src=src_impexp, kind='import/export', tryit='#    MyXyzImport points.txt   /   (select objects)  MyXyzExport out.txt'),
 'panel': dict(cc={'plugin_name':'My Report Panel','plugin_slug':'my_report_panel','command_name':'MyReport','version':'1.0.0','author':'Your Name','description':'Prints a table of the selection (sizes and box volumes).','index_tags':'"report", "panel"'},
                 src=src_panel, kind='panel (report)', tryit='#    (select objects)  MyReport'),
}
for k, v in kinds.items():
    root = os.path.join(k, D)
    os.makedirs(os.path.join(root, 'src'), exist_ok=True)
    with open(os.path.join(k, 'cookiecutter.json'), 'w') as f:
        json.dump(v['cc'], f, indent=2); f.write('\n')
    open(os.path.join(root, 'CMakeLists.txt'), 'w').write(common_cmake)
    open(os.path.join(root, 'src', 'plugin.c'), 'w').write(v['src'])
    open(os.path.join(root, 'manifest.json'), 'w').write(manifest)
    open(os.path.join(root, 'index-entry.json'), 'w').write(index_entry)
    open(os.path.join(root, '.gitignore'), 'w').write(gitignore)
    open(os.path.join(root, 'README.md'), 'w').write(readme_tpl % dict(kind=v['kind'], **{'try': v['tryit']}))
