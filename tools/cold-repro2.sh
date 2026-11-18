#!/bin/bash
# Cold-launch repro v2: reset, launch, sample windows + pixmap strips + states.
export WINEPREFIX="$HOME/.local/share/wineprefixes/vibe-desktop"
GEWINE="$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest/files/bin/wine"
SP=/home/chardlinux/system-config-history

pkill -f 'vibe-edge-fix --watc[h]' 2>/dev/null
pkill -f 'bin/vibe-deskto[p]' 2>/dev/null
pkill -f 'Vibe\.exe' 2>/dev/null
sleep 2
"$GEWINE" wineserver -k 2>/dev/null
sleep 2
echo "--- cold launch $(date +%H:%M:%S)"
setsid "$HOME/.local/bin/vibe-desktop" >/dev/null 2>&1 &
d="$HOME/vibe-fresh-test"; mkdir -p "$d"

for i in $(seq 1 50); do
  echo "== $(date +%H:%M:%S) app=$(pgrep -cf 'Vibe\.exe') watcher=$(pgrep -cf 'bin/vibe-deskto[p]') edgefix=$(pgrep -cf 'vibe-edge-fix --watc[h]')"
  for w in $(xdotool search --class steam_app_0 2>/dev/null); do
    g=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)
    wd=$(echo "$g"|awk -F= '/^WIDTH=/{print $2}'); ht=$(echo "$g"|awk -F= '/^HEIGHT=/{print $2}')
    x=$(echo "$g"|awk -F= '/^X=/{print $2}'); y=$(echo "$g"|awk -F= '/^Y=/{print $2}')
    [ -z "$wd" ] && continue
    if [ "$wd" -ge 200 ] && [ "$ht" -ge 150 ] 2>/dev/null; then
      st=$(xprop -id "$w" _NET_WM_STATE 2>/dev/null | sed 's/.*= //' | tr ',' ' ')
      echo "   win $w ${wd}x${ht}+${x}+${y} '$(xdotool getwindowname $w 2>/dev/null | head -c 18)' [$st]"
    fi
  done
  if [ $((i % 4)) -eq 0 ]; then
    best=""; ba=0
    for w in $(xdotool search --class steam_app_0 2>/dev/null); do
      g=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)
      wd=$(echo "$g"|awk -F= '/^WIDTH=/{print $2}'); ht=$(echo "$g"|awk -F= '/^HEIGHT=/{print $2}')
      [ -z "$wd" ] && continue
      a=$((wd*ht)); if [ "$a" -gt "$ba" ]; then ba=$a; best=$w; fi
    done
    if [ -n "$best" ]; then
      f="$d/v$i.png"; rm -f "$f"; import -window "$best" "$f" 2>/dev/null
      [ -s "$f" ] && echo "   pixmap main=$best $(bash $SP/scan.sh $f)"
    fi
  fi
  sleep 0.5
done
echo "--- done"
