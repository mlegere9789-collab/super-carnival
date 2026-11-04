p='/home/user/miniature-pancake/.claude/worktrees/agent-ad9fdba50f11440b3/dino8-kernel/src/fillet.cpp'
s=open(p).read()
def rep(old,new,cnt=1):
    global s
    assert s.count(old)==cnt,(old,s.count(old))
    s=s.replace(old,new)

rep("std::vector<std::array<double, 13>> Q;  // control rows: A xyz, w*M xyz + w, B xyz, centre xyz",
    "std::vector<std::array<double, 17>> Q;  // control rows: A xyz, w*M xyz + w, B xyz, centre xyz (periodic fit: + uv_a, uv_b)")
rep('''  const int m = 13;
  std::vector<double> A((size_t)N * N, 0.0), B((size_t)N * m, 0.0);
  for (int j = 0; j < N; ++j) {
    StationRow(st[(size_t)j], r, &B[(size_t)j * m]);''','''  const int m = 17;
  std::vector<double> A((size_t)N * N, 0.0), B((size_t)N * m, 0.0);
  for (int j = 0; j < N; ++j) {
    StationRow(st[(size_t)j], r, &B[(size_t)j * m]);
    B[(size_t)j * m + 13] = st[(size_t)j].uv_a.x; B[(size_t)j * m + 14] = st[(size_t)j].uv_a.y;
    B[(size_t)j * m + 15] = st[(size_t)j].uv_b.x; B[(size_t)j * m + 16] = st[(size_t)j].uv_b.y;''')

rep('''ON_NurbsCurve* FitCurve3(const Fit& fit, int c0) {''','''ON_NurbsCurve* FitCurve2Periodic(const Fit& fit, int c0) {
  const int N = fit.N;
  ON_NurbsCurve* c = new ON_NurbsCurve(2, false, 4, N + 3);
  for (int i = 0; i < N + 5; ++i) c->m_knot[i] = fit.U[(size_t)i + 1];
  for (int i = 0; i < N + 3; ++i) c->SetCV(i, ON_3dPoint(fit.Q[(size_t)i][(size_t)c0], fit.Q[(size_t)i][(size_t)c0 + 1], 0.0));
  return c;
}

ON_NurbsCurve* FitCurve3(const Fit& fit, int c0) {''')

rep('''      out.centre.raw() = *cen;''','''      out.centre.raw() = *cen;
      if (closed) {
        std::unique_ptr<ON_NurbsCurve> ta(FitCurve2Periodic(fit, 13)), tb(FitCurve2Periodic(fit, 15));
        out.trim_a.raw() = *ta;
        out.trim_b.raw() = *tb;
      }''')
open(p,'w').write(s)

h='/home/user/miniature-pancake/.claude/worktrees/agent-ad9fdba50f11440b3/dino8-kernel/include/dino8/kernel/fillet.h'
t=open(h).read()
t=t.replace("  NurbsCurve contact_a, contact_b, centre;\n","  NurbsCurve contact_a, contact_b, centre;\n  // CLOSED rims only: the contact curves as 2D periodic cubics in the parameter space of `a` and `b` (same parameter as contact_a / contact_b).\n  NurbsCurve trim_a, trim_b;\n",1)
open(h,'w').write(t)
print('ok')
