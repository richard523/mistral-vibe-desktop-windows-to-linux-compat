#!/bin/bash
# Measure Vibe Desktop boot phases: launch -> Vibe.exe -> first window ->
# mapped window -> painted window (unique colors > 100).
export WINEPREFIX="$HOME/.local/share/wineprefixes/vibe-desktop"
GEWINE="$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest/files/bin/wine"
pkill -f 'vibe-edge-fix --watc[h]' 2>/dev/null
pkill -f 'bin/vibe-deskto[p]' 2>/dev/null
pkill -f 'Vibe\.exe' 2>/dev/null
sleep 2
"$GEWINE" wineserver -k 2>/dev/null
sleep 2
rm -f /tmp/vibe-desktop-main.wid
d=$HOME/vibe-fresh-test; mkdir -p "$d"
T0=$(date +%s%N)
setsid "$HOME/.local/bin/vibe-desktop" >/dev/null 2>&1 &
ts() { local n=$(date +%s%N); echo "$(( (n - T0) / 1000000000 )).$(( ((n - T0) / 100000000) % 10 ))s"; }
echo "t=0 launch"
done_app=0; done_win=0; done_map=0; done_paint=0
for i in $(seq 1 240); do
  sleep 0.5
  now=$(ts)
  [ $done_app -eq 0 ] && pgrep -f 'Vibe\.exe' >/dev/null 2>&1 && { echo "t=${now}s Vibe.exe process up"; done_app=1; }
  nw=$(timeout 3 xdotool search --class steam_app_0 2>/dev/null | wc -l)
  [ $done_win -eq 0 ] && [ "$nw" -gt 0 ] 2>/dev/null && { echo "t=${now}s first X window ($nw windows)"; done_win=1; }
  nv=$(timeout 3 xdotool search --onlyvisible --class steam_app_0 2>/dev/null | wc -l)
  [ $done_map -eq 0 ] && [ "$nv" -gt 0 ] 2>/dev/null && { echo "t=${now}s first MAPPED window ($nv visible)"; done_map=1; }
  if [ $done_paint -eq 0 ] && [ "$nv" -gt 0 ] 2>/dev/null; then
    best=""; ba=0
    for w in $(timeout 3 xdotool search --onlyvisible --class steam_app_0 2>/dev/null); do
      g=$(timeout 2 xdotool getwindowgeometry --shell "$w" 2>/dev/null); wd=$(echo "$g"|awk -F= '/^WIDTH=/{print $2}'); ht=$(echo "$g"|awk -F= '/^HEIGHT=/{print $2}')
      [ -z "$wd" ] && continue
      a=$((wd*ht)); [ "$a" -gt "$ba" ] 2>/dev/null && { ba=$a; best=$w; }
    done
    if [ -n "$best" ]; then
      f=$d/boot.png; rm -f $f
      timeout 5 import -window "$best" "$f" 2>/dev/null
      if [ -s "$f" ]; then
        uc=$(identify -format '%k' "$f" 2>/dev/null)
        if [ -n "$uc" ] && [ "$uc" -gt 100 ] 2>/dev/null; then echo "t=${now}s window PAINTED (unique colors=$uc, ${best})"; done_paint=1; fi
      fi
    fi
  fi
  [ $done_paint -eq 1 ] && break
done
echo "total boot to painted: $(ts)s"
