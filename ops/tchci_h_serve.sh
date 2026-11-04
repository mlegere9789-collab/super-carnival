set -euo pipefail
echo() { builtin echo "$@" 2>/dev/null || true; }
HERE=/home/user/miniature-pancake/.claude/worktrees/agent-aa2a3ea1137f2ae4e/dino8-app/tests
BIN="$1"; fail=0
TMP="$(mktemp -d)"; TMPW="$TMP"
trap 'rm -rf "$TMP"' EXIT
near() { echo "     expected: $2"; }
IS_WINDOWS=0
HEREW="$HERE"

if ! command -v curl >/dev/null 2>&1; then
  echo "skip --serve compute-server checks (curl not available)"
else
  SERVE_LOG="$TMPW/serve.log"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-max-requests 24 > "$SERVE_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-max-requests 24 > "$SERVE_LOG" 2>&1 &
  fi
  SERVE_PID=$!

  SERVE_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$SERVE_LOG" 2>/dev/null; then
      SERVE_PORT="$(grep "^serve: listening on port " "$SERVE_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$SERVE_PORT" ]; then
    cat "$SERVE_LOG"; echo "FAIL: --serve never printed its listening port within 10s"; fail=1
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  else
    echo "ok   --serve started headless and printed its bound port ($SERVE_PORT)"

    set +e
    RESP1="$(curl -s --max-time 10 -X POST --data 'rs.Command("Box 0,0,0 5,5,0 5")
print("objects: " .. #rs.AllObjects())' "http://127.0.0.1:$SERVE_PORT/run")"
    # A real, if minimal, structured geometry wire format: narrows
    # PARITY_MAP.md's own disclosed "no geometry (de)serialization format
    # at all - a script gets and returns plain text" gap on both the
    # response side (/run[/python]'s new Accept: application/json form)
    # and the request/read side (GET /objects below) - taken right after
    # RESP1 so the document holds exactly the one box it just built, with
    # a known id/bounding box to check against.
    RESP9="$(curl -s --max-time 10 -X POST -H 'Accept: application/json' --data 'print("hi")' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP10="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/objects")"
    # GET /objects?geometry=1: the actual point/vertex/curve data for the
    # three object kinds simple enough to serialize honestly as plain JSON
    # right now (point, mesh, and now a NURBS curve's own degree/control
    # points/weights/knots) - narrows PARITY_MAP.md's own disclosed "no
    # geometry (de)serialization format" gap a step further than the bare
    # metadata listing above. Adds one point, one triangle mesh and one
    # straight (degree-1, non-rational) line so all three real payloads can
    # be checked in the same request, plus confirms the pre-existing box (a
    # polysurface, none of the three) reports "geometry":null rather than
    # silently omitting the key or guessing at a payload.
    RESP11="$(curl -s --max-time 10 -X POST --data 'rs.AddPoint(20,20,20)
rs.AddMesh({{0,0,0},{1,0,0},{0,1,0}}, {{1,2,3}})
rs.AddLine({0,0,0},{10,0,0})' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP12="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/objects?geometry=1")"
    # POST /objects: the other half of the geometry wire format - sends
    # the same three shapes GET /objects?geometry=1 reads back in as a
    # JSON request body, closing PARITY_MAP.md's own disclosed "no way to
    # POST geometry in as structured data" gap. Document already holds 4
    # objects (box=1, point=2, mesh=3, line=4 from RESP1/RESP11 above), so
    # these three real adds land at the exact predictable ids 5/6/7 -
    # using different coordinates than RESP11's own point/mesh/line so the
    # follow-up GET below can tell the two apart, not just confirm *something*
    # landed at those ids.
    RESP13="$(curl -s --max-time 10 -X POST --data '{"type":"point","point":[7,8,9]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    RESP14="$(curl -s --max-time 10 -X POST --data '{"type":"mesh","vertices":[[0,0,0],[2,0,0],[0,2,0]],"faces":[[0,1,2]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    RESP15="$(curl -s --max-time 10 -X POST --data '{"type":"curve","degree":1,"control_points":[[0,0,5],[20,0,5]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    # The fourth geometry kind (surface, alongside point/mesh/curve above):
    # a degree-(1,1) bilinear patch, posted with no explicit "knots_u"/
    # "knots_v" so FromControlGrid's own clamped knot vectors get checked
    # the same way RESP15's curve already checks FromControlPoints' own
    # filled-in knots. Lands at the next predictable id (8) right alongside
    # RESP13/14/15, so the one RESP16 GET just below reads all five kinds
    # back in a single request.
    RESP18="$(curl -s --max-time 10 -X POST --data '{"type":"surface","degree_u":1,"degree_v":1,"u_count":2,"v_count":2,"control_points":[[0,0,0],[0,5,1],[9,0,0],[9,5,1]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    # The fifth geometry kind (point cloud): a point cloud has no topology
    # to lose, so this closes that gap outright. Posts both optional
    # per-point channels (colors, normals) alongside the required positions
    # so the round trip below actually exercises
    # PointCloud::SetColors()/SetNormals(), not just the bare-position path.
    # Lands at id 9, right alongside RESP13/14/15/18, so the same RESP16 GET
    # below reads it back too.
    RESP19="$(curl -s --max-time 10 -X POST --data '{"type":"point_cloud","points":[[1,2,3],[4,5,6],[7,8,9]],"colors":[[255,0,0],[0,255,0],[0,0,255]],"normals":[[1,0,0],[0,1,0],[0,0,1]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    # The remaining two kinds (polysurface, SubD) no longer get a bare
    # "geometry":null either, narrowing PARITY_MAP.md's own disclosed gap
    # further: both now carry a real tessellated-mesh approximation (same
    # vertices/faces shape as ObjectKind::Mesh, under a nested "mesh" key,
    # with "tessellated":true alongside it to disclose plainly that it is
    # an approximation, not the real trimmed-surface/control-cage topology
    # - still genuinely unserialized, and still a separately-disclosed,
    # substantially larger undertaking). The box built by RESP1 at the very
    # top (id 1, a polysurface) is already in the document for RESP16's GET
    # below to re-check; this one new request adds a second SubD box (lands
    # at the next predictable id, 10) so the same GET also exercises the
    # SubD half - no separate GET needed, RESP16 hasn't been issued yet.
    RESP20="$(curl -s --max-time 10 -X POST --data 'rs.Command("SubDBox 100,0,0 105,5,0 5")' "http://127.0.0.1:$SERVE_PORT/run")"
    # The sixth POST /objects type, "subd": a SubD control cage at level 0
    # IS exactly a mesh, so this is the identical {"vertices","faces"}
    # shape "mesh" already takes - one flat quad face, the simplest valid
    # control cage FromControlMesh accepts. Lands at the next predictable
    # id (11, right after RESP20's own SubDBox at 10), so the same RESP16
    # GET just below reads this one back too, as a real SubD (not a mesh).
    RESP_SUBD="$(curl -s --max-time 10 -X POST --data '{"type":"subd","vertices":[[20,0,0],[21,0,0],[21,1,0],[20,1,0]],"faces":[[0,1,2,3]]}' "http://127.0.0.1:$SERVE_PORT/objects")"
    RESP16="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/objects?geometry=1")"
    RESP17="$(curl -s --max-time 10 -X POST --data '{"type":"bogus"}' "http://127.0.0.1:$SERVE_PORT/objects")"
    CODE14="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'not json' "http://127.0.0.1:$SERVE_PORT/objects")"
    CODE2="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP3="$(curl -s --max-time 10 -X POST --data 'rs.GetPoint()' "http://127.0.0.1:$SERVE_PORT/run")"
    RESP4="$(curl -s --max-time 10 -X POST --data 'import dino8
id = dino8.doc.Objects.AddBox(dino8.Point3d(0,0,0), dino8.Vector3d(5,5,5))
print("volume: %.1f" % dino8.doc.Objects.SurfaceVolume(id))' "http://127.0.0.1:$SERVE_PORT/run/python")"
    RESP6="$(curl -s --max-time 10 -X POST --data 'import dino8
dino8.GetPoint()' "http://127.0.0.1:$SERVE_PORT/run/python")"
    # A script that catches the "cancelled" exception compute_handler's own
    # Abort() raises out of the first dino8.GetPoint() and simply calls
    # GetPoint() again (an easy bare-except pattern, not a deliberately
    # adversarial one) used to re-suspend PythonEngine's worker thread on a
    # resume that would never come, deadlocking it together with this very
    # Abort() call - which runs synchronously on the main loop that also
    # drives this whole --serve process, so the hang wasn't scoped to one
    # connection, it froze the entire server. This request must still get
    # an ordinary response within the --max-time below, not hang until the
    # outer `timeout 30` kills the whole process.
    RESP7="$(curl -s --max-time 10 -X POST --data 'import dino8
try:
    dino8.GetPoint()
except Exception:
    pass
dino8.GetPoint()' "http://127.0.0.1:$SERVE_PORT/run/python")"
    # dino8.GetInteger()/GetReal() (new this pass - PythonEngine.h/.cpp)
    # share WaitForPoint/WaitForText's own suspend-and-abort machinery, so
    # this must be rejected the same way RESP6's GetPoint() is, not hang.
    RESP8="$(curl -s --max-time 10 -X POST --data 'import dino8
dino8.GetInteger("how many")' "http://127.0.0.1:$SERVE_PORT/run/python")"
    CODE5="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'x' "http://127.0.0.1:$SERVE_PORT/run/nosuchroute")"
    # GET /plugins: narrows PARITY_MAP.md's own disclosed "Plugin
    # marketplace / discovery mechanism" gap - this same compute server can
    # now serve the bundled plugin index as real JSON over real HTTP,
    # giving PluginMarketplaceIndex's own existing arbitrary-http(s)-URL
    # path a genuine server to point at instead of only ever a file
    # someone else hosted by hand.
    RESP21="$(curl -s --max-time 10 "http://127.0.0.1:$SERVE_PORT/plugins")"
    CODE6="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'x' "http://127.0.0.1:$SERVE_PORT/plugins")"
    set -e
    echo "$RESP1" | grep -q "^objects: 1$" && echo "ok   POST /run built a box over HTTP and read back its printed object count" || { echo "$RESP1"; echo "FAIL --serve POST /run did not report objects: 1"; fail=1; }
    [ "$RESP9" = '{"ok":true,"output":["hi"]}' ] && echo "ok   POST /run with Accept: application/json returns a real structured {ok,output} response instead of plain print() text" || { echo "$RESP9"; echo "FAIL --serve POST /run Accept: application/json did not return the expected JSON body"; fail=1; }
    echo "$RESP10" | grep -q '"type":"polysurface"' && echo "ok   GET /objects reports the box RESP1 just built as a real JSON object (type polysurface)" || { echo "$RESP10"; echo "FAIL --serve GET /objects did not report the box as a polysurface"; fail=1; }
    echo "$RESP10" | grep -q '"min":\[0.000000,0.000000,0.000000\],"max":\[5.000000,5.000000,5.000000\]' && echo "ok   GET /objects reported the box's own real bounding box (0,0,0)-(5,5,5), not just a type/name/layer listing" || { echo "$RESP10"; echo "FAIL --serve GET /objects did not report the box's expected bounding box"; fail=1; }
    echo "$RESP12" | grep -q '"geometry":{"point":\[20.000000,20.000000,20.000000\]}' && echo "ok   GET /objects?geometry=1 reports a real point object's own coordinates, not just its bounding box" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report the point's coordinates"; fail=1; }
    echo "$RESP12" | grep -q '"geometry":{"vertices":\[\[0.000000,0.000000,0.000000\],\[1.000000,0.000000,0.000000\],\[0.000000,1.000000,0.000000\]\],"faces":\[\[0,1,2\]\]}' && echo "ok   GET /objects?geometry=1 reports a real mesh object's own vertices/faces (0-based indices), not just its bounding box" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report the mesh's expected vertices/faces"; fail=1; }
    echo "$RESP12" | grep -q '"type":"curve".*"geometry":{"degree":1,"rational":false,"control_points":\[\[0.000000,0.000000,0.000000\],\[10.000000,0.000000,0.000000\]\],"knots":\[0.000000,1.000000\]}' && echo "ok   GET /objects?geometry=1 reports a real NURBS curve's own degree/control points/knots (no \"weights\" field for a non-rational curve), not just sampled points" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report the line's expected NURBS curve definition"; fail=1; }
    # Polysurface/SubD (RESP20's own new SubD checked a few lines below,
    # against RESP16 instead - it doesn't exist yet at this point in the
    # flow): a real tessellated-mesh approximation instead of a bare
    # "geometry":null - narrows PARITY_MAP.md's own disclosed gap further.
    # Checked by substantive content (the "tessellated" flag, both extreme
    # corners of the box's own known (0,0,0)-(5,5,5) bounds genuinely
    # present as vertices, and a non-empty face list) rather than the full
    # adaptive-triangulation string verbatim - EnsureDisplay's own adaptive
    # algorithm is deterministic for this fixed input (confirmed by two
    # independent runs against the real binary before writing this check),
    # but pinning its exact internal vertex/triangle order would tie this
    # test to that algorithm's own implementation detail more tightly than
    # the behavior actually being verified here calls for.
    echo "$RESP12" | grep -q '"type":"polysurface".*"geometry":{"tessellated":true,"mesh":{"vertices":\[' && echo "ok   GET /objects?geometry=1 reports a real tessellated mesh approximation for a polysurface instead of bare \"geometry\":null" || { echo "$RESP12"; echo "FAIL --serve GET /objects?geometry=1 did not report tessellated geometry for the box"; fail=1; }
    echo "$RESP12" | grep -q '\[0.000000,0.000000,0.000000\]' && echo "$RESP12" | grep -q '\[5.000000,5.000000,5.000000\]' && echo "ok   the box's own tessellated mesh genuinely spans its real (0,0,0)-(5,5,5) extent, not a placeholder or degenerate mesh" || { echo "$RESP12"; echo "FAIL --serve box's tessellated mesh did not span its expected extent"; fail=1; }
    echo "$RESP12" | grep -q '"faces":\[\[[0-9]' && echo "ok   the box's own tessellated mesh carries a real, non-empty face list" || { echo "$RESP12"; echo "FAIL --serve box's tessellated mesh had no faces"; fail=1; }
    [ "$RESP13" = '{"ok":true,"id":5}' ] && echo "ok   POST /objects {type:point} added a real point object at the expected id" || { echo "$RESP13"; echo "FAIL --serve POST /objects point did not return the expected {ok,id}"; fail=1; }
    [ "$RESP14" = '{"ok":true,"id":6}' ] && echo "ok   POST /objects {type:mesh} added a real mesh object at the expected id" || { echo "$RESP14"; echo "FAIL --serve POST /objects mesh did not return the expected {ok,id}"; fail=1; }
    [ "$RESP15" = '{"ok":true,"id":7}' ] && echo "ok   POST /objects {type:curve} added a real NURBS curve object at the expected id" || { echo "$RESP15"; echo "FAIL --serve POST /objects curve did not return the expected {ok,id}"; fail=1; }
    [ "$RESP18" = '{"ok":true,"id":8}' ] && echo "ok   POST /objects {type:surface} added a real NURBS surface object at the expected id" || { echo "$RESP18"; echo "FAIL --serve POST /objects surface did not return the expected {ok,id}"; fail=1; }
    [ "$RESP19" = '{"ok":true,"id":9}' ] && echo "ok   POST /objects {type:point_cloud} added a real point-cloud object at the expected id" || { echo "$RESP19"; echo "FAIL --serve POST /objects point_cloud did not return the expected {ok,id}"; fail=1; }
    echo "$RESP16" | grep -q '"id":5,"type":"point".*"geometry":{"point":\[7.000000,8.000000,9.000000\]}' && echo "ok   the point POSTed via /objects reads back through GET /objects?geometry=1 with its own exact coordinates - a genuine round trip, not just an accepted write" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed point"; fail=1; }
    echo "$RESP16" | grep -q '"id":6,"type":"mesh".*"geometry":{"vertices":\[\[0.000000,0.000000,0.000000\],\[2.000000,0.000000,0.000000\],\[0.000000,2.000000,0.000000\]\],"faces":\[\[0,1,2\]\]}' && echo "ok   the mesh POSTed via /objects reads back with its own exact vertices/faces - a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed mesh"; fail=1; }
    echo "$RESP16" | grep -q '"id":7,"type":"curve".*"geometry":{"degree":1,"rational":false,"control_points":\[\[0.000000,0.000000,5.000000\],\[20.000000,0.000000,5.000000\]\]' && echo "ok   the curve POSTed via /objects (with no explicit \"knots\") reads back with its own exact control points and a real knot vector FromControlPoints filled in - a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed curve"; fail=1; }
    echo "$RESP16" | grep -q '"id":8,"type":"surface".*"geometry":{"degree_u":1,"degree_v":1,"u_count":2,"v_count":2,"rational":false,"control_points":\[\[0.000000,0.000000,0.000000\],\[0.000000,5.000000,1.000000\],\[9.000000,0.000000,0.000000\],\[9.000000,5.000000,1.000000\]\],"knots_u":\[0.000000,1.000000\],"knots_v":\[0.000000,1.000000\]}' && echo "ok   the surface POSTed via /objects (with no explicit \"knots_u\"/\"knots_v\") reads back with its own exact control grid and real clamped knot vectors FromControlGrid filled in, in each direction - the fourth geometry kind this wire format now covers, a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed surface"; fail=1; }
    echo "$RESP16" | grep -q '"id":9,"type":"point cloud".*"geometry":{"points":\[\[1.000000,2.000000,3.000000\],\[4.000000,5.000000,6.000000\],\[7.000000,8.000000,9.000000\]\],"colors":\[\[255,0,0\],\[0,255,0\],\[0,0,255\]\],"normals":\[\[1.000000,0.000000,0.000000\],\[0.000000,1.000000,0.000000\],\[0.000000,0.000000,1.000000\]\]}' && echo "ok   the point cloud POSTed via /objects (positions plus both optional colors/normals channels) reads back with its own exact points/colors/normals - the fifth geometry kind this wire format now covers, a genuine round trip" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed point cloud"; fail=1; }
    # RESP20's SubD box (id 10, built via rs.Command, so it lands with a
    # real ON_SubD independently of the POST "subd" type checked just
    # below). Unlike the box's own adaptive tessellation above,
    # SubD::ToApproximateMesh() facets the CURRENT subdivision level's own
    # flat control net (its own doc comment is explicit this is never the
    # true limit surface) - a never-Subdivide()'d SubDBox is deterministic
    # exactly, so this pins the full vertex/face list, not just substantive
    # content, the same way the plain Mesh/Curve/Surface checks above do.
    echo "$RESP16" | grep -q '"id":10,"type":"SubD".*"geometry":{"tessellated":true,"mesh":{"vertices":\[\[100.000000,0.000000,0.000000\],\[105.000000,0.000000,0.000000\],\[100.000000,5.000000,0.000000\],\[105.000000,5.000000,0.000000\],\[100.000000,0.000000,5.000000\],\[105.000000,0.000000,5.000000\],\[100.000000,5.000000,5.000000\],\[105.000000,5.000000,5.000000\]\],"faces":\[\[0,2,3,1\],\[4,5,7,6\],\[0,1,5,4\],\[2,6,7,3\],\[0,4,6,2\],\[1,3,7,5\]\]}}' && echo "ok   GET /objects?geometry=1 reports a real tessellated mesh approximation (its own flat control cage, 8 vertices/6 quad faces) for a SubD instead of bare \"geometry\":null" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not report the SubD box's expected tessellated geometry"; fail=1; }
    [ "$RESP_SUBD" = '{"ok":true,"id":11}' ] && echo "ok   POST /objects {type:subd} added a real SubD control cage at the expected id, right after RESP20's own rs.Command-built SubD box" || { echo "$RESP_SUBD"; echo "FAIL --serve POST /objects subd did not return the expected {ok,id}"; fail=1; }
    echo "$RESP16" | grep -q '"id":11,"type":"SubD".*"geometry":{"tessellated":true,"mesh":{"vertices":\[\[20.000000,0.000000,0.000000\],\[21.000000,0.000000,0.000000\],\[21.000000,1.000000,0.000000\],\[20.000000,1.000000,0.000000\]\],"faces":\[\[0,1,2,3\]\]}}' && echo "ok   the SubD POSTed via /objects (one flat quad control cage) reads back as its own exact tessellated flat cage - not through Lua/rs.Command at all, the sixth geometry kind this wire format now covers on the write side" || { echo "$RESP16"; echo "FAIL --serve GET /objects?geometry=1 did not read back the POSTed SubD's expected control cage"; fail=1; }
    echo "$RESP17" | grep -q '^{"ok":false,"error":"unknown or missing' && echo "ok   POST /objects rejects an unrecognized \"type\" with a clear JSON error instead of silently doing nothing" || { echo "$RESP17"; echo "FAIL --serve POST /objects did not reject an unknown type as expected"; fail=1; }
    [ "$CODE14" = "400" ] && echo "ok   POST /objects rejects a malformed (non-JSON) body with 400 Bad Request" || { echo "FAIL --serve POST /objects malformed body returned HTTP $CODE14, expected 400"; fail=1; }
    [ "$CODE2" = "405" ] && echo "ok   a GET request to the compute server is rejected with 405 Method Not Allowed" || { echo "FAIL --serve GET /run returned HTTP $CODE2, expected 405"; fail=1; }
    echo "$RESP3" | grep -q "compute error: script requires interactive input" && echo "ok   a script calling an interactive rs.Get* prompt is rejected instead of hanging the connection" || { echo "$RESP3"; echo "FAIL --serve interactive-prompt script was not rejected as expected"; fail=1; }
    if echo "$RESP4" | grep -q "DINO8_HAVE_PYTHON"; then
      echo "skip POST /run/python checks (this build has no embedded Python - see DINO8_ENABLE_PYTHON in CMakeLists.txt)"
    else
      echo "$RESP4" | grep -q "^volume: 125.0$" && echo "ok   POST /run/python built a box through the dino8 module over HTTP and read back its printed volume" || { echo "$RESP4"; echo "FAIL --serve POST /run/python did not report volume: 125.0"; fail=1; }
      echo "$RESP6" | grep -q "compute error: script requires interactive input" && echo "ok   a POST /run/python script calling the now-real dino8.GetPoint() is rejected instead of hanging the connection (PythonEngine suspends on a worker thread now - see PythonEngine.h - so this is a real regression risk main.cpp's compute_handler guards against)" || { echo "$RESP6"; echo "FAIL --serve POST /run/python dino8.GetPoint() was not rejected as expected"; fail=1; }
      echo "$RESP7" | grep -q "compute error: script requires interactive input" && echo "ok   a POST /run/python script that catches the cancelled GetPoint() and calls it again still gets an ordinary rejection, not a frozen connection/server" || { echo "$RESP7"; echo "FAIL --serve POST /run/python catch-and-retry GetPoint() hung or returned something unexpected"; fail=1; }
      echo "$RESP8" | grep -q "compute error: script requires interactive input" && echo "ok   a POST /run/python script calling the new dino8.GetInteger() is rejected instead of hanging the connection, same as GetPoint/GetString" || { echo "$RESP8"; echo "FAIL --serve POST /run/python dino8.GetInteger() was not rejected as expected"; fail=1; }
    fi
    [ "$CODE5" = "404" ] && echo "ok   a POST to an unrecognized path is rejected with 404 Not Found" || { echo "FAIL --serve POST to an unknown path returned HTTP $CODE5, expected 404"; fail=1; }
    echo "$RESP21" | grep -q '"index_name": "Dino 8 Reference Plugin Index"' && echo "$RESP21" | grep -q '"id": "hellodino"' && echo "ok   GET /plugins serves the real bundled plugin index as JSON over HTTP" || { echo "$RESP21"; echo "FAIL --serve GET /plugins did not serve the expected bundled index"; fail=1; }
    [ "$CODE6" = "405" ] && echo "ok   a POST to /plugins is rejected with 405 Method Not Allowed (GET only)" || { echo "FAIL --serve POST /plugins returned HTTP $CODE6, expected 405"; fail=1; }

    set +e; wait "$SERVE_PID"; SERVE_EC=$?; set -e
    if [ "$SERVE_EC" -eq 124 ]; then
      cat "$SERVE_LOG"; echo "FAIL: --serve process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$SERVE_EC" -ne 0 ]; then
      cat "$SERVE_LOG"; echo "FAIL: --serve process exited $SERVE_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=24$" "$SERVE_LOG" && echo "ok   --serve exited cleanly on its own after --serve-max-requests 24 real HTTP requests" || { cat "$SERVE_LOG"; echo "FAIL --serve done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token: a second, independent server instance (its own ephemeral
  # port) started with TWO bearer tokens required - a bare, anonymous one
  # ("hunter2") and a named one ("ci:abc123"), checking that --serve-token
  # is genuinely repeatable and that a named token's own caller comes back
  # in the JSON response, not just that auth works at all. Checks: a
  # request with no/wrong Authorization header is rejected with 401 (its
  # script body, "should not run", is never passed to Lua.Start at all -
  # see main.cpp's compute_handler, which checks the token before touching
  # req.path/req.body); the bare token succeeds exactly like the token-less
  # server above, with no "caller" field; and the named token succeeds AND
  # echoes its own name back as "caller" (Accept: application/json).
  TOKEN_LOG="$TMPW/serve_token.log"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token hunter2 --serve-token ci:abc123 --serve-max-requests 4 > "$TOKEN_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token hunter2 --serve-token ci:abc123 --serve-max-requests 4 > "$TOKEN_LOG" 2>&1 &
  fi
  TOKEN_PID=$!

  TOKEN_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$TOKEN_LOG" 2>/dev/null; then
      TOKEN_PORT="$(grep "^serve: listening on port " "$TOKEN_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$TOKEN_PORT" ]; then
    cat "$TOKEN_LOG"; echo "FAIL: --serve-token server never printed its listening port within 10s"; fail=1
    kill "$TOKEN_PID" 2>/dev/null || true
    wait "$TOKEN_PID" 2>/dev/null || true
  else
    echo "ok   --serve-token started a second compute server headless on its own bound port ($TOKEN_PORT)"

    set +e
    CODE_NOAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKEN_PORT/run")"
    CODE_WRONGAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrongtoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKEN_PORT/run")"
    RESP_OKAUTH="$(curl -s --max-time 10 -H 'Authorization: Bearer hunter2' -X POST --data 'print("authorized ok")' "http://127.0.0.1:$TOKEN_PORT/run")"
    RESP_NAMEDAUTH="$(curl -s --max-time 10 -H 'Authorization: Bearer abc123' -H 'Accept: application/json' -X POST --data 'print("authorized ok")' "http://127.0.0.1:$TOKEN_PORT/run")"
    set -e
    [ "$CODE_NOAUTH" = "401" ] && echo "ok   --serve-token rejects a request with no Authorization header with 401" || { echo "FAIL --serve-token no-auth request returned HTTP $CODE_NOAUTH, expected 401"; fail=1; }
    [ "$CODE_WRONGAUTH" = "401" ] && echo "ok   --serve-token rejects a request with the wrong bearer token with 401" || { echo "FAIL --serve-token wrong-token request returned HTTP $CODE_WRONGAUTH, expected 401"; fail=1; }
    echo "$RESP_OKAUTH" | grep -q "^authorized ok$" && echo "ok   --serve-token accepts a request with the correct Authorization: Bearer header and runs the script" || { echo "$RESP_OKAUTH"; echo "FAIL --serve-token correct-token request did not run the script"; fail=1; }
    [ "$RESP_NAMEDAUTH" = '{"ok":true,"output":["authorized ok"],"caller":"ci"}' ] && echo "ok   a second, named --serve-token (ci:abc123) authenticates independently of the bare one and echoes its own caller name back in the JSON response" || { echo "$RESP_NAMEDAUTH"; echo "FAIL --serve-token named-token request did not return the expected caller-tagged JSON"; fail=1; }

    set +e; wait "$TOKEN_PID"; TOKEN_EC=$?; set -e
    if [ "$TOKEN_EC" -eq 124 ]; then
      cat "$TOKEN_LOG"; echo "FAIL: --serve-token process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$TOKEN_EC" -ne 0 ]; then
      cat "$TOKEN_LOG"; echo "FAIL: --serve-token process exited $TOKEN_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=4$" "$TOKEN_LOG" && echo "ok   --serve-token server exited cleanly on its own after 4 real HTTP requests" || { cat "$TOKEN_LOG"; echo "FAIL --serve-token done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file: a third, independent server instance whose tokens
  # come from a file re-read on every request instead of fixed at startup -
  # narrows PARITY_MAP.md's own disclosed "no rotation, expiry, or
  # revocation beyond restarting the server" gap --serve-token alone still
  # has. Starts with one bare token ("filetoken1") in the file, proves it
  # authenticates like any --serve-token would, then overwrites the file
  # mid-run (filetoken1 removed = revoked, filetoken2 + a named ci2:tokenY
  # added = rotated in) and proves the very next requests see the change
  # with no restart: the old token now rejected, the new ones accepted.
  TOKFILE_LOG="$TMPW/serve_token_file.log"
  TOKFILE_PATH="$TMPW/serve_tokens.txt"
  printf 'filetoken1\n' > "$TOKFILE_PATH"
  chmod 0600 "$TOKFILE_PATH"  # owner-only, same as any real deployment would need - see the permissions test below
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$TOKFILE_PATH" --serve-max-requests 5 > "$TOKFILE_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$TOKFILE_PATH" --serve-max-requests 5 > "$TOKFILE_LOG" 2>&1 &
  fi
  TOKFILE_PID=$!

  TOKFILE_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$TOKFILE_LOG" 2>/dev/null; then
      TOKFILE_PORT="$(grep "^serve: listening on port " "$TOKFILE_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$TOKFILE_PORT" ]; then
    cat "$TOKFILE_LOG"; echo "FAIL: --serve-token-file server never printed its listening port within 10s"; fail=1
    kill "$TOKFILE_PID" 2>/dev/null || true
    wait "$TOKFILE_PID" 2>/dev/null || true
  else
    echo "ok   --serve-token-file started a third compute server headless on its own bound port ($TOKFILE_PORT)"

    set +e
    FILE_CODE_NOAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    FILE_RESP_OK1="$(curl -s --max-time 10 -H 'Authorization: Bearer filetoken1' -X POST --data 'print("file token ok")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    # Rewrite the file while the server is still running, no restart:
    # filetoken1 is gone (revoked), filetoken2/ci2:tokenY are new (rotated
    # in) - both take effect on the next two requests below.
    printf 'filetoken2\nci2:tokenY\n' > "$TOKFILE_PATH"
    FILE_CODE_REVOKED="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer filetoken1' -X POST --data 'print("should not run")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    FILE_RESP_ROTATED="$(curl -s --max-time 10 -H 'Authorization: Bearer filetoken2' -X POST --data 'print("rotated token ok")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    FILE_RESP_NAMED="$(curl -s --max-time 10 -H 'Authorization: Bearer tokenY' -H 'Accept: application/json' -X POST --data 'print("named ok")' "http://127.0.0.1:$TOKFILE_PORT/run")"
    set -e
    [ "$FILE_CODE_NOAUTH" = "401" ] && echo "ok   --serve-token-file rejects a request with no Authorization header with 401, same as --serve-token" || { echo "FAIL --serve-token-file no-auth request returned HTTP $FILE_CODE_NOAUTH, expected 401"; fail=1; }
    echo "$FILE_RESP_OK1" | grep -q "^file token ok$" && echo "ok   --serve-token-file accepts a token currently listed in the file and runs the script" || { echo "$FILE_RESP_OK1"; echo "FAIL --serve-token-file did not accept the file's own listed token"; fail=1; }
    [ "$FILE_CODE_REVOKED" = "401" ] && echo "ok   rewriting the token file to drop a token revokes it on the very next request - no server restart needed" || { echo "FAIL --serve-token-file still accepted a token removed from the file (HTTP $FILE_CODE_REVOKED, expected 401) - revocation did not take effect live"; fail=1; }
    echo "$FILE_RESP_ROTATED" | grep -q "^rotated token ok$" && echo "ok   a token added to the file after the server started authenticates immediately - live rotation, no restart needed" || { echo "$FILE_RESP_ROTATED"; echo "FAIL --serve-token-file did not accept a token added to the file after startup"; fail=1; }
    [ "$FILE_RESP_NAMED" = '{"ok":true,"output":["named ok"],"caller":"ci2"}' ] && echo "ok   a named NAME:TOKEN entry in the token file authenticates and echoes its own caller name back, same as a named --serve-token" || { echo "$FILE_RESP_NAMED"; echo "FAIL --serve-token-file named-entry request did not return the expected caller-tagged JSON"; fail=1; }

    set +e; wait "$TOKFILE_PID"; TOKFILE_EC=$?; set -e
    if [ "$TOKFILE_EC" -eq 124 ]; then
      cat "$TOKFILE_LOG"; echo "FAIL: --serve-token-file process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$TOKFILE_EC" -ne 0 ]; then
      cat "$TOKFILE_LOG"; echo "FAIL: --serve-token-file process exited $TOKFILE_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=5$" "$TOKFILE_LOG" && echo "ok   --serve-token-file server exited cleanly on its own after 5 real HTTP requests" || { cat "$TOKFILE_LOG"; echo "FAIL --serve-token-file done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file-ttl: real automatic expiry, the one piece plain
  # --serve-token-file still lacked (it can rotate/revoke live, but an
  # unedited file's own tokens stayed valid forever). A 2s TTL, a fresh
  # token file, and real sleeps (the same mtime-comparison-needs-a-real-
  # elapsed-interval technique the DataLinkUpdate checks above already
  # use) prove a token that authenticated moments ago stops working once
  # the file goes stale, and starts working again the instant the file is
  # rewritten (even with the IDENTICAL token text) - `touch`-to-renew,
  # no restart.
  TTL_LOG="$TMPW/serve_token_ttl.log"
  TTL_PATH="$TMPW/serve_tokens_ttl.txt"
  printf 'ttltoken\n' > "$TTL_PATH"
  chmod 0600 "$TTL_PATH"  # owner-only, same as any real deployment would need - see the permissions test below
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$TTL_PATH" --serve-token-file-ttl 2 --serve-max-requests 3 > "$TTL_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$TTL_PATH" --serve-token-file-ttl 2 --serve-max-requests 3 > "$TTL_LOG" 2>&1 &
  fi
  TTL_PID=$!

  TTL_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$TTL_LOG" 2>/dev/null; then
      TTL_PORT="$(grep "^serve: listening on port " "$TTL_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$TTL_PORT" ]; then
    cat "$TTL_LOG"; echo "FAIL: --serve-token-file-ttl server never printed its listening port within 10s"; fail=1
    kill "$TTL_PID" 2>/dev/null || true
    wait "$TTL_PID" 2>/dev/null || true
  else
    set +e
    TTL_RESP_FRESH="$(curl -s --max-time 10 -H 'Authorization: Bearer ttltoken' -X POST --data 'print("fresh ok")' "http://127.0.0.1:$TTL_PORT/run")"
    sleep 4
    TTL_CODE_EXPIRED="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ttltoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$TTL_PORT/run")"
    printf 'ttltoken\n' > "$TTL_PATH"
    TTL_RESP_RENEWED="$(curl -s --max-time 10 -H 'Authorization: Bearer ttltoken' -X POST --data 'print("renewed ok")' "http://127.0.0.1:$TTL_PORT/run")"
    set -e
    echo "$TTL_RESP_FRESH" | grep -q "^fresh ok$" && echo "ok   --serve-token-file-ttl accepts a token right after the file was written (well inside the TTL)" || { echo "$TTL_RESP_FRESH"; echo "FAIL --serve-token-file-ttl rejected a fresh token"; fail=1; }
    [ "$TTL_CODE_EXPIRED" = "401" ] && echo "ok   the identical token is rejected once the file's own age exceeds --serve-token-file-ttl, with no edit to the file at all - real automatic expiry" || { echo "FAIL --serve-token-file-ttl still accepted a token from a stale file (HTTP $TTL_CODE_EXPIRED, expected 401) - expiry did not take effect"; fail=1; }
    echo "$TTL_RESP_RENEWED" | grep -q "^renewed ok$" && echo "ok   rewriting the file (even with the identical token text) renews it - access resumes immediately, no restart needed" || { echo "$TTL_RESP_RENEWED"; echo "FAIL --serve-token-file-ttl did not accept the token again after the file was rewritten"; fail=1; }

    set +e; wait "$TTL_PID"; TTL_EC=$?; set -e
    if [ "$TTL_EC" -eq 124 ]; then
      cat "$TTL_LOG"; echo "FAIL: --serve-token-file-ttl process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$TTL_EC" -ne 0 ]; then
      cat "$TTL_LOG"; echo "FAIL: --serve-token-file-ttl process exited $TTL_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=3$" "$TTL_LOG" && echo "ok   --serve-token-file-ttl server exited cleanly on its own after 3 real HTTP requests" || { cat "$TTL_LOG"; echo "FAIL --serve-token-file-ttl done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file hashed entries ("sha256:HEX"): the file holds only
  # a digest, never the real bearer secret, closing the "no hashing" gap
  # named alongside rotation/revocation/expiry above. Real SHA-256 hex
  # digests below (computed with `sha256sum`, not made up) for two real
  # tokens - a bare one ("hashedtoken123") and a named one
  # ("ci3:secretXYZ") - prove the server actually hashes the PRESENTED
  # token and compares digests, rather than, say, accidentally comparing
  # the presented plaintext against the stored hex string itself (which
  # would make every request fail, never succeed).
  HASH_LOG="$TMPW/serve_token_hash.log"
  HASH_PATH="$TMPW/serve_tokens_hash.txt"
  printf 'sha256:79d8dad2f0a04420fd1e0b3c2090350a527c9e8b147bba7a06e8c38ed666a034\nci3:sha256:8800d70b1d06d18497e333a3942da0037e660a66250a081e570073ad533c5ddc\n' > "$HASH_PATH"
  chmod 0600 "$HASH_PATH"  # owner-only, same as any real deployment would need - see the permissions test below
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$HASH_PATH" --serve-max-requests 4 > "$HASH_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$HASH_PATH" --serve-max-requests 4 > "$HASH_LOG" 2>&1 &
  fi
  HASH_PID=$!

  HASH_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$HASH_LOG" 2>/dev/null; then
      HASH_PORT="$(grep "^serve: listening on port " "$HASH_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$HASH_PORT" ]; then
    cat "$HASH_LOG"; echo "FAIL: --serve-token-file (hashed entries) server never printed its listening port within 10s"; fail=1
    kill "$HASH_PID" 2>/dev/null || true
    wait "$HASH_PID" 2>/dev/null || true
  else
    set +e
    HASH_CODE_NOAUTH="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$HASH_PORT/run")"
    HASH_CODE_WRONG="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer notthetoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$HASH_PORT/run")"
    HASH_RESP_OK="$(curl -s --max-time 10 -H 'Authorization: Bearer hashedtoken123' -H 'Accept: application/json' -X POST --data 'print("hashed ok")' "http://127.0.0.1:$HASH_PORT/run")"
    HASH_RESP_NAMED="$(curl -s --max-time 10 -H 'Authorization: Bearer secretXYZ' -H 'Accept: application/json' -X POST --data 'print("named hashed ok")' "http://127.0.0.1:$HASH_PORT/run")"
    set -e
    [ "$HASH_CODE_NOAUTH" = "401" ] && echo "ok   --serve-token-file with hashed entries still rejects a request with no Authorization header with 401" || { echo "FAIL --serve-token-file (hashed) no-auth request returned HTTP $HASH_CODE_NOAUTH, expected 401"; fail=1; }
    [ "$HASH_CODE_WRONG" = "401" ] && echo "ok   --serve-token-file with hashed entries rejects a wrong token with 401 - it genuinely hashes the presented token and compares, not a lucky accident" || { echo "FAIL --serve-token-file (hashed) wrong-token request returned HTTP $HASH_CODE_WRONG, expected 401"; fail=1; }
    [ "$HASH_RESP_OK" = '{"ok":true,"output":["hashed ok"]}' ] && echo "ok   presenting the real plaintext token authenticates against its file-stored sha256:HEX digest alone, with no spurious \"caller\":\"sha256\" field - the leading \"sha256:\" wasn't misparsed as a NAME: prefix, and the file itself never held the real secret" || { echo "$HASH_RESP_OK"; echo "FAIL --serve-token-file did not accept the real plaintext token for a bare hashed entry, or returned an unexpected caller field"; fail=1; }
    [ "$HASH_RESP_NAMED" = '{"ok":true,"output":["named hashed ok"],"caller":"ci3"}' ] && echo "ok   a named NAME:sha256:HEX entry hashes and authenticates independently, still echoing its own caller name back in the JSON response" || { echo "$HASH_RESP_NAMED"; echo "FAIL --serve-token-file named-hashed-entry request did not return the expected caller-tagged JSON"; fail=1; }

    set +e; wait "$HASH_PID"; HASH_EC=$?; set -e
    if [ "$HASH_EC" -eq 124 ]; then
      cat "$HASH_LOG"; echo "FAIL: --serve-token-file (hashed entries) process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$HASH_EC" -ne 0 ]; then
      cat "$HASH_LOG"; echo "FAIL: --serve-token-file (hashed entries) process exited $HASH_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=4$" "$HASH_LOG" && echo "ok   --serve-token-file (hashed entries) server exited cleanly on its own after 4 real HTTP requests" || { cat "$HASH_LOG"; echo "FAIL --serve-token-file (hashed entries) done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # --serve-token-file loose permissions: the file's own group/other-read
  # bits are checked fresh on every request, the same live-reconsideration
  # TTL/rotation/revocation already get - starts the file world-readable
  # (0644), proves a real correct token is still rejected (the file is
  # untrustworthy regardless of what it says), tightens it to 0600 WHILE
  # the server keeps running and proves the identical token now succeeds
  # with no restart, then loosens it right back to 0644 and proves access
  # is revoked again just as live - not a one-time startup check.
  PERM_LOG="$TMPW/serve_token_perm.log"
  PERM_PATH="$TMPW/serve_tokens_perm.txt"
  printf 'permtoken\n' > "$PERM_PATH"
  chmod 0644 "$PERM_PATH"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$PERM_PATH" --serve-max-requests 3 > "$PERM_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$PERM_PATH" --serve-max-requests 3 > "$PERM_LOG" 2>&1 &
  fi
  PERM_PID=$!

  PERM_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$PERM_LOG" 2>/dev/null; then
      PERM_PORT="$(grep "^serve: listening on port " "$PERM_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done

  if [ -z "$PERM_PORT" ]; then
    cat "$PERM_LOG"; echo "FAIL: --serve-token-file (permissions) server never printed its listening port within 10s"; fail=1
    kill "$PERM_PID" 2>/dev/null || true
    wait "$PERM_PID" 2>/dev/null || true
  else
    set +e
    PERM_CODE_LOOSE="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer permtoken' -X POST --data 'print("should not run")' "http://127.0.0.1:$PERM_PORT/run")"
    chmod 0600 "$PERM_PATH"
    PERM_RESP_TIGHT="$(curl -s --max-time 10 -H 'Authorization: Bearer permtoken' -X POST --data 'print("tight perms ok")' "http://127.0.0.1:$PERM_PORT/run")"
    chmod 0644 "$PERM_PATH"
    PERM_CODE_LOOSE_AGAIN="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer permtoken' -X POST --data 'print("should not run either")' "http://127.0.0.1:$PERM_PORT/run")"
    set -e
    if [ "$IS_WINDOWS" = 1 ]; then
      # Not a pass: TokenFilePermissionsOk (main.cpp) is a documented no-op
      # on Windows - there are no POSIX group/other read bits to inspect
      # (Git-Bash's chmod above changes nothing the app could read either),
      # and NTFS ACLs are not examined - so the two loose-permissions
      # rejections below cannot be exercised there. Both are left FAIL on
      # every other platform; the server start, the tight-permissions
      # request and the clean exit are still checked here exactly as on
      # Linux/macOS, so the Winsock path itself is not skipped.
      echo "skip (Windows: POSIX permission bits not checked - TokenFilePermissionsOk is a documented no-op there) --serve-token-file world-readable (0644) rejection (HTTP $PERM_CODE_LOOSE)"
    else
      [ "$PERM_CODE_LOOSE" = "401" ] && echo "ok   --serve-token-file rejects a correct token when the file itself is world-readable (0644) - the token file's own permissions, not just what it contains, are checked" || { echo "FAIL --serve-token-file accepted a token from a world-readable (0644) file, expected 401 (HTTP $PERM_CODE_LOOSE)"; fail=1; }
    fi
    echo "$PERM_RESP_TIGHT" | grep -q "^tight perms ok$" && echo "ok   chmod'ing the file to 0600 WHILE the server keeps running immediately allows the identical token - live, no restart needed, same as TTL/rotation above" || { echo "$PERM_RESP_TIGHT"; echo "FAIL --serve-token-file still rejected the token after tightening the file to 0600"; fail=1; }
    if [ "$IS_WINDOWS" = 1 ]; then
      echo "skip (Windows: POSIX permission bits not checked - TokenFilePermissionsOk is a documented no-op there) --serve-token-file re-loosened (0644) revocation (HTTP $PERM_CODE_LOOSE_AGAIN)"
    else
      [ "$PERM_CODE_LOOSE_AGAIN" = "401" ] && echo "ok   chmod'ing the file back to 0644 revokes access again on the very next request - a live recheck every time, not a one-shot startup gate" || { echo "FAIL --serve-token-file accepted a token again after loosening the file back to 0644, expected 401 (HTTP $PERM_CODE_LOOSE_AGAIN)"; fail=1; }
    fi

    set +e; wait "$PERM_PID"; PERM_EC=$?; set -e
    if [ "$PERM_EC" -eq 124 ]; then
      cat "$PERM_LOG"; echo "FAIL: --serve-token-file (permissions) process hung and was killed by the 30s timeout instead of exiting after --serve-max-requests"; fail=1
    elif [ "$PERM_EC" -ne 0 ]; then
      cat "$PERM_LOG"; echo "FAIL: --serve-token-file (permissions) process exited $PERM_EC, expected 0"; fail=1
    else
      grep -q "^serve: done requests=3$" "$PERM_LOG" && echo "ok   --serve-token-file (permissions) server exited cleanly on its own after 3 real HTTP requests" || { cat "$PERM_LOG"; echo "FAIL --serve-token-file (permissions) done-summary line missing or wrong"; fail=1; }
    fi
  fi

  # A missing/unreadable token file must fail CLOSED (deny everything),
  # never silently fall back to the fully-open behavior an empty
  # serve_tokens alone would mean - a typo'd --serve-token-file path must
  # not accidentally leave the compute server open to the network.
  MISSING_LOG="$TMPW/serve_token_file_missing.log"
  if [ -n "${DISPLAY:-}" ] && xset q >/dev/null 2>&1 || ! command -v xvfb-run >/dev/null 2>&1; then
    timeout 30 "$BIN" --serve 0 --serve-token-file "$TMPW/does_not_exist.txt" --serve-max-requests 1 > "$MISSING_LOG" 2>&1 &
  else
    timeout 30 timeout 900 xvfb-run -a -s "-screen 0 1600x900x24" "$BIN" --serve 0 --serve-token-file "$TMPW/does_not_exist.txt" --serve-max-requests 1 > "$MISSING_LOG" 2>&1 &
  fi
  MISSING_PID=$!
  MISSING_PORT=""
  for _ in $(seq 1 100); do
    if grep -q "^serve: listening on port " "$MISSING_LOG" 2>/dev/null; then
      MISSING_PORT="$(grep "^serve: listening on port " "$MISSING_LOG" | head -1 | awk '{print $NF}' | tr -d '\r')"
      break
    fi
    sleep 0.1
  done
  if [ -z "$MISSING_PORT" ]; then
    cat "$MISSING_LOG"; echo "FAIL: --serve-token-file (missing file) server never printed its listening port within 10s"; fail=1
    kill "$MISSING_PID" 2>/dev/null || true
    wait "$MISSING_PID" 2>/dev/null || true
  else
    set +e
    MISSING_CODE="$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST --data 'print("should not run")' "http://127.0.0.1:$MISSING_PORT/run")"
    set -e
    [ "$MISSING_CODE" = "401" ] && echo "ok   --serve-token-file pointed at a file that doesn't exist fails CLOSED (401), not open - a bad path can't accidentally disable auth" || { echo "FAIL --serve-token-file with a missing file returned HTTP $MISSING_CODE, expected 401 (fail closed)"; fail=1; }
    set +e; wait "$MISSING_PID"; set -e
  fi
fi

exit $fail
