base = '/home/user/miniature-pancake/.claude/worktrees/agent-a508d8a59160094bb/dino8-app/src/commands/'
p = base + 'cmd_solids.cpp'
s = open(p).read()

start = s.index('  Reg(e, "Cap", OnSelection("Select open surfaces to cap"')
end_marker = '''      }), CommandStatus::Implemented, "Caps every planar closed naked-edge loop on each selected polysurface (one call handles multiple separate holes).");
'''
end = s.index(end_marker) + len(end_marker)
old = s[start:end]

# body of the per-object loop (between the 'continue;' on naked.empty() and the final caps_here>0 line)
b0 = old.index("          // Group the naked edges into their separate closed loops")
b1 = old.index("          if (caps_here > 0) {")
body = old[b0:b1]
# dedent by 4 spaces (it moves from lambda-in-loop depth 10 to function depth 6)
body = "\n".join((l[4:] if l.startswith("    ") else l) for l in body.split("\n"))
assert "int caps_here = 0;\n" in body
body = body.replace("          int caps_here = 0;\n", "", 1).replace("      int caps_here = 0;\n", "", 1)

func = r'''// Cap's per-object construction, shared by the live command and UpdateHistory
// (history_rebuild.h): caps every planar closed naked-edge loop of an open
// polysurface on a COPY of it. `caps_here` receives the number of loops capped;
// nullopt (with `why`) when the object is not an open polysurface or no loop
// could be capped.
std::optional<SceneObject> CapObject(CommandContext& ctx, const SceneObject& src, int& caps_here, std::string& why) {
  caps_here = 0;
  if (src.kind != ObjectKind::Brep || !src.brep) { why = std::string("the object is ") + HistoryKindName(src.kind) + ", not an open polysurface"; return std::nullopt; }
  kernel::Brep nb;
  nb.raw() = src.brep->raw();
  ON_Brep& b = nb.raw();
  if (b.IsSolid()) { why = "the object is already a closed solid, there is nothing to cap"; return std::nullopt; }
  std::vector<int> naked;
  for (int ei = 0; ei < b.m_E.Count(); ++ei) if (b.m_E[ei].TrimCount() == 1) naked.push_back(ei);
  if (naked.empty()) { why = "the object has no naked edges"; return std::nullopt; }
''' + body + r'''  if (caps_here == 0) { why = "none of its " + std::to_string(naked.size()) + " naked edge(s) forms a closed planar loop"; return std::nullopt; }
  JoinNakedEdges(b, ctx.Settings().absolute_tolerance * 10);
  return SceneObject::MakeBrep(nb);
}

'''
newreg = r'''  Reg(e, "Cap", OnSelection("Select open surfaces to cap", [](CommandContext& ctx, const std::vector<ObjectId>& ids) {
        ctx.Doc().BeginChange("Cap");
        int capped = 0, openings = 0, recorded = 0;
        const bool keep_source = ctx.App().State().history_recording;
        for (ObjectId id : ids) {
          const SceneObject* o = ctx.Doc().Find(id);
          if (!o || o->kind != ObjectKind::Brep || !o->brep) continue;
          int caps_here = 0;
          std::string why;
          std::optional<SceneObject> built = CapObject(ctx, *o, caps_here, why);
          if (!built) continue;
          ++capped;
          openings += caps_here;
          SceneObject* t = ctx.Doc().Find(id);
          if (keep_source) {
            // History On: the open polysurface is hidden (kept as the recorded source), the capped copy is a new object.
            built->layer_index = t->layer_index;
            t->visible = false;
            t->selected = false;
            t->InvalidateDisplay();
            const ObjectId new_id = ctx.Doc().Add(std::move(*built));
            RecordHistoryIfEnabled(ctx, new_id, "Cap", {id}, {});
            ++recorded;
          } else {
            t->brep->raw() = built->brep->raw();
            t->InvalidateDisplay();
          }
        }
        ctx.Print("Capped " + std::to_string(capped) + " object(s), " + std::to_string(openings) + " opening(s)" +
                  (recorded ? "; History is On: the open polysurface(s) are kept hidden as the source of " + std::to_string(recorded) + " recorded result(s)" : std::string()));
      }), CommandStatus::Implemented, "Caps every planar closed naked-edge loop on each selected polysurface (one call handles multiple separate holes). With History On the open polysurface is kept hidden as the recorded source and the capped copy follows edits of it.");
'''
s = s[:start] + newreg + s[end:]

reg_marker = "void RegisterSolidCommands(CommandEngine& e) {"
assert s.count(reg_marker) == 1
rebuild = r'''std::optional<SceneObject> RebuildCap(CommandContext& ctx, const HistoryInputs& in, const HistoryRecord&, std::string& why) {
  if (in.size() != 1) { why = "expected 1 source object, the record has " + std::to_string(in.size()); return std::nullopt; }
  int caps = 0;
  std::optional<SceneObject> r = CapObject(ctx, *in[0], caps, why);
  if (!r && !why.empty()) why = "source object " + std::to_string(in[0]->id) + ": " + why;
  return r;
}

'''
s = s.replace(reg_marker, func + rebuild + reg_marker)
open(p, 'w').write(s)

p = base + 'history_rebuild.h'
h = open(p).read()
anchor = "// Offset (cmd_edit.cpp), curves:"
h = h.replace(anchor, '''// Cap (cmd_solids.cpp): one open polysurface in; every planar closed naked-edge
// loop is capped on a copy. Reads no num parameters (the loops are re-derived
// from the source's current naked edges). Refuses, with the reason, when the
// source is no longer an open polysurface or no loop can be capped.
std::optional<SceneObject> RebuildCap(CommandContext& ctx, const HistoryInputs& inputs, const HistoryRecord& rec, std::string& why);

''' + anchor, 1)
open(p, 'w').write(h)

p = base + 'cmd_history.cpp'
t = open(p).read()
old = '''  RegisterHistoryRebuilder("FilletEdge", '''
assert old in t
t = t.replace(old, '''  RegisterHistoryRebuilder("Cap", "Cap of an open polysurface (every planar closed naked-edge loop)", RebuildCap);
''' + old, 1)
a = "FilletEdge/ChamferEdge (exact kernel paths, edges re-found by geometry), and the exact"
assert a in t
t = t.replace(a, "FilletEdge/ChamferEdge (exact kernel paths, edges re-found by geometry), Cap, and the exact", 1)
open(p, 'w').write(t)
print("ok")
