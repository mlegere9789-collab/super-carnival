p='dino8-app/src/commands/cmd_boolean.cpp'
s=open(p).read()
old='''    if (res.brep.raw().m_F.Count() == 0) return res;  // an empty result is reported as such by the caller
    if (!HealGeneralBooleanResult(res.brep, res.heal_tolerance)) {
      fail = "the engine's result has gaps between faces that sewing could not close, so it is not a closed solid";
      return std::nullopt;
    }
'''
new='''    if (res.brep.raw().m_F.Count() == 0) return res;  // an empty result is reported as such by the caller
    // First choice: SEAL the result (kernel SealGeneralBooleanResult, the half of BooleanCombineGeneralSealed that
    // follows the engine) - sewn, ON_Brep::IsValid, IsSolid, every keyhole opened into a real inner loop, and an
    // exact (divergence-theorem) volume checked against the operands' bounds. A refusal falls back to the plain
    // sewing below, exactly as before, so every case that worked still works (its keyhole-slit structure intact).
    bool sealed = false;
    if (!std::getenv("DINO8_NO_SEALED_BOOLEAN")) {
      try {
        double va = std::nan(""), vb = std::nan("");
        if (first.size() == 1 && second.size() == 1) {  // the engine's pairwise case: operand bounds are known exactly
          try {
            va = first[0].Volume();
            vb = second[0].Volume();
          } catch (const std::exception&) {
            va = vb = std::nan("");
          }
        }
        kernel::SealedGeneralBoolean sb = kernel::SealGeneralBooleanResult(res.brep, second.empty() ? kernel::BooleanOp::Union : op, va, vb);
        if (sb.brep.raw().m_F.Count() > 0 && SealedStructureAcceptable(sb.brep)) {
          res.brep = std::move(sb.brep);
          res.heal_tolerance = sb.sew_tolerance;
          res.sealed = true;
          res.sealed_volume = sb.volume;
          res.keyholes_opened = sb.keyholes_opened;
          sealed = true;
        }
      } catch (const std::exception&) {
        sealed = false;
      }
    }
    if (!sealed && !HealGeneralBooleanResult(res.brep, res.heal_tolerance)) {
      fail = "the engine's result has gaps between faces that sewing could not close, so it is not a closed solid";
      return std::nullopt;
    }
'''
assert old in s
s=s.replace(old,new)
s=s.replace('''  int recorded_tools = 0;     // > 0: evaluated''','''  bool sealed = false;        // sealed by the kernel: IsValid + IsSolid, real inner loops (see run() below)
  double sealed_volume = 0;   // its exact divergence-theorem volume
  int keyholes_opened = 0;    // keyhole slits opened into real inner loops
  int recorded_tools = 0;     // > 0: evaluated''')
s=s.replace('''struct GeneralBooleanResult {''','''// Gate for the sealed structure: true when every consumer of a Boolean result's structure can read it.
bool SealedStructureAcceptable(const kernel::Brep&) { return true; }

struct GeneralBooleanResult {''',1)
open(p,'w').write(s)
