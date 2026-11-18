#!/bin/bash
# Sample CPU of Vibe processes during boot to see if the 12s gap is compute or waiting.
export WINEPREFIX="$HOME/.local/share/wineprefixes/vibe-desktop"
GEWINE="$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest/files/bin/wine"
pkill -f 'vibe-edge-fix --watc[h]' 2>/dev/null
pkill -f 'bin/vibe-deskto[p]' 2>/dev/null
pkill -f 'Vibe\.exe' 2>/dev/null
sleep 2
"$GEWINE" wineserver -k 2>/dev/null
sleep 2
T0=$(date +%s%N)
setsid "$HOME/.local/bin/vibe-desktop" >/dev/null 2>&1 &
ts() { local n=$(date +%s%N); echo "$(( (n - T0) / 1000000000 )).$(( ((n - T0) / 100000000) % 10 ))"; }
for i in $(seq 1 60); do
  sleep 0.5
  nv=$(timeout 2 xdotool search --onlyvisible --class steam_app_0 2>/dev/null | wc -l)
  cpu=$(ps -eo pcpu,comm,args 2>/dev/null | grep -i 'vibe.exe' | grep -v grep | awk '{s+=$1} END {printf "%.0f", s}')
  nwine=$(ps -eo pcpu,comm 2>/dev/null | grep -E 'wineserver|explorer|services|rpcss' | awk '{s+=$1} END {printf "%.0f", s}')
  echo "t=$(ts)s visible_win=$nv vibe_cpu=${cpu}% wine_svc_cpu=${nwine}%"
  [ "$nv" -gt 0 ] 2>/dev/null && [ "$i" -gt 10 ] && break
done
