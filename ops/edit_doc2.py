p='dino8-kernel/include/dino8/kernel/brep.h'
s=open(p).read()
old="""  // station count. CLOSED rails with a corner are refused with a reason.
  // Always an UNCAPPED"""
new="""  // station count. CLOSED rails with a corner are refused with a reason.
  // The user's section anchors win over the corner pairing: a corner of ONE
  // rail only (its partner on the other rail is just the point at the same
  // arc-length fraction) never makes an input fail - a section anchored at
  // that corner makes that station the corner (the anchor defines the
  // partner), and when the derived partner does not fit between the
  // neighbouring anchors on the other rail that corner pair is dropped (the
  // wall cuts that corner, as without corner handling). Only a corner that
  // is genuinely on BOTH rails (matched) and conflicts with an anchor throws.
  // Always an UNCAPPED"""
assert old in s
s=s.replace(old,new,1)
open(p,'w').write(s)
