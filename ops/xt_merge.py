import sys
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
p = sys.argv[1] + '/src/parasolid_xt.cpp'
s = open(p).read()
r = open(S + 'xt_reader.inc').read()
assert '//@@READER@@\n' in s
s = s.replace('//@@READER@@\n', r)
a = '''    if (face.m_li.Count() == 0) {
      if (!(d.type == kSphere || d.type == kTorus) || !(srf->IsClosed(0) && srf->IsClosed(1) || srf->IsClosed(0))) {
        return tag + "face " + std::to_string(f) + " has no boundary loops and is not a closed sphere/torus (untrimmed patch cannot be expressed)";
      }
      continue;
    }'''
b = '''    const bool closed_round = (d.type == kSphere || d.type == kTorus) && srf->IsClosed(0);
    if (face.m_li.Count() == 0) {
      if (!closed_round) return tag + "face " + std::to_string(f) + " has no boundary loops and is not a closed sphere/torus (untrimmed patch cannot be expressed)";
      continue;
    }'''
assert a in s
s = s.replace(a, b)
a = '''    for (const auto& lp : fo.loops)
      for (const FinRec& fr : lp) used_edges.insert(fr.edge);
  }'''
b = '''    if (fo.loops.empty() && !closed_round)
      return tag + "face " + std::to_string(f) + " has only seam/singular trims and is not a closed sphere/torus";
    for (const auto& lp : fo.loops)
      for (const FinRec& fr : lp) used_edges.insert(fr.edge);
  }'''
assert a in s
s = s.replace(a, b)
open(p, 'w').write(s)
c = sys.argv[1] + '/CMakeLists.txt'
t = open(c).read()
if 'src/parasolid_xt.cpp' not in t:
    t = t.replace('  src/iges.cpp\n', '  src/iges.cpp\n  src/parasolid_xt.cpp\n', 1)
    open(c, 'w').write(t)
