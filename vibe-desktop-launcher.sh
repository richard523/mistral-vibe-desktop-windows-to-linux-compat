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

wgeo() { timeout 3 xdotool getwindowgeometry --shell "$1" 2>/dev/null; }
vis_list() { timeout 5 xdotool search --onlyvisible --class steam_app_0 2>/dev/null; }

# The real main (chat) window = largest VISIBLE app window whose title is not a
# helper name. Helpers: 'Default IME'/'Input' (IME), 'Dictation' and
# 'le-chat-desktop' (the splash window that becomes the Dictation window - it
# is only ~0.4% smaller than the chat window, so area alone can't tell them
# apart; the title is the discriminator). --onlyvisible so already-withdrawn
# helpers are never candidates. Untitled windows are allowed (chat can be
# untitled); at startup the splash then wins until the titled chat appears.
find_main() {
    BEST=""; BESTAREA=0
    for w in $(vis_list); do
        n=$(timeout 3 xdotool getwindowname "$w" 2>/dev/null)
        case "$n" in 'Default IME'|'Input'|'Dictation'|'le-chat-desktop') continue;; esac
        g=$(wgeo "$w")
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
        # Keep the previous main window while it lives and stays visible - so a
        # transient popup can't steal "main" and get the chat window hidden.
        # Switch only when a non-helper candidate is >20% larger (startup splash
        # -> real chat window). The persisted id is dropped if it died, got
        # withdrawn, shrank, or turned out to be a helper-titled window.
        MAINFILE=/tmp/vibe-desktop-main.wid
        WID=$(cat "$MAINFILE" 2>/dev/null)
        if [ -n "$WID" ]; then
            vis_list | grep -qx "$WID" || WID=""
            if [ -n "$WID" ]; then
                case "$(timeout 3 xdotool getwindowname "$WID" 2>/dev/null)" in
                    'Default IME'|'Input'|'Dictation'|'le-chat-desktop') WID="" ;;
                esac
            fi
            if [ -n "$WID" ]; then
                g=$(wgeo "$WID")
                wd=$(echo "$g" | awk -F= '/^WIDTH=/{print $2}')
                ht=$(echo "$g" | awk -F= '/^HEIGHT=/{print $2}')
                { [ -n "$wd" ] && [ "$wd" -ge 200 ] && [ "$ht" -ge 150 ]; } || WID=""
            fi
            if [ -n "$WID" ]; then
                CAND=$(find_main)
                if [ -n "$CAND" ] && [ "$CAND" != "$WID" ]; then
                    g=$(wgeo "$WID");  wd=$(echo "$g" | awk -F= '/^WIDTH=/{print $2}');  ht=$(echo "$g" | awk -F= '/^HEIGHT=/{print $2}')
                    g2=$(wgeo "$CAND"); wd2=$(echo "$g2" | awk -F= '/^WIDTH=/{print $2}'); ht2=$(echo "$g2" | awk -F= '/^HEIGHT=/{print $2}')
                    if [ -n "$wd2" ] && [ -n "$ht2" ] && [ $((wd2 * ht2)) -gt $((wd * ht * 12 / 10)) ]; then
                        WID=$CAND
                        echo "$WID" > "$MAINFILE"
                    fi
                fi
            fi
        fi
        if [ -z "$WID" ]; then
            WID=$(find_main)
            [ -n "$WID" ] && echo "$WID" > "$MAINFILE"
        fi
        [ -z "$WID" ] && { sleep 1; continue; }
        set_skip_taskbar "$WID" 0
        # un-minimize the main window if it ever got hidden (close-to-tray etc.)
        case "$(xprop -id "$WID" _NET_WM_STATE 2>/dev/null)" in
            *HIDDEN*) wmctrl -i -a "$WID" 2>/dev/null ;;
            *) show_wid "$WID" 0 ;;
        esac
        "$HOME/.local/bin/vibe-edge-fix" "$WID" >/dev/null 2>&1
        # hide helper/popup windows (everything but the main window), but never
        # touch a FOCUSED window - that's an active popup (file dialog, or the
        # Dictation overlay during a dictation session) the user is looking at.
        # Idle Dictation (full-size, unfocused, behind main) gets windowunmap:
        # withdrawn from the WM (no alt-tab/overview/screen presence) while the
        # app can still re-map+focus it when dictation starts. Other helpers
        # (the splash) get minimized (mutter ignores wmctrl -b add,hidden).
        for w in $(xdotool search --class steam_app_0 2>/dev/null); do
            [ "$w" = "$WID" ] && continue
            g=$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)
            wd=$(echo "$g" | awk -F= '/^WIDTH=/{print $2}')
            ht=$(echo "$g" | awk -F= '/^HEIGHT=/{print $2}')
            [ -n "$wd" ] && [ -n "$ht" ] || continue
            [ "$wd" -lt 200 ] && continue
            [ "$ht" -lt 150 ] && continue
            st=$(xprop -id "$w" _NET_WM_STATE 2>/dev/null)
            case "$st" in *FOCUSED*) continue ;; esac   # active popup: leave it alone
            set_skip_taskbar "$w" 1
            n=$(xdotool getwindowname "$w" 2>/dev/null)
            case "$n" in
                Dictation) wmctrl -i -r "$w" -b remove,above 2>/dev/null ;;
            esac
            # withdraw every idle helper (splash, idle Dictation) from the WM
            # entirely: minimized windows still show up in GNOME alt-tab/overview
            # and wmctrl; an unmapped window does not. The app can re-map on
            # demand (dictation) and the watcher then leaves it alone (focused).
            xdotool windowunmap "$w" 2>/dev/null
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
