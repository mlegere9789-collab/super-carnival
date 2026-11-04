#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
OUT=/home/user/miniature-pancake/.claude/worktrees/agent-ad9fdba50f11440b3/dino8-kernel/tests/surface_fillet_extra.cpp
{
cat <<'EOF'
// Dev harness (assembled): FilletSurfaces closed rims / refusals / boss-on-slab solid.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <string>
#include <vector>
#include "dino8/kernel/brep.h"
#include "dino8/kernel/fillet.h"
#include "dino8/kernel/surface_intersect.h"
#include "opennurbs.h"
namespace {
int g_failures = 0;
void Check(bool condition, const char* what) {
  if (!condition) { std::fprintf(stderr, "FAILED: %s\n", what); ++g_failures; } else { std::printf("ok: %s\n", what); }
}
}
EOF
cat $S/helpers.txt
cat $S/newtests.txt
cat <<'EOF'
}  // namespace surface_fillet_tests
int main(int argc, char** argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  ON::Begin();
  const char* only = argc > 1 ? argv[1] : "";
  auto run = [&](const char* n, void (*fn)()) {
    if (*only && !std::strstr(n, only)) return;
    try { fn(); } catch (const std::exception& e) { std::fprintf(stderr, "FAILED: %s threw %s\n", n, e.what()); ++g_failures; }
  };
  run("Stub", surface_fillet_tests::TestSurfaceFilletRefusalBranchesAndStubOddity);
  run("Closed", surface_fillet_tests::TestSurfaceFilletClosedRimBossOnFloor);
  run("Solid", surface_fillet_tests::TestFilletBossOnSlabClosedSolid);
  ON::End();
  std::printf("failures: %d\n", g_failures);
  return g_failures ? 1 : 0;
}
EOF
} > $OUT
