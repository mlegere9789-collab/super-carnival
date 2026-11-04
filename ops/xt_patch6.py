import sys
root = sys.argv[1]
p = root + '/src/parasolid_xt.cpp'
s = open(p).read()

# writer header
i = s.index('std::string Header() {')
j = s.index('// ---------------------------------------------------------------------------\n// Small vector helpers')
newh = r'''std::string Header() {
  // Deliberately NOT the real Parasolid signature lines: this is a private encoding (see the file comment above).
  std::string s;
  s += "**DINO8-XT-PROFILE: private clean-room encoding modelled on the XT topology/geometry vocabulary - NOT readable by Parasolid\n";
  s += "**PART1;\nAPPL=Dino 8 kernel (private XT-like profile);\nFORMAT=text;\nGUISE=transmit;\n";
  s += std::string("**PART2;\nSCH=") + kSchemaName + ";\nUSFLD_SIZE=0;\n**PART3;\n";
  s += "**END_OF_HEADER*****************************************************\n";
  return s;
}

'''
s = s[:i] + newh + s[j:]

a = '''    if (ln == 1 && line.rfind("**ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0) != 0) return "not a Parasolid text transmit file (missing '**ABC...' signature line)";
    if (ln == 2 && line.rfind("**PARASOLID", 0) != 0) return "not a Parasolid text transmit file (missing '**PARASOLID' line)";'''
b = '''    if (ln == 1 && line.rfind("**ABCDEFGHIJKLMNOPQRSTUVWXYZ", 0) == 0)
      return "this is a real Parasolid transmit file; reading real Parasolid schemas is NOT implemented because the XT Format Reference "
             "could not be obtained in this environment (see docs/PARASOLID_XT_NOTES.md) - refusing rather than guessing field layouts";
    if (ln == 1 && line.rfind("**DINO8-XT-PROFILE", 0) != 0) return "not a Dino 8 XT-profile file (missing '**DINO8-XT-PROFILE' signature line)";'''
assert a in s
s = s.replace(a, b)

a = '''  if (schema != kSchemaName)
    return "unsupported schema '" + schema + "' (this reader implements only the Dino 8 profile " + kSchemaName +
           "; real Parasolid schemas need the published schema tables, see docs/PARASOLID_XT_NOTES.md)";'''
b = '''  if (schema != kSchemaName)
    return "unsupported schema '" + schema + "' (this reader implements only the private Dino 8 profile " + kSchemaName +
           "; real Parasolid schemas are not implemented, see docs/PARASOLID_XT_NOTES.md)";'''
assert a in s
s = s.replace(a, b)

a = '''// Parasolid XT text (.x_t) reader/writer - see include/dino8/kernel/parasolid_xt.h
// and docs/PARASOLID_XT_NOTES.md for the (important) clean-room status: the
// node layouts below are this project's own reduced profile, schema name
// "SCH_DINO8_1", NOT verified against Siemens' published reference.'''
b = '''// XT-style text transmit reader/writer - see include/dino8/kernel/parasolid_xt.h
// and docs/PARASOLID_XT_NOTES.md for the (important) status: the public XT
// Format Reference could not be fetched, so the node layouts below are this
// project's OWN private profile (schema name "SCH_DINO8_1"). Every node type
// code and field list here is UNVERIFIED against Siemens' reference and the
// files are NOT interchangeable with Parasolid.'''
assert a in s
s = s.replace(a, b)
open(p, 'w').write(s)

h = root + '/include/dino8/kernel/parasolid_xt.h'
t = open(h).read()
i = t.index('// Parasolid XT (text, .x_t) reader / writer')
j = t.index('#include <iosfwd>')
newc = '''// XT-style text transmit reader / writer for solid and sheet bodies.
//
// STATUS - READ docs/PARASOLID_XT_NOTES.md FIRST. The public Parasolid XT
// Format Reference could NOT be fetched from the build environment (the hosts
// that carry it are blocked), so no real XT field layout could be verified.
// What this module implements is therefore a PRIVATE profile that borrows the
// XT topology vocabulary (body, region, shell, face, loop, fin, edge, vertex,
// point; plane, cylinder, cone, sphere, torus, B-surface; line, circle,
// ellipse, B-curve), declares the schema name "SCH_DINO8_1" and starts with a
// "**DINO8-XT-PROFILE" line. It is NOT Parasolid-compatible in either
// direction: a real Parasolid transmit file (its first line is the
// "**ABCDEFGHIJ..." signature) is REFUSED with a reason, and a file written
// here cannot be read by Parasolid. Every node type code / field list in
// parasolid_xt.cpp is UNVERIFIED against the reference. The API names are kept
// so that, once the reference is obtained, real schemas can be added behind
// the same entry points.
//
// Reader scope: bodies made of planar / cylindrical / conical / spherical /
// toroidal / B-spline faces bounded by line / circle / ellipse / B-spline
// edges. Anything else is refused (whole file) or skipped (one body) with a
// reason string; nothing is silently approximated into a bad body.

'''
t = t[:i] + newc + t[j:]
open(h, 'w').write(t)
