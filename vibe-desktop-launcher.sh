#!/bin/sh
# Mistral Vibe Desktop (official Windows build) via Proton (GE-Proton via umu).
# Installed from vibe-1.1.0-setup.exe (official chat.mistral.ai/download/vibe-desktop/windows),
# payload extracted into the dedicated wine prefix below. Everything is user-local.
#
# Why GE-Proton: measured on this machine (GNOME Wayland + XWayland, Iris Xe):
#   - wine-staging 11.19: paints only with --disable-gpu (GPU proc STATUS_BREAKPOINT via GL/XWayland).
#   - proton-cachyos-slr: app healthy but window never paints (blank, unique_colors=1) in all
#     three configurations (DXVK+GPU, --disable-gpu, PROTON_USE_WINED3D).
#   - GE-Proton10-32 (GPU on, DXVK->Vulkan): window paints, GPU process stable, no crash lines.
# Do not "upgrade" the layer without re-verifying paint (import -window + unique colors).

export WINEPREFIX="$HOME/.local/share/wineprefixes/vibe-desktop"
export GAMEID=0
export PROTONPATH="$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest"

WIN_APP='C:\users\'"$USER"'\AppData\Local\Programs\vibe\Vibe.exe'
LOG_DIR="$HOME/.local/state/vibe-desktop"
mkdir -p "$LOG_DIR"

if [ ! -f "$WINEPREFIX/drive_c/users/$USER/AppData/Local/Programs/vibe/Vibe.exe" ]; then
    echo "Vibe Desktop not found in prefix: $WINEPREFIX" >&2
    exit 1
fi

# largest app window (class steam_app_0), skipping only tiny helper windows
# (IME/Input/Dictation are 1x1..166x45). Main window can have any/empty title.
find_wid() {
    BEST=""; BESTAREA=0
    for w in $(xdotool search --class steam_app_0 2>/dev/null); do
        g=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)
        wd=$(echo "$g" | awk -F= '/^WIDTH=/{print $2}')
        ht=$(echo "$g" | awk -F= '/^HEIGHT=/{print $2}')
        [ -n "$wd" ] && [ -n "$ht" ] || continue
        [ "$wd" -lt 200 ] && continue
        [ "$ht" -lt 150 ] && continue
        area=$((wd * ht))
        if [ "$area" -gt "$BESTAREA" ]; then BESTAREA=$area; BEST=$w; fi
    done
    echo "$BEST"
}

# the real main window = largest app window that has a non-helper title;
# fallback to largest overall
find_main() {
    BEST=""; BESTAREA=0
    for w in $(xdotool search --class steam_app_0 2>/dev/null); do
        n=$(xdotool getwindowname "$w" 2>/dev/null)
        case "$n" in ''|'Default IME'|'Input'|'Dictation') continue;; esac
        g=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)
        wd=$(echo "$g" | awk -F= '/^WIDTH=/{print $2}')
        ht=$(echo "$g" | awk -F= '/^HEIGHT=/{print $2}')
        [ -n "$wd" ] && [ -n "$ht" ] || continue
        [ "$wd" -lt 200 ] && continue
        [ "$ht" -lt 150 ] && continue
        area=$((wd * ht))
        if [ "$area" -gt "$BESTAREA" ]; then BESTAREA=$area; BEST=$w; fi
    done
    [ -z "$BEST" ] && BEST=$(find_wid)
    echo "$BEST"
}

set_skip_taskbar() {  # $1=wid $2=1 hide, 0 unhide
    cur=$(xprop _NET_WM_STATE -id "$1" 2>/dev/null | sed 's/.*= //')
    if [ "$2" = "1" ]; then
        case "$cur" in *SKIP_TASKBAR*) return;; esac
        xprop -id "$1" -f _NET_WM_STATE 32a -set _NET_WM_STATE "${cur:+$cur, }_NET_WM_STATE_SKIP_TASKBAR, _NET_WM_STATE_SKIP_PAGER" 2>/dev/null
    else
        case "$cur" in *SKIP_TASKBAR*) ;; *) return;; esac
        new=$(echo "$cur" | tr ',' '\n' | sed 's/^ *//' | grep -v 'SKIP_TASKBAR\|SKIP_PAGER' | paste -sd, -)
        if [ -n "$new" ]; then
            xprop -id "$1" -f _NET_WM_STATE 32a -set _NET_WM_STATE "$new" 2>/dev/null
        else
            xprop -id "$1" -f _NET_WM_STATE 32a -remove _NET_WM_STATE 2>/dev/null
        fi
    fi
}

show_wid() {
    # $1 = wid (decimal), $2 = 1 to force focus. Otherwise only maps/activates
    # if the window is currently unmapped. Numeric id compare: wmctrl prints
    # zero-padded hex (0x05800008), printf %x does not (0x5800008).
    [ -z "$1" ] && return 1
    if [ "$2" = "1" ] || ! wmctrl -l 2>/dev/null | awk -v t="$1" '{ if (strtonum($1) == t) f = 1 } END { exit !f }'; then
        wmctrl -i -a "$1" 2>/dev/null
    fi
}

# Already running with a window? Make sure the edge-fixer daemon is up, re-show
# the window, done. (If running windowless, fall through: the new instance makes
# the app recreate its window, and the watcher below maps it.)
if pgrep -f 'Vibe\.exe' > /dev/null 2>&1; then
    pgrep -f 'vibe-edge-fix --watc[h]' > /dev/null 2>&1 || "$HOME/.local/bin/vibe-edge-fix" --watch > /dev/null 2>&1 &
    WID=$(find_main)
    if [ -n "$WID" ]; then
        show_wid "$WID" 1
        exit 0
    fi
fi

# Window helper, runs as long as the app lives:
#  1) re-show the main window if it ever ends up unmapped (close-to-tray then
#     relaunch paths can leave it hidden under proton);
#  2) edge-fix daemon (C binary, 200ms poll): sets the X background pixel of
#     every app window to the app's dark #17171B. This kills the white
#     right/bottom bars at creation: Electron reserves a 4px resize frame
#     painted white; XWayland composites that uncovered edge from the window
#     background pixel (wine sets WhitePixel at creation since Chromium's
#     class brush is NULL). Registry colors / wine metrics can't reach this.
#  3) keeps near-fullscreen windows at (1920,29,1928x1023) so any residual
#     edge overhang renders off-monitor (belt and braces).
(
    flock -n 9 || exit 0   # only one watcher loop system-wide
    # Fresh launches reach here before umu/wine has spawned Vibe.exe; without
    # this wait the `while pgrep` below is false at t=0 and the watcher dies
    # instantly -> no edge-fix, no helper hiding, no snap on cold start.
    n=0
    while ! pgrep -f 'Vibe\.exe' > /dev/null 2>&1; do
        n=$((n+1)); [ "$n" -gt 180 ] && exit 0
        sleep 1
    done
    "$HOME/.local/bin/vibe-edge-fix" --watch > /dev/null 2>&1 &
    while pgrep -f 'Vibe\.exe' > /dev/null 2>&1; do
        WID=$(find_main)
        [ -z "$WID" ] && { sleep 2; continue; }
        show_wid "$WID" 0
        set_skip_taskbar "$WID" 0
        "$HOME/.local/bin/vibe-edge-fix" "$WID" >/dev/null 2>&1
        # hide helper/popup windows (everything but the main window) from alt-tab
        for w in $(xdotool search --class steam_app_0 2>/dev/null); do
            [ "$w" = "$WID" ] && continue
            g=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)
            wd=$(echo "$g" | awk -F= '/^WIDTH=/{print $2}')
            ht=$(echo "$g" | awk -F= '/^HEIGHT=/{print $2}')
            [ -n "$wd" ] && [ -n "$ht" ] || continue
            [ "$wd" -lt 200 ] && continue
            [ "$ht" -lt 150 ] && continue
            set_skip_taskbar "$w" 1
        done
        GEO=$(xdotool getwindowgeometry --shell "$WID" 2>/dev/null)
        X=$(echo "$GEO" | awk -F= '/^X=/    {print $2}')
        WD=$(echo "$GEO" | awk -F= '/^WIDTH=/  {print $2}')
        HT=$(echo "$GEO" | awk -F= '/^HEIGHT=/ {print $2}')
        if [ -n "$WD" ] && [ "$WD" -ge 1900 ] && [ -n "$HT" ] && [ "$HT" -ge 1000 ] \
           && [ -n "$X" ] && [ "$X" -ge 1900 ] && [ "$X" -le 1930 ] \
           && { [ "$X" -ne 1920 ] || [ "$WD" -ne 1928 ] || [ "$HT" -ne 1023 ]; }; then
            xdotool windowmove "$WID" 1920 29 2>/dev/null
            xdotool windowsize "$WID" 1928 1023 2>/dev/null
        fi
        sleep 1
    done
) 9>/tmp/vibe-desktop-watcher.lock &

exec setsid umu-run "$WIN_APP" < /dev/null >> "$LOG_DIR/run.log" 2>&1
