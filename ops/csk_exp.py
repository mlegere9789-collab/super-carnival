import math
# independent closed forms: hole profile path in (r, depth); plate 20x20x10
A=400.0; T=10.0
def hole_vol(path):
    # pi * integral r^2 d(depth) along a polyline, exact per straight piece
    v=0
    for (r0,d0),(r1,d1) in zip(path,path[1:]):
        v+=math.pi*(d1-d0)*(r0*r0+r0*r1+r1*r1)/3
    return v
def blend_path(path, i, rho=None, d1=None, d2=None, n=20000):
    # vertex i (1..len-2 interior, or 0 / last with implicit plane); returns refined polyline
    P=[(r,-d) for r,d in path]
    if i==0: prev=(P[0][0]+10,P[0][1])
    else: prev=P[i-1]
    if i==len(P)-1: nxt=(P[i][0]+10,P[i][1])
    else: nxt=P[i+1]
    v=P[i]
    def unit(a,b):
        l=math.hypot(b[0]-a[0],b[1]-a[1]); return ((b[0]-a[0])/l,(b[1]-a[1])/l)
    t1=unit(prev,v); t2=unit(v,nxt)
    cr=t1[0]*t2[1]-t1[1]*t2[0]; dt=t1[0]*t2[0]+t1[1]*t2[1]
    phi=math.atan2(abs(cr),dt)
    if rho is not None:
        s1=s2=rho*math.tan(phi/2)
        A_=(v[0]-s1*t1[0],v[1]-s1*t1[1]); B_=(v[0]+s2*t2[0],v[1]+s2*t2[1])
        nrm=(-t1[1],t1[0]) if cr>0 else (t1[1],-t1[0])
        C=(A_[0]+rho*nrm[0],A_[1]+rho*nrm[1])
        a0=math.atan2(A_[1]-C[1],A_[0]-C[0]); a1=math.atan2(B_[1]-C[1],B_[0]-C[0])
        sw=a1-a0
        while sw>math.pi: sw-=2*math.pi
        while sw<-math.pi: sw+=2*math.pi
        mid=[(C[0]+rho*math.cos(a0+sw*k/n),C[1]+rho*math.sin(a0+sw*k/n)) for k in range(n+1)]
    else:
        A_=(v[0]-d1*t1[0],v[1]-d1*t1[1]); B_=(v[0]+d2*t2[0],v[1]+d2*t2[1]); mid=[A_,B_]
    pts=P[:i] if i>0 else []
    out=pts+mid+(P[i+1:] if i<len(P)-1 else [])
    return [(x,-y) for x,y in out]
def vol(path): return A*T-hole_vol(path)
sink=[(6,0),(3,3),(3,10)]
bore=[(5,0),(5,3),(3,3),(3,10)]
print("sink V0",vol(sink),"bore V0",vol(bore))
def show(name,path,i,**kw):
    p=blend_path(path,i,**kw); print(name,round(vol(p),4))
show("F_sink_top",sink,0,rho=1)
show("F_sink_junction",sink,1,rho=1)
show("F_sink_bottom",sink,2,rho=1)
show("C_sink_top_w1_c1",sink,0,d1=1,d2=1) # path-order semantic: d1 on incoming(plane) ... see below
print("----")
def two(path, specs):
    # apply several blends sequentially on distinct vertices by volume deltas (independent regions)
    base=vol(path); tot=base
    for i,kw in specs:
        tot+= vol(blend_path(path,i,**kw))-base
    return tot
show("S_F_top",sink,0,rho=1)
show("S_F_junc",sink,1,rho=1)
show("S_F_bot",sink,2,rho=1)
print("S_F_two",round(two(sink,[(0,dict(rho=1)),(2,dict(rho=0.5))]),4))
show("S_C_top w1 cap0.5",sink,0,d1=0.5,d2=1)   # s1 (plane)=cap 0.5, s2 (wall)=1
show("B_F_top",bore,0,rho=1)
show("B_F_corner",bore,1,rho=1)
show("B_F_floor",bore,2,rho=1)
show("B_F_bot",bore,3,rho=1)
show("B_C_top w1 cap1",bore,0,d1=1,d2=1)
show("B_C_corner wall1 floor0.5",bore,1,d1=1,d2=0.5)
print("B_F_two",round(two(bore,[(0,dict(rho=1)),(3,dict(rho=0.5))]),4))
