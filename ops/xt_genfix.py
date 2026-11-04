# Independent fixture generator (does not use the C++ writer): emits private-profile text for a box, a cylinder, a sphere.
import math

HEADER = """**DINO8-XT-PROFILE: private clean-room encoding modelled on the XT topology/geometry vocabulary - NOT readable by Parasolid
**PART1;
APPL=hand-derived test fixture;
FORMAT=text;
GUISE=transmit;
**PART2;
SCH=SCH_DINO8_1;
USFLD_SIZE=0;
**PART3;
**END_OF_HEADER*****************************************************
T : TRANSMIT FILE hand-derived fixture
SCH_DINO8_1
"""


class W:
    def __init__(self):
        self.n = []

    def add(self, t, *f):
        self.n.append((t, f))
        return len(self.n)

    def set(self, idx, k, v):
        t, f = self.n[idx - 1]
        f = list(f)
        f[k] = v
        self.n[idx - 1] = (t, tuple(f))

    def text(self):
        out = [str(len(self.n))]
        for i, (t, f) in enumerate(self.n, 1):
            toks = []
            for x in f:
                if isinstance(x, bool):
                    toks.append('T' if x else 'F')
                elif isinstance(x, int):
                    toks.append(str(x))
                else:
                    toks.append(repr(float(x)))
            out.append(' '.join([str(t), str(i)] + toks))
        out.append('END')
        return HEADER + '\n'.join(out) + '\n'


def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def unit(a):
    l = math.sqrt(sum(x * x for x in a))
    return tuple(x / l for x in a)
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])


def body(w, solid=True):
    b = w.add(12, 1 if solid else 3, 0)
    rv = w.add(19, b, 0, 0, False)
    w.set(b, 1, rv)
    rs = w.add(19, b, 0, 0, True)
    w.set(rv, 1, rs)
    sh = w.add(13, rs, 0, 0)
    w.set(rs, 2, sh)
    return b, sh


def box(X, Y, Z):
    w = W()
    b, sh = body(w)
    V = {}
    for i in range(8):
        p = (X * (i & 1), Y * ((i >> 1) & 1), Z * ((i >> 2) & 1))
        pn = w.add(29, *p)
        V[i] = (w.add(18, pn, 0.0), p)
    # edges between corner indices differing in one bit
    E = {}
    for i in range(8):
        for bit in (1, 2, 4):
            if not i & bit:
                j = i | bit
                p0, p1 = V[i][1], V[j][1]
                d = unit(sub(p1, p0))
                ln = w.add(30, *p0, *d)
                E[(i, j)] = w.add(16, 0, V[i][0], V[j][0], ln, 0.0)
    # faces: (corner cycle CCW seen from outside, outward normal, plane point)
    def idx(x, y, z): return x | (y << 1) | (z << 2)
    faces = [
        ([idx(0,0,0), idx(0,1,0), idx(0,1,1), idx(0,0,1)], (-1,0,0)),
        ([idx(1,0,0), idx(1,0,1), idx(1,1,1), idx(1,1,0)], (1,0,0)),
        ([idx(0,0,0), idx(0,0,1), idx(1,0,1), idx(1,0,0)], (0,-1,0)),
        ([idx(0,1,0), idx(1,1,0), idx(1,1,1), idx(0,1,1)], (0,1,0)),
        ([idx(0,0,0), idx(1,0,0), idx(1,1,0), idx(0,1,0)], (0,0,-1)),
        ([idx(0,0,1), idx(0,1,1), idx(1,1,1), idx(1,0,1)], (0,0,1)),
    ]
    prev = 0
    for cyc, n in faces:
        a_, b_, c_ = (V[k][1] for k in cyc[:3])
        if sum(x*y for x, y in zip(cross(sub(b_, a_), sub(c_, b_)), n)) < 0:
            cyc = [cyc[0]] + cyc[:0:-1]
        p = V[cyc[0]][1]
        xa = unit(sub(V[cyc[1]][1], p))
        pl = w.add(50, *p, *n, *xa)
        f = w.add(14, sh, 0, 0, pl, True)
        if prev: w.set(prev, 1, f)
        else: w.set(sh, 2, f)
        prev = f
        # check outward orientation: (v1-v0)x(v2-v1) . n > 0
        a, b2, c = (V[k][1] for k in cyc[:3])
        assert sum(x*y for x, y in zip(cross(sub(b2, a), sub(c, b2)), n)) > 0
        lp = w.add(15, f, 0, 0)
        w.set(f, 2, lp)
        pf = 0
        for k in range(4):
            a, b2 = cyc[k], cyc[(k + 1) % 4]
            key = (a, b2) if (a, b2) in E else (b2, a)
            fin = w.add(17, lp, 0, E[key], key == (a, b2))
            if pf: w.set(pf, 1, fin)
            else: w.set(lp, 2, fin)
            pf = fin
    return w.text()


def cylinder(r, h):
    w = W()
    b, sh = body(w)
    vb = w.add(18, w.add(29, r, 0, 0), 0.0)
    vt = w.add(18, w.add(29, r, 0, h), 0.0)
    cb = w.add(31, 0, 0, 0, 0, 0, 1, 1, 0, 0, r)
    ct = w.add(31, 0, 0, h, 0, 0, 1, 1, 0, 0, r)
    eb = w.add(16, 0, vb, vb, cb, 0.0)
    et = w.add(16, 0, vt, vt, ct, 0.0)
    # bottom cap (normal -z): loop clockwise about +z => fin sense F on circle (edge is CCW about +z)
    def face(surf, fins):
        f = w.add(14, sh, 0, 0, surf, True)
        return f
    pb = w.add(50, 0, 0, 0, 0, 0, -1, 1, 0, 0)
    pt = w.add(50, 0, 0, h, 0, 0, 1, 1, 0, 0)
    cy = w.add(51, 0, 0, 0, 0, 0, 1, r, 1, 0, 0)
    f1 = w.add(14, sh, 0, 0, pb, True)
    w.set(sh, 2, f1)
    f2 = w.add(14, sh, 0, 0, pt, True)
    w.set(f1, 1, f2)
    f3 = w.add(14, sh, 0, 0, cy, True)
    w.set(f2, 1, f3)
    def loop(f, edge, sense, prev_loop=0):
        lp = w.add(15, f, 0, 0)
        if prev_loop: w.set(prev_loop, 1, lp)
        else: w.set(f, 2, lp)
        fin = w.add(17, lp, 0, edge, sense)
        w.set(lp, 2, fin)
        return lp
    loop(f1, eb, False)
    loop(f2, et, True)
    l1 = loop(f3, eb, True)
    loop(f3, et, False, l1)
    return w.text()


def sphere(r, c):
    w = W()
    b, sh = body(w)
    sp = w.add(53, *c, r, 0, 0, 1, 1, 0, 0)
    f = w.add(14, sh, 0, 0, sp, True)
    w.set(sh, 2, f)
    return w.text()


if __name__ == '__main__':
    import sys
    out = sys.argv[1]
    for name, txt in (('box', box(1.0, 2.0, 3.0)), ('cylinder', cylinder(1.0, 4.0)), ('sphere', sphere(2.0, (1.0, 2.0, 3.0)))):
        open(f'{out}/fixture_{name}.xt', 'w').write(txt)
