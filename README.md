# Mistral Vibe Desktop on Linux (CachyOS / GNOME Wayland) — full runbook

How the official Windows-only Vibe Desktop 1.1.0 was made to run well on this
machine: Proton (GE-Proton) via umu-run, hardware-accelerated, with all the
window/chrome quirks fixed. Everything is user-local; nothing system-wide.

Machine context: CachyOS (Arch-based), GNOME on Wayland + XWayland, dual
1920x1080 monitors (eDP-1 at +0+0, DP-6 primary at +1920+0), i7-12700H,
Iris Xe + RTX 3070 Ti, 16 GB RAM with aggressive zram tuning.

## 0. What the app is

- Vibe Desktop 1.1.0 is the official **proprietary** Mistral desktop app
  (internal name `le-chat-desktop`, Electron 45.2.1). Official downloads are
  macOS/Windows only; Linux is "coming soon" (docs.mistral.ai/vibe/code/desktop).
- Distinct from the open-source `mistral-vibe` CLI (Apache-2.0) already on
  this machine — different product.
- Download: `https://chat.mistral.ai/download/vibe-desktop/windows?from=website`
  (Cloudflare-gated; fetched via the user's Firefox). File kept at
  `~/Downloads/vibe-1.1.0-setup.exe`, 274,448,856 bytes,
  sha256 `d946312b91d95f495b7e50de4e9072de51d3ce0530034ebaa30da4a167e391aa`
  (NSIS 3.04 electron-builder).

## 1. Install (NSIS installer fails under wine — extract instead)

The NSIS installer exits rc=2 under wine (banner-plugin OS probe fails) even
with a Win11 prefix profile. Workaround: extract the payload directly.

```sh
7z x ~/Downloads/vibe-1.1.0-setup.exe -o/tmp/nsis        # -> $PLUGINSDIR/app-64.7z
7z x /tmp/nsis/'$PLUGINSDIR'/app-64.7z -o/tmp/payload
P=~/.local/share/wineprefixes/vibe-desktop
mkdir -p "$P/drive_c/users/$USER/AppData/Local/Programs"
cp -a /tmp/payload "$P/drive_c/users/$USER/AppData/Local/Programs/vibe"
```

Electron apps need no installer registry entries, so a plain copy works.
App data lives in `$P/drive_c/users/$USER/AppData/Roaming/le-chat-desktop`.

## 2. Compatibility layer: GE-Proton via umu (measured, not guessed)

| Layer | Result on this machine |
|---|---|
| wine-staging 11.19 | works only with `--disable-gpu` (GPU proc STATUS_BREAKPOINT via wine GL/XWayland); ~1.3 GiB RSS |
| proton-cachyos-slr (umu) | app fully healthy but window NEVER paints (unique_colors=1) in all 3 configs: DXVK+GPU, `--disable-gpu`, `PROTON_USE_WINED3D=1`. Do not use. |
| **GE-Proton10-32** ("Proton-GE Latest", `~/.local/share/Steam/compatibilitytools.d/Proton-GE Latest`) | **chosen**: GPU on via DXVK→Vulkan on Iris Xe, window paints, GPU proc crash-count 0, ~520-580 MiB RSS, sign-in (browser OIDC) works, active sessions verified |

Launch line:

```sh
GAMEID=0 PROTONPATH="$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest" \
WINEPREFIX="$HOME/.local/share/wineprefixes/vibe-desktop" \
umu-run 'C:\users\chardlinux\AppData\Local\Programs\vibe\Vibe.exe'
```

Under Proton the app's WM_CLASS is `steam_app_0` (GAMEID=0) — the .desktop
entry uses `StartupWMClass=steam_app_0`.

Files installed:
- `~/.local/bin/vibe-desktop` — launcher (see `vibe-desktop-launcher.sh` here)
- `~/.local/bin/vibe-edge-fix` + `vibe-edge-fix.c` — white-edge fixer (below)
- `~/.local/share/applications/mistral-vibe-desktop.desktop` — GNOME entry
- `~/.local/share/icons/hicolor/{128x128,48x48}/apps/mistral-vibe-desktop.png`
  (extracted from Vibe.exe `.rsrc` ICON/8.ico)
- log: `~/.local/state/vibe-desktop/run.log`

## 3. Launcher behavior (`vibe-desktop-launcher.sh`)

1. If the app is already running with a window: just map+focus it (relaunch =
   show). If running windowless (close-to-tray destroyed the X window), launch
   again so the app recreates its window.
2. One watcher loop (flock-guarded; waits up to 180 s for Vibe.exe to appear —
   without that wait a cold launch killed it at t=0 and nothing was fixed all
   session, the "by default still broken" bug) while the app lives:
   - re-shows/un-minimizes the main window if hidden (close-to-tray relaunch)
   - re-applies the edge fix to the main window
   - marks every non-main app window `_NET_WM_STATE_SKIP_TASKBAR,SKIP_PAGER`;
     the full-size **Dictation** window (the voice-input overlay host, created
     ABOVE and kept mapped by the app, so minimize doesn't stick) is
     `xdotool windowunmap`-ed — withdrawn from the WM entirely; other big
     helpers (splash) are minimized. Result: exactly one Vibe window in
     alt-tab/overview/on screen.
   - snaps near-fullscreen windows to (1920,29,1928x1023)
3. `vibe-edge-fix --watch` daemon (200 ms poll over the whole window tree,
   depth 3) darkens every `steam_app_0` window's background/border and paints
   its 8 px edge strips dark.

## 4. The white-bar saga (root-caused)

Symptom: 4 px white bar on the right (and bottom) edge of the window whenever
its edge is on-screen — worst when maximized (exactly monitor-sized).

- Layer 1 (fixed): wine draws the WS_THICKFRAME resize bevel inside frameless
  windows using system colors. Measured pixels [245,255,166,106] matched
  `ButtonFace/ButtonHilight/ButtonShadow/ButtonDkShadow` in
  `HKCU\Control Panel\Colors` exactly. Fix: set the whole palette dark in the
  prefix (via GE's `files/bin/wine reg add ...`; verify with `reg query` —
  `user.reg` on disk lags because wine caches in the live wineserver).
- Layer 2 (the real one): Chromium reserves a 4 px resize frame it does not paint;
  XWayland composites that uncovered edge from the X window's **background pixel**,
  which wine sets to WhitePixel at creation (Chromium's window class has
  hbrBackground=NULL). NOT reachable via registry colors, wine border metrics
  (wine clamps SM_CXSIZEFRAME >= 1), or Chromium's `--default-background-color`
  flag (all tested). Worse: full-size helper windows (the "Dictation" window,
  1920x1019 flush at the monitor's right edge) peek out from behind the main
  window with their white edge. Fix (`vibe-edge-fix`, C/Xlib, recursive tree walk,
  200 ms poll): on every `steam_app_0` window set background-pixmap None +
  background/border pixel dark (so future exposes repaint dark) AND directly
  `XFillRectangle` the 8 px edge strips dark — changing the bg of a viewable
  window does not repaint it by itself, and `XClearArea`+expose makes Chromium
  repaint the frame white again (measured), so we paint over the strips instead.
- The app also saves poisoned window bounds (`mainWindowBounds: {x:-4,...}`,
  the Windows DWM off-screen-border trick) in
  `Roaming/le-chat-desktop/config.json`; mutter draws the overhang literally.
  Watcher snaps geometry; config was also corrected to `{x:4,y:0,w:1920,h:1019}`.

Verified: 0 pure-white pixels on right/left/bottom edges in normal, maximized,
toggle-churn, and close→relaunch states (window recreated dark within 200 ms).

## 5. Other fixed bugs

- Focus-stealing loop: watcher compared window ids as hex strings
  (`0x5800008` vs wmctrl's padded `0x05800008`) → never matched → re-activated
  every 2 s. Now numeric compare (`strtonum`).
- "Relaunch does nothing": close-to-tray destroys the X window and the finder
  skipped untitled windows; fixed (size-based finder, launch-again-when-windowless
  path, watcher maps unmapped windows).
- Stale duplicate watcher loops from repeated launches: single loop via
  `flock -n 9>/tmp/vibe-desktop-watcher.lock`.
- Ghost processes from the (deleted) binary-swap experiment running for hours:
  killed.
- Dark file dialogs (the "ugly file system UI"): full dark
  `HKCU\Control Panel\Colors` palette (light text `225 225 230`, dark scrollbar
  `48 48 54`, muted title bars, etc.). Wine ships no .msstyles here, so icons/
  toolbar remain wine-era — that's the ceiling without third-party themes.

## 6. Dead ends (do not retry)

- **Electron binary swap** (run the app's resources on native Linux Electron):
  app main bundle is bytenode-compiled V8 bytecode (27 `.jsc` + loader). All 16
  cache header bytes match Linux Electron 45.2.1, yet `cachedDataRejected=true`,
  and a locally produced cache for the identical source differs in size
  (5248 vs 4400 bytes) — Windows/Linux V8 builds serialize incompatible code
  caches at payload level (embedded snapshot divergence). No source fallback
  shipped. Hard blocker.
- **WinBoat**: Podman + KVM Windows VM + per-app RDP — heavier than Proton,
  wrong tool for a ~0.5 GiB Electron app on 16 GB. Raven: pre-alpha.
- proton-cachyos-slr: permanently blank window on this stack (see table).

## 7. Verification tooling (hard-won)

- Window paint check: `import -window <wid> $HOME/...png` then
  `identify -format '%k'` (unique colors; 1 = blank). Only into existing dirs;
  dead ids hang/error — resolve the id and capture atomically.
- Find the live app window: `xdotool search --class steam_app_0`, skip
  tiny helpers (w<200 or h<150), pick largest or the titled one. Chromium
  destroys/recreates the top-level window on close and fullscreen toggles —
  X ids churn constantly.
- Ground truth of what the user sees: GNOME PrintScreen →
  `~/Pictures/Screenshots/*.png` (compositor view; can differ from the X pixmap
  for GPU-presented windows).
- `pgrep -f`/`pkill -f` self-match trap (bit me twice): use bracket patterns
  like `'Vibe\.exe'`… `'note[p]ad'`.
- Never `wineserver -k` while the app should stay up; use it for full resets.
- Registry edits: use GE's wine directly
  (`".../Proton-GE Latest/files/bin/wine" reg add ...` with WINEPREFIX set) —
  seconds per call, no umu runtime spin-up.

## 9. Boot time: why it's slow (measured)

Cold-launch phases, measured by polling every 0.5s from launcher start
(two runs, consistent):

| phase | time |
|---|---|
| umu/pressure-vessel + wineserver + Vibe.exe spawn | ~0.5 s |
| first X window created (steam_app_0) | ~2.0 s |
| first window MAPPED + painted | ~14 s |

So the ~12 s gap between "X window exists" and "window shown" is the app's own
init, and it is **CPU-bound, not network-bound**: sampling during boot shows the
Vibe processes at 200-400% CPU continuously from t=4s to t=13s. That is the
Electron main process loading the 302 MB `app.asar` + bytenode `.jsc` modules
and running its effect-runtime init under wine; the asar read itself is fast
(0.3 s warm page cache), so it's parse/interpret/JIT work on the emulated stack.
run.log also shows per-boot noise that is NOT the bottleneck but adds logging
I/O: repeated `WSALookupServiceBegin failed with: 8` (Chromium network-change
notifier under wine), a `desktop_secret_store_failed` safeStorage decrypt
fallback (no keyring in the prefix), and a 5 s `TimeoutError` in the
transfer-rule chunk.

Implications / mitigations (implemented):
- The expensive part is one-time per cold start; once running, the launcher's
  already-running path shows the window in well under a second. So keep the app
  alive (close-to-tray) instead of quitting it.
- Autostart at login (XDG .desktop in ~/.config/autostart) so the ~14 s cold
  boot happens during login, not when the user clicks the icon.
- `WINEDEBUG=-all` and `nice -n -5` in the launcher cut logging overhead and
  give the CPU-bound init priority.

## 8. Remaining caveats

- Auto-update can't self-apply (would re-run the NSIS installer under wine,
  which fails). Update = download new setup.exe in Firefox, re-extract
  `app-64.7z` over `Programs/vibe`.
- Local-session stack = Windows helper binaries under Proton
  (agent-browser.exe, rg.exe, key-server.exe, windows-files.node) — untested;
  remote/web sessions work (verified: signed in, sessions listed).
- Close button hides to tray (app behavior; its tray icon is not a standard
  SNI, so relaunch goes through the launcher/dock icon, which now re-shows the
  window).
- One transient frozen-splash launch seen in ~5; relaunch clears it.
- Uninstall: `rm -rf` the WINEPREFIX + launcher + vibe-edge-fix* + .desktop +
  icons. The original installer stays in ~/Downloads.
