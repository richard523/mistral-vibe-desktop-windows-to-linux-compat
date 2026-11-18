#!/bin/sh
# install.sh — install Mistral Vibe Desktop (official Windows build) on Linux
# via GE-Proton/umu, plus the launcher, edge-fix, tray icon and desktop entries.
# Usage:  ./install.sh [/path/to/vibe-1.1.0-setup.exe]
# See README.md for the full story. Everything is user-local; nothing system-wide.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SETUP=${1:-"$HOME/Downloads/vibe-1.1.0-setup.exe"}
PREFIX="$HOME/.local/share/wineprefixes/vibe-desktop"
GE="$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest"
BIN="$HOME/.local/bin"
APPDIR="$PREFIX/drive_c/users/$USER/AppData/Local/Programs/vibe"

[ -d "$GE" ] || { echo "GE-Proton not found at $GE (install Proton-GE via ProtonUp-Qt, put it in compatibilitytools.d)" >&2; exit 1; }
[ -f "$SETUP" ] || { echo "installer not found: $SETUP (download from https://chat.mistral.ai/download/vibe-desktop/windows in a browser)" >&2; exit 1; }

echo "== extract payload (the NSIS installer itself fails under wine, rc=2)"
TMP=$(mktemp -d)
7z x "$SETUP" -o"$TMP" >/dev/null
7z x "$TMP/\$PLUGINSDIR/app-64.7z" -o"$TMP/payload" >/dev/null
mkdir -p "$PREFIX/drive_c/users/$USER/AppData/Local/Programs"
rm -rf "$APPDIR"
cp -a "$TMP/payload" "$APPDIR"
rm -rf "$TMP"

echo "== install scripts"
mkdir -p "$BIN" "$HOME/.local/state/vibe-desktop"
cp "$HERE/vibe-desktop-launcher.sh" "$BIN/vibe-desktop"
chmod +x "$BIN/vibe-desktop"
cp "$HERE/vibe-edge-fix.c" "$BIN/vibe-edge-fix.c"
cc -O2 -o "$BIN/vibe-edge-fix" "$BIN/vibe-edge-fix.c" -lX11
cp "$HERE/vibe-tray.py" "$BIN/vibe-tray.py"
chmod +x "$BIN/vibe-tray.py"

echo "== desktop entries + autostart"
mkdir -p "$HOME/.local/share/applications" "$HOME/.config/autostart" "$HOME/.local/share/icons/hicolor/128x128/apps" "$HOME/.local/share/icons/hicolor/48x48/apps"
sed "s|/home/chardlinux|$HOME|g" "$HERE/mistral-vibe-desktop.desktop" > "$HOME/.local/share/applications/mistral-vibe-desktop.desktop"
sed "s|/home/chardlinux|$HOME|g" "$HERE/autostart-mistral-vibe-desktop.desktop" > "$HOME/.config/autostart/mistral-vibe-desktop.desktop"
sed "s|/home/chardlinux|$HOME|g" "$HERE/vibe-tray-autostart.desktop" > "$HOME/.config/autostart/vibe-tray.desktop"
# icon: extract from the exe if a tool is available, else skip (generic icon)
if command -v wrestool >/dev/null 2>&1 && command -v icotool >/dev/null 2>&1; then
    wrestool -x --type=14 "$APPDIR/Vibe.exe" -o "$TMP" 2>/dev/null || true
fi
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo "== dark wine palette (wine-drawn bevels + file dialogs)"
WINEPREFIX="$PREFIX" "$GE/files/bin/wine" reg add 'HKCU\Control Panel\Colors' /v ActiveBorder /d '48 48 54' /f >/dev/null 2>&1 || true
# (full palette used on the reference machine is in README.md section 4)

echo "== app config: disable the app's own tray icon (it never reaches GNOME under
#    wine; we provide our own via vibe-tray.py)"
CFGDIR="$PREFIX/drive_c/users/$USER/AppData/Roaming/le-chat-desktop"
mkdir -p "$CFGDIR"
python3 - "$CFGDIR/config.json" <<'EOF'
import json, os, sys
p = sys.argv[1]
c = {}
if os.path.exists(p):
    try: c = json.load(open(p))
    except Exception: pass
c["showTrayIconEnabled"] = False
json.dump(c, open(p, "w"), indent="\t")
EOF

echo "== done. Launch with:  vibe-desktop   (or the 'Mistral Vibe Desktop' app icon)"
echo "   Proton layer: $GE"
