T = '/home/user/miniature-pancake/.claude/worktrees/agent-a9d52e233fd29516e/dino8-app/tests/'
p = T + 'satf_script.txt'
s = open(p).read()
a = '''Import @TMP@/satf_sphere.sat
SelAll
List
'''
assert a in s
s = s.replace(a, '''Import @TMP@/satf_sphere.sat
SelAll
List
Volume
''')
s = s.replace('''#   Volume lines: [0] the box before export, [1] the box re-opened from the
#   .sat file, [2] the cylinder re-opened from its .sat file.''', '''#   Volume lines: [0] the box before export, [1] the box re-opened from the
#   .sat file, [2] the sphere imported from its .sat file (r 8: 2144.7; the
#   app's Volume is tessellation based), [3] the cylinder re-opened from its
#   .sat file.''')
open(p, 'w').write(s)

p = T + 'smoke.sh'
s = open(p).read()
a = '''if [ "${#SATF_VOLS[@]}" -ge 3 ]; then
  satf_range "${SATF_VOLS[0]}" 3999.5 4000.5 "box Volume before export (20 x 20 x 10 = 4000)"
  satf_range "${SATF_VOLS[1]}" 3999.5 4000.5 "box Volume after .sat export and Open (4000)"
  satf_range "${SATF_VOLS[2]}" 770 800 "cylinder Volume after .sat export and Open vs pi r^2 h = 785.4"
else
  echo "FAIL satf script printed only ${#SATF_VOLS[@]} Volume lines (expected 3)"; fail=1
fi'''
assert a in s
b = '''if [ "${#SATF_VOLS[@]}" -ge 4 ]; then
  satf_range "${SATF_VOLS[0]}" 3999.5 4000.5 "box Volume before export (20 x 20 x 10 = 4000)"
  satf_range "${SATF_VOLS[1]}" 3999.5 4000.5 "box Volume after .sat export and Open (4000)"
  satf_range "${SATF_VOLS[2]}" 2090 2160 "sphere Volume after .sat export and Import vs 4/3 pi r^3 = 2144.7 (it was 0 before the whole-sphere face was rebuilt as a native sphere)"
  satf_range "${SATF_VOLS[3]}" 770 800 "cylinder Volume after .sat export and Open vs pi r^2 h = 785.4"
else
  echo "FAIL satf script printed only ${#SATF_VOLS[@]} Volume lines (expected 4)"; fail=1
fi
satf_has "is a whole sphere face with no edges; it was rebuilt as the application's native sphere Brep" "a whole-sphere body from the file is rebuilt as the app's native sphere and the summary says so"'''
s = s.replace(a, b)
open(p, 'w').write(s)
