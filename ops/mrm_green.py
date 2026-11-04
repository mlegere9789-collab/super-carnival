import math

def vol(poly, blends):
    """blends: {idx: ('f', r)} or {idx: ('c', dprev, dnext)}; V = pi * closed-integral rho^2 dz, arcs in closed form."""
    n = len(poly)
    seg = lambda p, q: (q[1]-p[1])*(p[0]*p[0]+p[0]*q[0]+q[0]*q[0])/3.0
    ins = list(poly); outs = list(poly); arc = {}
    for i, b in blends.items():
        C = poly[i]; A = poly[(i-1) % n]; B = poly[(i+1) % n]
        ax, az = A[0]-C[0], A[1]-C[1]; la = math.hypot(ax, az); ax /= la; az /= la
        bx, bz = B[0]-C[0], B[1]-C[1]; lb = math.hypot(bx, bz); bx /= lb; bz /= lb
        if b[0] == 'f':
            r = b[1]
            nax, naz = -az, ax
            if nax*bx+naz*bz < 0: nax, naz = -nax, -naz
            nbx, nbz = -bz, bx
            if nbx*ax+nbz*az < 0: nbx, nbz = -nbx, -nbz
            det = nax*nbz-naz*nbx
            dx = (r*nbz-naz*r)/det; dz = (nax*r-r*nbx)/det
            c = (C[0]+dx, C[1]+dz)
            ins[i] = (c[0]-r*nax, c[1]-r*naz); outs[i] = (c[0]-r*nbx, c[1]-r*nbz)
            arc[i] = (c, r)
        else:
            ins[i] = (C[0]+b[1]*ax, C[1]+b[1]*az); outs[i] = (C[0]+b[2]*bx, C[1]+b[2]*bz)
    tot = 0.0
    for i in range(n):
        if i in arc:
            c, r = arc[i]
            a0 = math.atan2(ins[i][1]-c[1], ins[i][0]-c[0]); a1 = math.atan2(outs[i][1]-c[1], outs[i][0]-c[0])
            while a1-a0 > math.pi: a1 -= 2*math.pi
            while a1-a0 < -math.pi: a1 += 2*math.pi
            cx = c[0]
            F = lambda ph: r*(cx*cx*math.sin(ph)+2*cx*r*(ph/2+math.sin(2*ph)/4)+r*r*(math.sin(ph)-math.sin(ph)**3/3))
            tot += F(a1)-F(a0)
        else:
            tot += seg(ins[i], outs[i])
        tot += seg(outs[i], ins[(i+1) % n])
    return math.pi*tot

