p='dino8-app/src/commands/cmd_boolean.cpp'
s=open(p).read()
s=s.replace('''// Gate for the sealed structure: true when every consumer of a Boolean result's structure can read it.
bool SealedStructureAcceptable(const kernel::Brep&) { return true; }

''','')
s=s.replace("if (sb.brep.raw().m_F.Count() > 0 && SealedStructureAcceptable(sb.brep)) {","if (sb.brep.raw().m_F.Count() > 0) {")
open(p,'w').write(s)
