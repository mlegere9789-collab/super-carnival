def sub(s, a, b, cnt=1):
    assert s.count(a) == cnt, (a, s.count(a))
    return s.replace(a, b)

p = 'src/app/Application.cpp'
s = open(p).read()
s = sub(s, '''  } else if (ext == ".stp" || ext == ".step") {
    ok = ImportStep(fresh, path, error);
  } else {''', '''  } else if (ext == ".stp" || ext == ".step") {
    ok = ImportStep(fresh, path, error);
  } else if (ext == ".sat") {
    ok = ImportSat(fresh, path, error);
  } else {''')
s = sub(s, '''  } else if (ext == ".stp" || ext == ".step") {
    ok = ExportStep(doc_, path, false, error);
    if (ok) Notify("Exported " + path);
''', '''  } else if (ext == ".stp" || ext == ".step") {
    ok = ExportStep(doc_, path, false, error);
    if (ok) Notify("Exported " + path);
  } else if (ext == ".sat") {
    ok = ExportSat(doc_, path, false, error);
    if (ok) { Notify("Exported " + path); if (!error.empty()) Notify(error); error.clear(); }
''')
s = sub(s, '''  } else if (ext == ".stp" || ext == ".step") {
    ok = ImportStep(doc_, path, error);
  } else if (ext == ".ifc") {''', '''  } else if (ext == ".stp" || ext == ".step") {
    ok = ImportStep(doc_, path, error);
  } else if (ext == ".sat") {
    ok = ImportSat(doc_, path, error);
  } else if (ext == ".ifc") {''')
s = sub(s, '''  if (ext == ".stp" || ext == ".step") return ExportStep(doc_, path, true, error);
  if (ext == ".ifc") return ExportIfc(doc_, path, true, error);''', '''  if (ext == ".stp" || ext == ".step") return ExportStep(doc_, path, true, error);
  if (ext == ".sat") {
    const bool ok = ExportSat(doc_, path, true, error);
    if (ok) { if (!error.empty()) Notify(error); error.clear(); }  // ExportSat's success text is a summary, not an error
    return ok;
  }
  if (ext == ".ifc") return ExportIfc(doc_, path, true, error);''')
open(p, 'w').write(s)

p = 'src/commands/cmd_file.cpp'
s = open(p).read()
s = sub(s, '".stp", ".step", ".ifc", ".xyz", ".pts", ".las"};', '".stp", ".step", ".sat", ".ifc", ".xyz", ".pts", ".las"};', 2)
s = sub(s, '''  if (ext == ".stp" || ext == ".step") return ExportStep(doc, path, true, error);
  if (ext == ".ifc") return ExportIfc(doc, path, true, error);''', '''  if (ext == ".stp" || ext == ".step") return ExportStep(doc, path, true, error);
  if (ext == ".sat") return ExportSat(doc, path, true, error);  // on success `error` holds the summary (printed by the caller)
  if (ext == ".ifc") return ExportIfc(doc, path, true, error);''')
s = sub(s, '''  if (ok) app.Notify("Exported " + path + " (origin at " + FormatPoint(origin) + ")");
  else app.Notify(error);''', '''  if (ok) {
    app.Notify("Exported " + path + " (origin at " + FormatPoint(origin) + ")");
    if (!error.empty()) app.Notify(error);  // ExportSat reports its summary through `error` on success
  } else app.Notify(error);''')
open(p, 'w').write(s)

p = 'src/compare/DwgCompare.cpp'
s = open(p).read()
s = sub(s, '''  if (ext == ".stp" || ext == ".step") return ImportStep(out, path, error);
  error = "Unsupported file type for compare''', '''  if (ext == ".stp" || ext == ".step") return ImportStep(out, path, error);
  if (ext == ".sat") return ImportSat(out, path, error);
  error = "Unsupported file type for compare''')
open(p, 'w').write(s)
