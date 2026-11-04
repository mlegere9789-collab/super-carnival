import os
p = '/home/user/miniature-pancake/.claude/worktrees/agent-aa3cc9045c22c4ab3/dino8-app/src/io/WebViewer.cpp'
s = open(p).read()

def rep(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)

rep('''// Mouse-drag orbits, the wheel zooms; the initial camera frames the whole
// scene's bounding sphere so a document of any size opens nicely centered.''',
'''// Mouse-drag (or one finger / a pen) orbits, the wheel (or a two-finger
// pinch) zooms - Pointer Events, so one code path serves mouse, touch and
// pen, with `touch-action:none` so the page itself never scrolls or
// browser-zooms under the gesture; the initial camera frames the whole
// scene's bounding sphere so a document of any size opens nicely centered.
// This is the "touch-first companion" slice that fits in a static file: a
// phone/tablet browser can open the exported .html and orbit/zoom/scale
// parts with fingers. There is no native companion app and no
// edit-and-sync-back to a Dino 8 document; the camera state is readable at
// window.__dino8Viewer.camera() so tests can verify touch gestures for real.''')

rep('''<html><head><meta charset="utf-8"><title>Dino 8 model viewer</title>
<style>
  html,body{margin:0;height:100%;background:#2b2e33;overflow:hidden}
  canvas{display:block;width:100%;height:100%}''',
'''<html><head><meta charset="utf-8"><title>Dino 8 model viewer</title>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<style>
  html,body{margin:0;height:100%;background:#2b2e33;overflow:hidden;overscroll-behavior:none}
  canvas{display:block;width:100%;height:100%;touch-action:none}''')

rep('''  #controls .ctrlRow input{width:120px}
</style></head>''',
'''  #controls .ctrlRow input{width:120px}
  @media (pointer:coarse){
    #controls{font-size:15px;padding:10px 12px}
    #controls .ctrlRow{margin:10px 0}
    #controls .ctrlRow input{width:150px;height:32px}
    #hint{font-size:14px}
  }
</style></head>''')

rep('<div id="hint">drag to orbit &middot; wheel to zoom</div>',
    '<div id="hint">drag or one finger to orbit &middot; wheel or pinch to zoom</div>')

rep('''  let dragging = false, lastX = 0, lastY = 0;
  canvas.addEventListener('mousedown', e => { dragging = true; lastX = e.clientX; lastY = e.clientY; });
  window.addEventListener('mouseup', () => { dragging = false; });
  window.addEventListener('mousemove', e => {
    if (!dragging) return;
    yaw += (e.clientX - lastX) * 0.01;
    pitch = Math.max(-1.5, Math.min(1.5, pitch + (e.clientY - lastY) * 0.01));
    lastX = e.clientX; lastY = e.clientY;
  });
  canvas.addEventListener('wheel', e => {
    dist = Math.max(RADIUS * 0.05, Math.min(RADIUS * 50, dist * (e.deltaY > 0 ? 1.1 : 0.9)));
    e.preventDefault();
  }, {passive:false});
''',
'''  // Pointer Events: one pointer orbits (mouse drag, one finger, a pen);
  // two pointers pinch-zoom (distance between them scales the camera
  // distance). The same handlers serve every input type.
  const pointers = new Map();
  let pinchSpan = 0;
  function clampDist(d) { return Math.max(RADIUS * 0.05, Math.min(RADIUS * 50, d)); }
  function span() {
    const v = Array.from(pointers.values());
    return Math.hypot(v[0].x - v[1].x, v[0].y - v[1].y);
  }
  canvas.addEventListener('pointerdown', e => {
    pointers.set(e.pointerId, {x: e.clientX, y: e.clientY});
    try { canvas.setPointerCapture(e.pointerId); } catch (_) {}
    if (pointers.size === 2) pinchSpan = span();
    e.preventDefault();
  });
  canvas.addEventListener('pointermove', e => {
    const p = pointers.get(e.pointerId);
    if (!p) return;
    const dx = e.clientX - p.x, dy = e.clientY - p.y;
    p.x = e.clientX; p.y = e.clientY;
    if (pointers.size === 1) {
      yaw += dx * 0.01;
      pitch = Math.max(-1.5, Math.min(1.5, pitch + dy * 0.01));
    } else if (pointers.size === 2) {
      const s = span();
      if (pinchSpan > 0 && s > 0) dist = clampDist(dist * pinchSpan / s);
      pinchSpan = s;
    }
    e.preventDefault();
  });
  function endPointer(e) {
    pointers.delete(e.pointerId);
    if (pointers.size === 2) pinchSpan = span();
  }
  canvas.addEventListener('pointerup', endPointer);
  canvas.addEventListener('pointercancel', endPointer);
  canvas.addEventListener('wheel', e => {
    dist = clampDist(dist * (e.deltaY > 0 ? 1.1 : 0.9));
    e.preventDefault();
  }, {passive:false});
  window.__dino8Viewer.camera = function () { return {yaw: yaw, pitch: pitch, dist: dist, pointers: pointers.size}; };
''')
open(p, 'w').write(s)
print('patched')
