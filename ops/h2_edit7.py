p = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/src/commands/cmd_fillet.cpp'
s = open(p).read()

def rep(old, new, cnt=1):
    global s
    assert s.count(old) == cnt, (s.count(old), old[:80])
    s = s.replace(old, new)

rep('''  ON_3dPoint rel;  // midpoint relative to the solid's bounding box
  ON_3dVector dir, na, nb;
};''', '''  ON_3dPoint rel;  // midpoint relative to the solid's bounding box
  ON_3dVector dir, na, nb;
  // Rotation- and uniform-scale-invariant fallback identity (used only when no edge matches the
  // geometry above, e.g. after the solid was Rotated): the edge's index and the solid's edge count,
  // the cosine of the dihedral angle and the edge length relative to the mean edge length.
  int index = -1, count = 0;
  double dih = 0, lenrel = 0;
};

double MeanEdgeLength(const ON_Brep& b) {
  double sum = 0;
  int n = 0;
  for (int i = 0; i < b.m_E.Count(); ++i) { sum += b.m_E[i].PointAtStart().DistanceTo(b.m_E[i].PointAtEnd()); ++n; }
  return n ? sum / n : 0.0;
}''')

rep('bool EdgeSignatureOf(const ON_Brep& b, int ei, EdgeSig& s, std::string& why) {',
    'bool EdgeSignatureOf(const ON_Brep& b, int ei, EdgeSig& s, std::string& why, double mean_len = -1.0) {')
rep('''  s.rel = ON_3dPoint(rel(s.mid.x, ctr.x, bb.m_min.x, bb.m_max.x), rel(s.mid.y, ctr.y, bb.m_min.y, bb.m_max.y), rel(s.mid.z, ctr.z, bb.m_min.z, bb.m_max.z));
  return true;''', '''  s.rel = ON_3dPoint(rel(s.mid.x, ctr.x, bb.m_min.x, bb.m_max.x), rel(s.mid.y, ctr.y, bb.m_min.y, bb.m_max.y), rel(s.mid.z, ctr.z, bb.m_min.z, bb.m_max.z));
  if (mean_len < 0) mean_len = MeanEdgeLength(b);
  s.index = ei;
  s.count = b.m_E.Count();
  s.dih = ON_DotProduct(s.na, s.nb);
  s.lenrel = mean_len > 1e-12 ? len / mean_len : 0.0;
  return true;''')

rep('''  num[EdgeKey(k, "g")] = group;
}''', '''  num[EdgeKey(k, "g")] = group;
  num[EdgeKey(k, "i")] = s.index;
  num[EdgeKey(k, "c")] = s.count;
  num[EdgeKey(k, "dh")] = s.dih;
  num[EdgeKey(k, "lr")] = s.lenrel;
}''')

rep('''  return get3("r", s.rel.x, s.rel.y, s.rel.z) && get3("m", s.mid.x, s.mid.y, s.mid.z) && get3("d", s.dir.x, s.dir.y, s.dir.z) &&
         get3("a", s.na.x, s.na.y, s.na.z) && get3("b", s.nb.x, s.nb.y, s.nb.z);
}''', '''  auto get1 = [&](const char* f, double dflt) { const auto it = num.find(EdgeKey(k, f)); return it == num.end() ? dflt : it->second; };
  s.index = static_cast<int>(get1("i", -1));
  s.count = static_cast<int>(get1("c", 0));
  s.dih = get1("dh", 0);
  s.lenrel = get1("lr", 0);
  return get3("r", s.rel.x, s.rel.y, s.rel.z) && get3("m", s.mid.x, s.mid.y, s.mid.z) && get3("d", s.dir.x, s.dir.y, s.dir.z) &&
         get3("a", s.na.x, s.na.y, s.na.z) && get3("b", s.nb.x, s.nb.y, s.nb.z);
}''')

rep('int FindEdgeBySignature(const ON_Brep& b, const EdgeSig& want, std::string& why) {',
    'int FindEdgeBySignature(const ON_Brep& b, const EdgeSig& want, std::string& why, bool* by_index = nullptr) {')
rep('''  std::vector<std::pair<double, int>> cand;
  for (int i = 0; i < b.m_E.Count(); ++i) {
    EdgeSig s;
    std::string ignore;
    if (!EdgeSignatureOf(b, i, s, ignore)) continue;''', '''  std::vector<std::pair<double, int>> cand;
  const double mean_len = MeanEdgeLength(b);
  for (int i = 0; i < b.m_E.Count(); ++i) {
    EdgeSig s;
    std::string ignore;
    if (!EdgeSignatureOf(b, i, s, ignore, mean_len)) continue;''')
rep('''  if (cand.empty()) { why = what + " no longer exists on the edited source: no edge has that direction between faces with those normals"; return -1; }''',
    '''  if (cand.empty()) {
    // Nothing has that direction and those normals. If the solid kept its topology and the same edge still has the
    // same dihedral angle and the same length relative to the mean edge length, the solid was re-oriented (rotated):
    // accept it by its position in the edge list, and say so.
    if (want.count > 0 && b.m_E.Count() == want.count && want.index >= 0 && want.index < b.m_E.Count()) {
      EdgeSig s;
      std::string ignore;
      if (EdgeSignatureOf(b, want.index, s, ignore, mean_len) && std::fabs(s.dih - want.dih) < 1e-3 && std::fabs(s.lenrel - want.lenrel) < 1e-3) {
        if (by_index) *by_index = true;
        return want.index;
      }
    }
    why = what + " no longer exists on the edited source: no edge has that direction between faces with those normals, and the solid's own edge " +
          std::to_string(want.index) + " no longer has the recorded dihedral angle and length";
    return -1;
  }''')

# message in the rebuild
rep('''      const int ei = FindEdgeBySignature(cur, want, reason);
      if (ei < 0) { why = "edge " + std::to_string(k + 1) + " of " + std::to_string(n) + ": " + reason; return std::nullopt; }
      es.emplace_back(Point3d(cur.m_E[ei].PointAtStart()), Point3d(cur.m_E[ei].PointAtEnd()));
      ctx.Print(rec.command + ": edge " + std::to_string(k + 1) + " re-found as edge " + std::to_string(ei) + " of the source (direction and both face normals match)");''',
    '''      bool by_index = false;
      const int ei = FindEdgeBySignature(cur, want, reason, &by_index);
      if (ei < 0) { why = "edge " + std::to_string(k + 1) + " of " + std::to_string(n) + ": " + reason; return std::nullopt; }
      es.emplace_back(Point3d(cur.m_E[ei].PointAtStart()), Point3d(cur.m_E[ei].PointAtEnd()));
      ctx.Print(rec.command + ": edge " + std::to_string(k + 1) + " re-found as edge " + std::to_string(ei) + " of the source (" +
                (by_index ? "the solid was re-oriented: same position in its edge list, same dihedral angle and relative length"
                          : "direction and both face normals match") + ")");''')
open(p, 'w').write(s)
print('ok')
