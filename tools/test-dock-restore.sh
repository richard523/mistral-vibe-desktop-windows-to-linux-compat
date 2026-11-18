#!/bin/bash
# Verify the dock-icon behaviour the launcher implements (README §10):
#   window up               -> click activates it, no new process
#   closed to tray          -> click re-shows the SAME window via the
#                              second-instance handoff, no restart
#   close after that        -> must still hide (guards the out-of-band-map trap)
#
# Usage: tools/test-dock-restore.sh            (expects the app running)
set -u
LAUNCHER="$HOME/.local/bin/vibe-desktop"
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1

hex8() { printf '0x%08x' "$1"; }          # wmctrl prints zero-padded hex
state() {                                  # map_state of a wmctrl-style id: 0 unmapped, 2 viewable
    # xenum dies on BadWindow races while the app churns windows, so retry.
    local dec s; dec=$(printf '%d' "$1") || return 1
    for _ in 1 2 3 4 5; do
        s=$(python3 "$HERE/xenum.py" 2>/dev/null | awk -v id="$(printf '0x%x' "$dec")" \
              '$1==id {sub(/map=/, "", $4); print $4; exit}')
        [ -n "$s" ] && { echo "$s"; return 0; }
        sleep 0.15
    done
}
mainwid() {                                # largest managed steam_app_0 window, helpers excluded
    for w in $(wmctrl -l 2>/dev/null | awk '{print $1}'); do
        [ "$(xprop -id "$w" WM_CLASS 2>/dev/null | awk -F'"' '{print $4}')" = "steam_app_0" ] || continue
        case "$(timeout 3 xdotool getwindowname "$w" 2>/dev/null)" in
            'Default IME'|'Input'|'Dictation'|'le-chat-desktop') continue;;
        esac
        g=$(timeout 3 xdotool getwindowgeometry --shell "$w" 2>/dev/null)
        wd=$(echo "$g" | awk -F= '/^WIDTH=/{print $2}'); ht=$(echo "$g" | awk -F= '/^HEIGHT=/{print $2}')
        [ -n "$wd" ] && [ "$wd" -ge 200 ] && [ -n "$ht" ] && [ "$ht" -ge 150 ] || continue
        echo "$((wd * ht)) $w"
    done | sort -rn | awk 'NR==1{print $2}'
}
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
procs() { pgrep -cf 'Vibe\.exe'; }

M=$(mainwid); M=${M:-$(cat /tmp/vibe-desktop-main.wid 2>/dev/null)}
[ -n "${M:-}" ] || { echo "FAIL: no app window found"; exit 1; }
echo "main=$M '$(timeout 3 xdotool getwindowname "$M" 2>/dev/null)' procs=$(procs)"

echo "=== TEST 1: click while the window is up (must activate in place)"
P0=$(procs); T0=$(date +%s%N); timeout 15 "$LAUNCHER"; RC=$?
echo "launcher rc=$RC took $(ms "$T0")ms procs $P0 -> $(procs) state=$(state "$M")"

echo "=== TEST 2: real close (WM_DELETE, what the titlebar X does) -> dock click"
wmctrl -i -c "$(hex8 "$M")" 2>/dev/null; sleep 2
echo "after close: state=$(state "$M") (0=hidden, window must still exist) procs=$(procs)"
T0=$(date +%s%N); timeout 25 "$LAUNCHER"; RC=$?
echo "launcher rc=$RC took $(ms "$T0")ms"
for i in $(seq 1 20); do sleep 0.25; [ "$(state "$M")" = "2" ] && break; done
echo "restored: state=$(state "$M") (2=viewable) procs=$(procs) same-id=$([ "$(mainwid)" = "$M" ] && echo yes || echo NO)"

echo "=== TEST 3: close again - must hide (guards the windowmap trap from README §10)"
wmctrl -i -c "$(hex8 "$M")" 2>/dev/null; sleep 2
S=$(state "$M")
if [ "$S" = "0" ]; then echo "PASS: close puts it back to hidden-to-tray (state=0)"; else
    echo "FAIL: close was ignored (state=$S) - someone used an out-of-band windowmap"; fi
