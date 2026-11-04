S = "/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/"
W = "/home/user/miniature-pancake/.claude/worktrees/agent-affecf0689743ce29/dino8-kernel/"
head = '''#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include "dino8/kernel/brep.h"
#include "dino8/kernel/curve.h"
#include "dino8/kernel/surface.h"
#include "opennurbs.h"
namespace {
int g_failures = 0;
void Check(bool c, const char* w) { if (!c) { std::fprintf(stderr, "FAILED: %s\\n", w); ++g_failures; } else std::printf("ok: %s\\n", w); }
}
'''
tests = open(S + 'surfops_tests.txt').read()
main = '''
int main() {
  ON::Begin();
  surfops_tolerance_tests::TestCurveRemoveMultiKnotsErrorBoundAndBudget();
  surfops_tolerance_tests::TestSurfaceRemoveMultiKnotsBothDirections();
  surfops_tolerance_tests::TestSurfaceFitToToleranceMeetsToleranceOnIndependentGrid();
  surfops_tolerance_tests::TestBrepShrinkSurfacesTolerance();
  ON::End();
  std::printf("failures=%d\\n", g_failures);
  return g_failures ? 1 : 0;
}
'''
open(W + 'tests/scratch_test.cpp', 'w').write(head + tests + main)
