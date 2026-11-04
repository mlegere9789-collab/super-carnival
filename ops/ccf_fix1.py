S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = S + 'ccf_rr_tests.inc'
s = open(p).read()
def rep(a, b):
    global s
    assert a in s, a
    s = s.replace(a, b)
rep("std::fabs(plate.Volume() - v0) < 1e-9 * v0, (\"[countersink] fixture volume \"", "std::fabs(plate.Volume() - v0) < 1e-6 * v0, (\"[countersink] fixture volume \"")
rep('''    Check(std::fabs((v0 - res.Volume()) - removed) < 1e-6 * removed,
          ("[plate outer rim] removed volume " + std::to_string(v0 - res.Volume()) + " vs Pappus closed form " + std::to_string(removed)).c_str());''',
'''    // Brep::Volume() is a numerical quadrature (~1e-7 relative on these parts): compare the ABSOLUTE volumes at 1e-6 of the part.
    Check(std::fabs(res.Volume() - (v0 - removed)) < 1e-6 * v0,
          ("[plate outer rim] volume " + std::to_string(res.Volume()) + " vs sharp-plate closed form minus the Pappus removal " + std::to_string(v0 - removed)).c_str());''')
rep("std::fabs(sh.Volume() - v0) < 1e-9 * v0", "std::fabs(sh.Volume() - v0) < 1e-6 * v0")
rep('''    Check(std::fabs((res.Volume() - v0) - added) < 1e-6 * added,
          ("[shaft inside corner] ADDED volume " + std::to_string(res.Volume() - v0) + " vs closed form " + std::to_string(added)).c_str());''',
'''    Check(std::fabs(res.Volume() - (v0 + added)) < 1e-6 * v0 && res.Volume() > v0,
          ("[shaft inside corner] volume " + std::to_string(res.Volume()) + " vs sharp closed form + ADDED closed form " + std::to_string(v0 + added)).c_str());''')
rep("std::fabs(res.Volume() - vch) < 1e-9 * vch", "std::fabs(res.Volume() - vch) < 1e-6 * vch")
rep('''  m = Reason([&] { FilletRevolveRim(Brep::Box(0, 0, 0, 1, 1, 1), Point3d(1, 0, 0), 0.1); });
  Check(m.find("no cylindrical or conical face") != std::string::npos, ("[box] refused with a reason: " + m).c_str());''',
'''  m = Reason([&] { FilletRevolveRim(Brep::BoxWelded(0, 0, 0, 1, 1, 1), Point3d(1, 0, 0), 0.1); });
  Check(m.find("no cylindrical or conical face") != std::string::npos, ("[welded box] refused with a reason: " + m).c_str());
  m = Reason([&] { FilletRevolveRim(Brep::Box(0, 0, 0, 1, 1, 1), Point3d(1, 0, 0), 0.1); });
  Check(m.find("not a closed solid") != std::string::npos, ("[surface-only box] refused with a reason: " + m).c_str());''')
open(p, 'w').write(s)
