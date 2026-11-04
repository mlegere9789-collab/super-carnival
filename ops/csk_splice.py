p = '/home/user/miniature-pancake/.claude/worktrees/agent-a1461cbbcbfc614b8/dino8-app/src/commands/cmd_solidtools.cpp'
S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/csk_cmd.inc'
t = open(p).read()
inc = open(S).read()
marker = 'void RegisterSolidToolsCommands(CommandEngine& e) {'
assert t.count(marker) == 1
t = t.replace(marker, inc + marker)
reg = '  Reg(e, "RoundHole", Tool('
assert t.count(reg) == 1
new = '''  Reg(e, "CountersinkHole", Tool({ObjectsStep("Select the plate (an exact solid)"), PointStep("Point on the plate face for the hole"), NumberStep("Diameter", 6), NumberStep("Depth", 10)},
                                 {Toggle("Through", true), Numeric("CountersinkDiameter", 0), Numeric("Angle", 90)}, Guarded("CountersinkHole", [](CommandContext& ctx, const Input& in) { ExactHoleFeature(ctx, in, true); })),
      CommandStatus::Implemented,
      "Exact countersunk hole: a cone + cylinder cut from an exact B-rep plate by the kernel's sealed general Boolean (planes, cylinder and cone only, real inner loops, Check-valid closed solid). CountersinkDiameter (0 = twice the hole diameter) is the cone's diameter at the picked face, Angle its full included angle. Refuses, with the reason, a diameter that does not fit the face, a depth not less than the plate thickness, or a cone deeper than the hole. Mesh plates are refused (use RoundHole).");
  Reg(e, "CounterboreHole", Tool({ObjectsStep("Select the plate (an exact solid)"), PointStep("Point on the plate face for the hole"), NumberStep("Diameter", 6), NumberStep("Depth", 10)},
                                 {Toggle("Through", true), Numeric("CounterboreDiameter", 0), Numeric("CounterboreDepth", 3)}, Guarded("CounterboreHole", [](CommandContext& ctx, const Input& in) { ExactHoleFeature(ctx, in, false); })),
      CommandStatus::Implemented,
      "Exact counterbored hole: a cylinder in a cylinder cut from an exact B-rep plate by the kernel's sealed general Boolean (planes and cylinders only, real inner loops, Check-valid closed solid). CounterboreDiameter (0 = 1.6 times the hole diameter) and CounterboreDepth set the recess. Refuses, with the reason, a diameter that does not fit the face, a depth not less than the plate thickness, or a recess deeper than the hole. Mesh plates are refused (use RoundHole).");
'''
t = t.replace(reg, new + reg)
inc_line = '#include "commands/cmd_common.h"\n'
assert t.count(inc_line) == 1
t = t.replace(inc_line, inc_line + '#include "dino8/kernel/boolean_general.h"\n', 1)
open(p, 'w').write(t)
print('ok')
