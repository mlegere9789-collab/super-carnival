import sys
p=sys.argv[1]; L=open(p).read().split('\n'); o=[]; i=0; n=0
while i<len(L):
    if L[i].startswith('<<<<<<< '):
        b=next(j for j in range(i,len(L)) if L[j]=='=======')
        c=next(j for j in range(b,len(L)) if L[j].startswith('>>>>>>> '))
        o+=L[i+1:b]+['']+L[b+1:c]; i=c+1; n+=1
    else: o.append(L[i]); i+=1
open(p,'w').write('\n'.join(o)); print('hunks',n)
