p = 'dino8-kernel/tests/test_basic.cpp'
s = open(p).read()
a = '''  g_mesh_measure = false;
  RoundTrip("app-style sphere (ON_BrepSphere, UNVERIFIED layout)", WrapOn(ON_BrepSphere(ON_Sphere(ON_3dPoint(1, 2, 3), 4.0))), 2e-3, true, true);
'''
assert a in s
b = '''  g_mesh_measure = false;
  // ON_BrepSphere's face is an ON_RevSurface, which Brep::Volume()/TessellateToClosedMeshAdaptive cannot integrate, so the
  // source is not measured: the written file is read back and the result compared with the analytic sphere instead.
  {
    const Brep sph = WrapOn(ON_BrepSphere(ON_Sphere(ON_3dPoint(1, 2, 3), 4.0)));
    std::ostringstream os;
    dino8::kernel::AcisSatOptions opt;
    opt.allow_unverified_layouts = true;
    const auto w = dino8::kernel::WriteAcisSat(os, {sph}, opt);
    Check(w.ok, "AcisSat: app-style sphere (ON_BrepSphere, UNVERIFIED layout) writes without refusal");
    if (!w.ok) std::fprintf(stderr, "  write refused: %s\\n", w.error.c_str());
    const AcisSatReadResult r = ReadText(w.ok ? os.str() : std::string(), true);
    Check(w.ok && r.ok && r.bodies.size() == 1 && r.bodies[0].FaceCount() == 1, "AcisSat: app-style sphere reads back as one one-face body");
    if (r.ok && r.bodies.size() == 1) {
      const double V = 4.0 / 3.0 * ON_PI * 64.0, A = 4.0 * ON_PI * 16.0;
      std::printf("  app-style sphere (ON_BrepSphere) read back: volume %.12g (analytic %.12g), area %.12g (analytic %.12g)\\n", r.bodies[0].Volume(), V,
                  r.bodies[0].Area(), A);
      Check(Near(r.bodies[0].Volume(), V, V * 2e-3) && Near(r.bodies[0].Area(), A, A * 2e-3), "AcisSat: app-style sphere read-back volume and area match 4/3 pi r^3 and 4 pi r^2 (2e-3)");
    }
  }
'''
s = s.replace(a, b)
open(p, 'w').write(s)
