p='dino8-kernel/tests/test_basic.cpp'
s=open(p).read()
new=open('/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/newtests_fix.txt').read()
marker="}  // namespace sweep_closure_tests\n"
assert s.count(marker)==1
s=s.replace(marker,new.lstrip('\n')+"\n"+marker)
reg_old='''          sweep_closure_tests::TestSweep1TwistOnAClosedRailIsAllowedForWholeTurns);
'''
reg_new=reg_old+'''  RunTest("sweep_closure_tests::TestSweep2CornerPairingIgnoresASpuriousExtraKink",
          sweep_closure_tests::TestSweep2CornerPairingIgnoresASpuriousExtraKink);
  RunTest("sweep_closure_tests::TestSweep2SectionsAnchorsWinOverOneRailOnlyCorners",
          sweep_closure_tests::TestSweep2SectionsAnchorsWinOverOneRailOnlyCorners);
  RunTest("sweep_closure_tests::TestSweep1ClosedRailTwistStepIsBounded",
          sweep_closure_tests::TestSweep1ClosedRailTwistStepIsBounded);
  RunTest("sweep_closure_tests::TestSweep1SectionsClosedRailVaryingSectionsMatchAnIndependentPeriodicBlend",
          sweep_closure_tests::TestSweep1SectionsClosedRailVaryingSectionsMatchAnIndependentPeriodicBlend);
'''
assert s.count(reg_old)==1
s=s.replace(reg_old,reg_new)
open(p,'w').write(s)
