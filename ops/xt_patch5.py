import sys
p = sys.argv[1] + '/src/parasolid_xt.cpp'
s = open(p).read()
i = s.index('      if (solid && std::getenv("XT_DEBUG_SKIP_VOL") == nullptr) {')
j = s.index('      if (approx) r.warnings.push_back')
new = '''      if (solid) {
        // Brep::Volume() relies on the class's per-face side tables to tessellate curved TRIMMED faces watertight;
        // a Brep assembled from a raw ON_Brep (as here, and as a .3dm reload) may not close, in which case the
        // enclosed volume is measured on a fine adaptive tessellation instead (sign and magnitude check only).
        double vol = 0;
        bool exact = true;
        try {
          vol = out.Volume();
        } catch (const std::exception&) {
          exact = false;
          try {
            vol = out.TessellateToClosedMeshAdaptive(1e-6 * std::max(1.0, ref_size(out))).Volume();
          } catch (const std::exception& ex2) {
            r.warnings.push_back(tag + "skipped: enclosed volume could not be evaluated: " + ex2.what());
            skipped.push_back(tag + "volume could not be evaluated");
            continue;
          }
        }
        if (!(vol > 0)) {
          r.warnings.push_back(tag + "skipped: solid body has non-positive volume (" + std::to_string(vol) + "): inside-out or degenerate");
          skipped.push_back(tag + "non-positive volume");
          continue;
        }
        if (!exact) r.warnings.push_back(tag + "Brep::Volume() is unavailable for this imported Brep (curved trimmed faces); orientation validated on an adaptive tessellation");
      }
'''
s = s[:i] + new + s[j:]
s = s.replace('#include "dino8/kernel/parasolid_xt.h"\n', '#include "dino8/kernel/parasolid_xt.h"\n\n#include "dino8/kernel/mesh.h"\n', 1)
s = s.replace('ParasolidXtReadResult ReadParasolidXtString(const std::string& text, const ParasolidXtOptions& options) {', '''namespace {
double ref_size(const Brep& b) {
  const ON_BoundingBox bb = b.raw().BoundingBox();
  return bb.IsValid() ? bb.Diagonal().Length() : 1.0;
}
}  // namespace

ParasolidXtReadResult ReadParasolidXtString(const std::string& text, const ParasolidXtOptions& options) {''', 1)
open(p, 'w').write(s)
