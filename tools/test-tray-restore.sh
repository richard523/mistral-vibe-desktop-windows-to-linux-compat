#!/bin/bash
# wait for main window, then test: minimize (proxy for close-to-tray) -> launcher -> restored;
# then real close (WM_DELETE) -> launcher -> restored.
for i in $(seq 1 40); do
  sleep 2
  M=$(cat /tmp/vibe-desktop-main.wid 2>/dev/null)
  [ -n "$M" ] && wmctrl -l 2>/dev/null | grep -q "$(printf '0x%08x' "$M" 2>/dev/null)" && break
done
M=$(cat /tmp/vibe-desktop-main.wid 2>/dev/null)
echo "main=$M '$(timeout 3 xdotool getwindowname "$M" 2>/dev/null)'"
wmctrl -lG
echo "=== TEST 1: minimize (hidden) then launcher (what tray click does)"
wmctrl -i -r "$M" -b add,hidden 2>/dev/null; sleep 0.5
echo "hidden: wmctrl-has=$((wmctrl -l | grep -c "$(printf '0x%08x' "$M")"))"
T0=$(date +%s%N); timeout 15 "$HOME/.local/bin/vibe-desktop"; rc=$?; T1=$(date +%s%N)
echo "launcher rc=$rc took $(( (T1-T0)/1000000 ))ms; main in wmctrl: $(wmctrl -l | grep -c "$(printf '0x%08x' "$M")"), state: $(xprop -id "$M" _NET_WM_STATE 2>/dev/null | grep -c HIDDEN) hidden"
echo "=== TEST 2: real close (WM_DELETE -> app goes to tray/windowless) then launcher"
timeout 5 xdotool windowclose "$M" 2>/dev/null; sleep 3
echo "after close: app=$(pgrep -cf 'Vibe\.exe') wmctrl-app-windows=$(wmctrl -lG | grep -c steam_app_0; wmctrl -l | wc -l)"
wmctrl -lG | tail -n +2
T0=$(date +%s%N); timeout 25 "$HOME/.local/bin/vibe-desktop"; rc=$?; T1=$(date +%s%N)
echo "launcher rc=$rc took $(( (T1-T0)/1000000 ))ms"
sleep 8
echo "after restore:"; wmctrl -lG
M2=$(cat /tmp/vibe-desktop-main.wid 2>/dev/null); echo "mainfile=$M2 '$(timeout 3 xdotool getwindowname "$M2" 2>/dev/null)'"
echo "procs: app=$(pgrep -cf 'Vibe\.exe') watcher=$(pgrep -cf 'bin/vibe-deskto[p]') edgefix=$(pgrep -cf 'vibe-edge-fix --watc[h]') tray=$(pgrep -cf 'vibe-tray.p[y]')"
