p='dino8-kernel/include/dino8/kernel/brep.h'
s=open(p).read()
old="""  // closed rail throws (it would leave a step at the seam), as does a
  // twist_schedule.
"""
new="""  // closed rail throws (it would leave a step at the seam). The twist
  // BETWEEN consecutive stations must also stay within 30 degrees (the
  // nothing-checks-the-copies aliasing guard: a whole-turn twist spread
  // over too few stations would alias, at one turn per station every copy
  // is the untwisted section) - a larger per-station step throws, naming
  // the angle and about how many stations would do; `stations` is NOT
  // raised automatically.
"""
assert old in s
s=s.replace(old,new,1)
old2="""  // rail1 is paired with the i-th corner of rail2 (unequal counts: each
  // corner is paired with the point of the other rail at the same
  // arc-length fraction of the whole rail); the stations are packed per
"""
new2="""  // rail1 is paired with the i-th corner of rail2. With unequal counts the
  // corners are MATCHED in order (never crossing) on the proximity of their
  // arc-length fractions of the whole rail (within 5% of the rail; most
  // matches first, then the least total fraction distance), so an extra or
  // spurious kink on one rail cannot displace the real corner pairs; a
  // corner left unmatched is a corner of one rail only and is paired with
  // the other rail's point at the same arc-length fraction (clamped to stay
  // between its neighbouring pairs). The stations are packed per
"""
assert old2 in s
s=s.replace(old2,new2,1)
open(p,'w').write(s)
