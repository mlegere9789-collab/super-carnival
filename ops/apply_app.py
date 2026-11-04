S = "/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/"
p = "/home/user/miniature-pancake/.claude/worktrees/agent-affecf0689743ce29/dino8-app/src/commands/cmd_srfedit.cpp"
s = open(p).read()
a = s.index("void ShrinkTrimmed(CommandContext& ctx")
b = s.index("void CreateUVCrv(")
s = s[:a] + open(S + 'app_srf_new.txt').read() + s[b:]
anchor = "class RebuildUVCommand : public Command {"
assert s.count(anchor) == 1
s = s.replace(anchor, open(S + 'app_fit_new.txt').read() + anchor)
old = '  Reg(e, "FitSrf", Immediate([](CommandContext& ctx) { ctx.Engine().Execute("Rebuild"); }));\n'
assert s.count(old) == 1
s = s.replace(old, '  Reg(e, "FitSrf", Make<FitSrfCommand>());\n')
open(p, 'w').write(s)
print("applied")
