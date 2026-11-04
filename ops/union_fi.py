import sys,subprocess
p=sys.argv[1]; L=open(p).read().split('\n'); 
def build(addfi):
    o=[]; i=0
    while i<len(L):
        if L[i].startswith('<<<<<<< '):
            b=next(j for j in range(i,len(L)) if L[j]=='=======')
            c=next(j for j in range(b,len(L)) if L[j].startswith('>>>>>>> '))
            o+=L[i+1:b]+(['fi',''] if addfi else [''])+L[b+1:c]; i=c+1
        else: o.append(L[i]); i+=1
    return o
for addfi in (True,False):
    open(p,'w').write('\n'.join(build(addfi)))
    if subprocess.run(['bash','-n',p]).returncode==0:
        print('resolved addfi=%s'%addfi); sys.exit(0)
print('UNRESOLVED'); sys.exit(1)
