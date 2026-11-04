p='/home/user/miniature-pancake/.claude/worktrees/agent-a9cb50949c933224e/dino8-app/tests/sbl_script.txt'
s=open(p).read()
old=s[s.index("SBLBEGIN_sequential"):s.index("# Shell of the sealed")]
new='''SBLBEGIN_sequential
Box 0,0,0 10,10,0 10
Cylinder 3,5,-5 1.5 20
SelNone
SelID 1
BooleanDifference
SelID 2
Enter
Cylinder 7,5,-5 1.5 20
SelNone
SelID 3
BooleanDifference
SelID 4
Enter
SelAll
Check
List
Volume
'''
s=s.replace(old,new)
s=s.replace("SelAll\nShell 0.5\nSelAll\nList","SelAll\nShell\nEnter\n0.5\nSelAll\nList")
s=s.replace("Box 100000,100000,100000 100010,100010,100000 10\nCylinder 100005,100005,99995 2 20","Box 100000,100000,0 100010,100010,0 10\nCylinder 100005,100005,-5 2 20")
open(p,'w').write(s)
