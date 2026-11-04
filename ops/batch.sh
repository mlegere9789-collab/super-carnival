#!/bin/bash
S=/tmp/claude-0/-home-user-miniature-pancake/c6eb999f-5b74-501a-aada-aadc6aa22709/scratchpad
T=/home/user/miniature-pancake/.claude/worktrees/agent-a9cb50949c933224e/dino8-app/tests
cd "$S"
python3 mkh.py h_surf.sh $T 1278-1567
python3 mkh.py h_fil.sh $T 2232-2420
python3 mkh.py h_kw.sh $T 8695-8943
python3 mkh.py h_hist.sh $T 6423-6760
python3 mkh.py h_h3r.sh $T 10503-10520 10755-10899
python3 mkh.py h_h4r.sh $T 10503-10520 11221-11357
python3 mkh.py h_sweeps.sh $T 10336-10416 10969-11063 11447-11562
python3 mkh.py h_sx.sh $T 8944-9615
python3 mkh.py h_bge.sh $T 3880-3904
python3 mkh.py h_b2s.sh $T 10417-10641
python3 mkh.py h_frh.sh $T 11358-11446 11563-11674
./runh.sh h_surf.sh & ./runh.sh h_fil.sh & ./runh.sh h_kw.sh & wait
./runh.sh h_hist.sh & ./runh.sh h_h3r.sh & ./runh.sh h_h4r.sh & wait
./runh.sh h_sweeps.sh & ./runh.sh h_sx.sh & ./runh.sh h_bge.sh & wait
./runh.sh h_b2s.sh & ./runh.sh h_frh.sh & wait
echo done > batch.done
