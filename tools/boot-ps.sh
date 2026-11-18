#!/bin/bash
# Per-process CPU during boot: which Vibe.exe --type= burns the 12s?
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
for i in $(seq 1 40); do
  sleep 1
  line="t=$(ts)s"
  for t in '' '--type=gpu-process' '--type=renderer' '--type=utility'; do
    c=$(ps -eo pcpu,args 2>/dev/null | grep "Vibe.exe" | grep -F -- "$t" | grep -v grep | awk '{s+=$1} END {printf "%.0f", s}')
    line="$line [${t:-main}]=${c}%"
  done
  nv=$(timeout 2 xdotool search --onlyvisible --class steam_app_0 2>/dev/null | wc -l)
  echo "$line visible=$nv"
  [ "$nv" -gt 0 ] 2>/dev/null && break
done
