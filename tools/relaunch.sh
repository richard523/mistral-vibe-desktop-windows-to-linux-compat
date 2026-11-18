#!/bin/bash
# clean relaunch with current launcher code
export WINEPREFIX="$HOME/.local/share/wineprefixes/vibe-desktop"
GEWINE="$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest/files/bin/wine"
pkill -f 'vibe-edge-fix --watc[h]' 2>/dev/null
pkill -f 'bin/vibe-deskto[p]' 2>/dev/null
pkill -f 'Vibe\.exe' 2>/dev/null
sleep 2
"$GEWINE" wineserver -k 2>/dev/null
sleep 2
rm -f /tmp/vibe-desktop-main.wid
setsid "$HOME/.local/bin/vibe-desktop" >/dev/null 2>&1 &
echo "launched $(date +%H:%M:%S)"
