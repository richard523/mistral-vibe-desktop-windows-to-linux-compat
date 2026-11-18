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
GEWINE="$PROTONPATH/files/bin/wine"
# boot is CPU-bound app init under wine; less logging I/O + higher priority
export WINEDEBUG=-all

WIN_APP='C:\users\'"$USER"'\AppData\Local\Programs\vibe\Vibe.exe'
LOG_DIR="$HOME/.local/state/vibe-desktop"
mkdir -p "$LOG_DIR"

if [ ! -f "$WINEPREFIX/drive_c/users/$USER/AppData/Local/Programs/vibe/Vibe.exe" ]; then
    echo "Vibe Desktop not found in prefix: $WINEPREFIX" >&2
    exit 1
fi

wgeo() { timeout 3 xdotool getwindowgeometry --shell "$1" 2>/dev/null; }
# managed windows (wmctrl lists minimized ones too, but NOT windows we withdrew
# with windowunmap) - decimal ids
managed_list() { wmctrl -l 2>/dev/null | awk '{print strtonum($1)}'; }

# The real main (chat) window = largest MANAGED app window whose title is not a
# helper name. Helpers: 'Default IME'/'Input' (IME), 'Dictation' and
# 'le-chat-desktop' (the splash window that becomes the Dictation window - it
# is only ~0.4% smaller than the chat window, so area alone can't tell them
# apart; the title is the discriminator). Withdrawn helpers are unmanaged, so
# they never show up here. Untitled windows are allowed (chat can be untitled).
find_main() {
    BEST=""; BESTAREA=0
    for w in $(managed_list); do
        cls=$(xprop -id "$w" WM_CLASS 2>/dev/null | awk -F'"' '{print $4}')
        [ "$cls" = "steam_app_0" ] || continue
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


# Already running? Ensure daemons, then bring the existing window back.
if pgrep -f 'Vibe\.exe' > /dev/null 2>&1; then
    pgrep -f 'vibe-edge-fix --watc[h]' > /dev/null 2>&1 || "$HOME/.local/bin/vibe-edge-fix" --watch > /dev/null 2>&1 &
    WID=$(find_main)
    if [ -n "$WID" ]; then
        show_wid "$WID" 1
        exit 0
    fi
    # App running but no managed window = closed to tray. The window is HIDDEN,
    # not destroyed: the X window survives unmapped, geometry and title intact -
    # the app only called hide() on it. (An XDestroyWindow-based test such as
    # `xdotool windowclose` fakes destruction and gave a wrong answer here.)
    #
    # Ask the RUNNING process to show it again: launching a second instance makes
    # Electron's single-instance lock hand off to the primary, whose
    # second-instance handler shows the existing window. Measured 2.2s to a
    # mapped window vs ~15s for a cold boot, and no state damage.
    #
    # Do NOT simplify this to `xdotool windowmap <hidden-id>`: an out-of-band
    # XMapWindow restores the pixels in ~0.3s but leaves Chromium's own
    # visibility flag false, after which the app's close handler (hide) becomes
    # a no-op - close-to-tray silently stops working until the app restarts
    # (verified by experiment: WM_DELETE_WINDOW is delivered and ignored).
    WIN_EXE="$WINEPREFIX/drive_c/users/$USER/AppData/Local/Programs/vibe/Vibe.exe"
    # Boot guard: a young app has no window yet (cold start ~12-15s) and setting
    # up a tray hide needs the window to have appeared, so a young windowless app
    # is starting up, not closed to tray - do nothing (never kill a booting app).
    APP_AGE=$(ps -o etimes= -p "$(pgrep -o -f 'Vibe\.exe' 2>/dev/null)" 2>/dev/null | tr -d ' ')
    if [ -n "$APP_AGE" ] && [ "$APP_AGE" -lt 30 ]; then
        exit 0
    fi
    if [ -x "$GEWINE" ] && [ -f "$WIN_EXE" ]; then
        setsid timeout 30 "$GEWINE" "$WIN_EXE" < /dev/null >> "$LOG_DIR/run.log" 2>&1 &
        n=0
        while [ "$n" -lt 32 ]; do          # <= 8s, the handoff needs ~2.2s
            n=$((n + 1))
            sleep 0.25
            WID=$(find_main)
            if [ -n "$WID" ]; then
                show_wid "$WID" 1
                exit 0
            fi
        done
    fi
    # Last resort (handoff failed: wedged app): kill and cold start, in the
    # background so the click itself never hangs.
    command -v notify-send >/dev/null 2>&1 && notify-send -i mistral-vibe-desktop "Mistral Vibe" "Restoring window (cold start ~15s)..." 2>/dev/null
    pkill -f 'Vibe\.exe' 2>/dev/null
    sleep 1
    WINEPREFIX="$WINEPREFIX" "$GEWINE" wineserver -k 2>/dev/null
    sleep 2
    setsid "$0" < /dev/null >> "$LOG_DIR/run.log" 2>&1 &
    exit 0
fi

# Window helper, runs as long as the app lives:
#  1) tracks the real chat window (largest managed app window, helper titles
#     excluded) and never shows it: close-to-tray must stick, restore happens
#     only on an explicit click (dock icon -> second-instance handoff, or the
#     app's own tray icon);
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
            managed_list | grep -qx "$WID" || WID=""
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
        # Do NOT show/activate the main window here: the user closing it
        # (close-to-tray) must stick. Restore happens only on explicit click
        # (dock/launcher fast path or the app's own tray icon).
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

exec setsid nice -n -5 umu-run "$WIN_APP" < /dev/null >> "$LOG_DIR/run.log" 2>&1
