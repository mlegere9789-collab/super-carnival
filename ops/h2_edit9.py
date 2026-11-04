S = '/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad/'
for p in [S + 'h2r_section.sh', '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/tests/smoke.sh']:
    s = open(p).read()
    a = "'exact fillet \\(radius 2\\)$' 2 \"H2R_off control: with History Off (the N1 box and the fresh X1 control)"
    assert a in s, p
    s = s.replace(a, "'exact fillet \\(radius 2\\)$' 3 \"H2R_off control: with History Off (the N1 box and the fresh X1 and X4 controls)")
    b = """# Off records nothing, a source rotated so the edge signature no longer exists is
# refused with the reason and the old result is kept, Rho fillet / angle chamfer / a
# Project that splits into pieces / a Cap of a closed solid record nothing."""
    assert b in s, p
    s = s.replace(b, """# Off records nothing, a rotated source is still followed (edge re-found by its position
# in the edge list, dihedral angle and relative length), a source chamfered on the very
# edge that was filleted makes the rebuild refuse with the reason and keep the old result,
# Rho fillet / angle chamfer / a Project that splits into pieces / a Cap of a closed solid
# record nothing.""")
    open(p, 'w').write(s)
print('ok')
