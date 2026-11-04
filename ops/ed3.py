p='dino8-kernel/src/boolean_general.cpp'
s=open(p).read()
a=s.index("// Exact volume of a sealed solid whose faces may be analytic")
b=s.index("}  // namespace\n\nint OpenSewnKeyholes")
s=s[:a]+s[b:]
s=s.replace("SealedVolumeOfAnalyticFaces(c)","c.VolumeOfSealedSolid()")
open(p,'w').write(s)
