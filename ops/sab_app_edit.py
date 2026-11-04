R='/home/user/miniature-pancake/.claude/worktrees/agent-a6f744a12b0e7f9d5/dino8-app/'
def edit(path, pairs):
    s=open(R+path).read()
    for a,b,*cnt in pairs:
        n=cnt[0] if cnt else 1
        assert s.count(a)==n,(path,a,s.count(a))
        s=s.replace(a,b)
    open(R+path,'w').write(s)

edit('src/io/FileSat.h',[
('''// ACIS SAT (.sat, text save file) exchange - a thin app layer over the kernel's
// ReadAcisSat/WriteAcisSat (dino8-kernel/src/acis_sat.cpp). Read''','''// ACIS SAT (.sat, text save file) and SAB (.sab, binary save file) exchange - a thin
// app layer over the kernel's ReadAcis/WriteAcisSat/WriteAcisSab (dino8-kernel/src/acis_sat.cpp). The
// SAB byte layout is UNVERIFIED (no public prose for it was reachable); see the kernel header. Read'''),
('''// Reads every body of a .sat file as a Brep object.''','''// Reads every body of a .sat or .sab file as a Brep object (the encoding is detected from the file's first bytes,
// so a .sat file that holds SAB bytes, or the reverse, still opens; the summary says which encoding was read).'''),
('''bool ExportSat(const Document& doc, const std::string& path, bool selected_only, std::string& error);''','''bool ExportSat(const Document& doc, const std::string& path, bool selected_only, std::string& error);

// Same as ExportSat but writes the binary (.sab) encoding of the same records. The byte layout is UNVERIFIED and has only
// been read back by this program's own reader; the summary says so.
bool ExportSab(const Document& doc, const std::string& path, bool selected_only, std::string& error);'''),
])

edit('src/io/FileSat.cpp',[
('''#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
''','''#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
'''),
('''}  // namespace

bool ImportSat(Document& doc, const std::string& path, std::string& summary) {
  summary.clear();
  const std::string file = std::filesystem::path(path).filename().string();
  kernel::AcisSatOptions strict;
  kernel::AcisSatReadResult res = kernel::ReadAcisSat(path, strict);''','''const char* const kSabNote =
    "SAB status: the binary token tags, header layout and two-valued-word encoding are UNVERIFIED (no public description of the byte layout "
    "was reachable; they are recollection plus first-principles choices). The reader and writer have only been tested against each other, "
    "never against a file from a real ACIS-based product (see dino8-kernel/docs/ACIS_SAT_NOTES.md).";

// True when the file starts with the SAB signature.
bool FileIsSab(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  char head[16] = {};
  f.read(head, 15);
  return f.gcount() == 15 && kernel::LooksLikeAcisSab(std::string(head, 15));
}

}  // namespace

bool ImportSat(Document& doc, const std::string& path, std::string& summary) {
  summary.clear();
  const std::string file = std::filesystem::path(path).filename().string();
  const bool binary = FileIsSab(path);
  const char* const fmt = binary ? "SAB" : "SAT";
  kernel::AcisSatOptions strict;
  kernel::AcisSatReadResult res = kernel::ReadAcis(path, strict);'''),
('''    kernel::AcisSatReadResult second = kernel::ReadAcisSat(path, relaxed);''','''    kernel::AcisSatReadResult second = kernel::ReadAcis(path, relaxed);'''),
('''    summary = "SAT import refused (" + file + "): " +''','''    summary = std::string(fmt) + " import refused (" + file + "): " +'''),
('''  os << "SAT import " << file << ": " << res.bodies.size() << " Brep body(ies) read";''','''  os << fmt << " import " << file << ": " << res.bodies.size() << " Brep body(ies) read";'''),
('''  os << "\\n" << kLayoutNote;
  summary = os.str();
  return true;
}

bool ExportSat(const Document& doc, const std::string& path, bool selected_only, std::string& error) {''','''  os << "\\n" << kLayoutNote;
  if (binary) os << "\\n" << kSabNote;
  summary = os.str();
  return true;
}

namespace {

bool ExportAcis(const Document& doc, const std::string& path, bool selected_only, std::string& error, bool binary) {
  const char* const fmt = binary ? "SAB" : "SAT";'''),
('''      refused.push_back(nm + " (" + ObjectKindName(o.kind) + "): SAT export writes Brep bodies only; this object kind has no body representation here");''','''      refused.push_back(nm + " (" + ObjectKindName(o.kind) + "): " + fmt + " export writes Brep bodies only; this object kind has no body representation here");'''),
('''        w = kernel::WriteAcisSat(scratch, {*body}, opt);''','''        w = binary ? kernel::WriteAcisSab(scratch, {*body}, opt) : kernel::WriteAcisSat(scratch, {*body}, opt);'''),
('''    error = "SAT export wrote nothing (" + path + "). Refused:";''','''    error = std::string(fmt) + " export wrote nothing (" + path + "). Refused:";'''),
('''    w = kernel::WriteAcisSat(path, bodies, opt);''','''    w = binary ? kernel::WriteAcisSab(path, bodies, opt) : kernel::WriteAcisSat(path, bodies, opt);'''),
('''  if (!w.ok) { error = "SAT export failed (" + path + "): " + w.error; return false; }''','''  if (!w.ok) { error = std::string(fmt) + " export failed (" + path + "): " + w.error; return false; }'''),
('''  os << "SAT export " << std::filesystem::path(path).filename().string() << " (ACIS 7.0 text, version 700): " << ok.size()''','''  os << fmt << " export " << std::filesystem::path(path).filename().string() << (binary ? " (ACIS 7.0 binary, version 700): " : " (ACIS 7.0 text, version 700): ") << ok.size()'''),
('''  os << "\\n" << kLayoutNote;
  error = os.str();
  return true;
}
''','''  os << "\\n" << kLayoutNote;
  if (binary) os << "\\n" << kSabNote;
  error = os.str();
  return true;
}

}  // namespace

bool ExportSat(const Document& doc, const std::string& path, bool selected_only, std::string& error) {
  return ExportAcis(doc, path, selected_only, error, false);
}

bool ExportSab(const Document& doc, const std::string& path, bool selected_only, std::string& error) {
  return ExportAcis(doc, path, selected_only, error, true);
}
'''),
])

edit('src/app/Application.cpp',[
('''  } else if (ext == ".sat") {
    ok = ImportSat(fresh, path, error);''','''  } else if (ext == ".sat" || ext == ".sab") {
    ok = ImportSat(fresh, path, error);'''),
('''  doc_.SetPath(ext == ".sat" ? std::string() : path);''','''  doc_.SetPath((ext == ".sat" || ext == ".sab") ? std::string() : path);'''),
('''  // A .sat export writes only the Brep bodies it can express, so a plain Save must never overwrite the source .sat in place:''','''  // A .sat/.sab export writes only the Brep bodies it can express, so a plain Save must never overwrite the source file in place:'''),
('''  } else if (ext == ".sat") {
    ok = ExportSat(doc_, path, false, error);
    if (ok) { Notify("Exported " + path); if (!error.empty()) Notify(error); error.clear(); }''','''  } else if (ext == ".sat" || ext == ".sab") {
    ok = ext == ".sab" ? ExportSab(doc_, path, false, error) : ExportSat(doc_, path, false, error);
    if (ok) { Notify("Exported " + path); if (!error.empty()) Notify(error); error.clear(); }'''),
('''  } else if (ext == ".sat") {
    ok = ImportSat(doc_, path, error);''','''  } else if (ext == ".sat" || ext == ".sab") {
    ok = ImportSat(doc_, path, error);'''),
('''  if (ext == ".sat") {
    const bool ok = ExportSat(doc_, path, true, error);''','''  if (ext == ".sat" || ext == ".sab") {
    const bool ok = ext == ".sab" ? ExportSab(doc_, path, true, error) : ExportSat(doc_, path, true, error);'''),
])
edit('src/compare/DwgCompare.cpp',[('''  if (ext == ".sat") return ImportSat(out, path, error);''','''  if (ext == ".sat" || ext == ".sab") return ImportSat(out, path, error);''')])
edit('src/commands/cmd_file.cpp',[
('''".igs", ".iges", ".stp", ".step", ".sat", ".ifc", ".xyz", ".pts", ".las"};
const std::vector<std::string> kExportExts''','''".igs", ".iges", ".stp", ".step", ".sat", ".sab", ".ifc", ".xyz", ".pts", ".las"};
const std::vector<std::string> kExportExts'''),
('''".stp", ".step", ".sat", ".ifc", ".xyz", ".pts", ".las"};
''','''".stp", ".step", ".sat", ".sab", ".ifc", ".xyz", ".pts", ".las"};
''',1),
('''  if (ext == ".sat") return ExportSat(doc, path, true, error);''','''  if (ext == ".sat") return ExportSat(doc, path, true, error);
  if (ext == ".sab") return ExportSab(doc, path, true, error);'''),
])
