# Change log

Every change made while getting the official **Windows** build of Mistral Vibe
Desktop (1.1.0) running on Linux under GE-Proton, in the order it was found.
Newest first. Details and measurements live in `README.md` (§ numbers below).

Reference machine: GNOME **Wayland** session with XWayland, Intel Iris Xe,
2x1920x1080, GE-Proton10-32 via `umu-run`, dedicated prefix
`~/.local/share/wineprefixes/vibe-desktop`.

---

## (pending) - Git for Windows installed inside the prefix (the app had no git)

User request: "install git in this proton". The app's coding features call
`git`, and wine's `CreateProcess` only starts PE binaries, so the Linux git on
the host `PATH` is unreachable from the app — the prefix needs its own.

- Payload: `PortableGit-2.56.1-64-bit.7z.exe` (60,125,512 bytes, sha256
  `9dd04a608ceb5f6ab32a73709e0ecb159d211da71b697c45ff81f6dd0c6b49c7`, matching
  the release notes) extracted with 7z — the installer route fails under wine,
  same as the app's own NSIS installer (§1). 9622 files, 412 MB at
  `C:\Program Files\Git`. 2.56.x matches the host git 2.56.0, so both sides
  read the same repository format.
- PATH: appended `C:\Program Files\Git\cmd` to the prefix's system
  `Environment\Path` (`cmd` only — `usr\bin` ships `bash.exe`, `sort.exe`,
  `find.exe`, `link.exe` and would shadow wine's system32 tools). Verified from
  a fresh wine process: `where git` → `C:\Program Files\Git\cmd\git.exe`,
  `git --version` → `git version 2.56.1.windows.1`. A `wine reg` call from the
  host attaches to the app's live wineserver (process count stayed at 1), so
  the write lands in the running hive and flushes on app exit — no clobber risk.
  The **running** app still needs a relaunch: `PATH` is built at process start.
- Two defaults had to be overridden:
  - `core.autocrlf = true` (portable default) would rewrite LF files in the
    Linux repos this app edits → set to `false` in `etc/gitconfig`.
  - Wine's `Z:` stat reports every file as `100644`, so repos whose index
    records `100755` showed phantom modifications with **0-line diffs**:
    `git diff --raw install.sh` → `:100755 100644 9e2ba7d 0000000 M install.sh`
    (same for `vibe-desktop-launcher.sh`, `tools/test-dock-restore.sh`). The
    launcher now exports `GIT_CONFIG_COUNT=1` /
    `GIT_CONFIG_KEY_0=core.filemode` / `GIT_CONFIG_VALUE_0=false`; that has
    command scope, so it beats the repo's own `core.filemode = true` (verified:
    `status --porcelain` empty, `config --get core.filemode` → `false`).
- Verified working: `init`, `add`, `commit`, `log`, `status`, `rev-parse`,
  `diff` on `Z:` paths, and `git ls-remote https://github.com/...` over HTTPS
  with the bundled CA (wine prints harmless `no Kerberos/NTLM support` lines).
- `install.sh` does all of it now — pinned version + sha256, download, 7z
  extract, PATH entry, autocrlf patch — and is idempotent (re-runs skip the
  payload). README §12.

## 33df8fb - Typing latency in the input box: the app was living in zram, in someone else's cgroup

User report: "there's a bit of latency when typing into the input box." Not an
Electron problem - a cgroup inheritance problem.

- The launcher never created a cgroup, so the app joined whatever scope the
  launching terminal was in. Launched from a Zed terminal that was Zed's
  transient scope: `MemoryHigh=2G`, `MemoryMin=0`, no `CPUWeight`. The scope sat
  at 2.09 GB charged with **29 MB "available"**, so the kernel parked the rest in
  zram: scope `memory.swap.current` **4.15 GB**, and per process - UI renderer
  (`CrRendererMain`) **36 MB resident / 672 MB swapped**, browser 226/690, GPU
  270/370, second renderer 187/657, `vibe-app-server` 164/124.
- Mechanism: the renderer main thread paid **synchronous zram decompression on
  every keystroke**. Same failure class as the shell/MemoryMin and game-scope
  MemoryMin fixes on this machine: a `MemoryHigh` with no floor means the hot set
  is the first thing swapped.
- Four launcher changes: own scope
  (`systemd-run --user --scope --collect --unit=vibe-desktop-app
  -p MemoryMin=2G -p MemoryHigh=8G -p CPUWeight=500`), `XMODIFIERS=` (empty - no
  XIM round trip to ibus-x11 before wine sees the key), `PROTON_USE_XALIA=0`
  (Proton only sets it when absent, so `=0` is honoured) and
  `DXVK_CONFIG=dxgi.maxFrameLatency=1` (DXVK 2.7.1 >= 2.4).
- Found on the way, all measured: `xalia.exe` (Proton's UIA bridge) burned
  **89.5 % of a whole core** for the app's entire lifetime - 20:19 CPU seconds
  over 1382 s - and does nothing for an Electron UI; the UI renderer had been
  reclassified to nice **+5** by ananicy-cpp; load average 13.04.
- `vibe-edge-fix` rewrite: removing its `popen("pgrep -f Vibe.exe")` (5 forks/s)
  made it **worse** - 16.3 % vs 12.9 % of a core - which located the real cost:
  a full tree walk per poll over **5076 top-level windows**, one `XGetClassHint`
  round trip each. Now a cached 29-window set fed by `CreateNotify`/`MapNotify`
  on the root, `/proc` check every 5 s (three misses to exit: the
  umu-run -> proton -> wine hand-off makes a single miss normal), full rescan
  every 5 min as a safety net: **0.2 % of a core**, edge strips unchanged.
- Verified live after a relaunch: `memory.min` = 2147483648 enforced,
  `memory.swap.current` 364 KB (was 4.15 GB), every app process 0 MB swap,
  renderers back to 696 MB / 848 MB resident, main 902 MB, GPU 839 MB, `xalia`
  absent, `XMODIFIERS=` in `/proc/<Vibe.exe>/environ`, load average 2.86.
- Honest gap: no end-to-end keystroke number exists for this machine. XTEST is
  inert here (Xwayland `-enable-ei-portal`), `XSendEvent` is ignored by wine,
  GNOME refuses `windowactivate`, kernel-level `ydotool` input does nothing. The
  user's fingers are the instrument; the swap figures are the evidence.
- Trap for next time: cgroup memory charges do **not** migrate with processes, so
  moving the running pids into a new scope leaves `memory.current` near zero and
  the pages still charged to the old one. Only a relaunch fixes the charge. Also:
  the launcher's "already running?" test is `pgrep -f 'Vibe.exe'`, which a dying
  wine process still matches - relaunching too early takes the closed-to-tray
  path and exits silently with no window.

## 8a8d8f0 - Dock icon reopens the running app instead of restarting it

The bug the whole tray/close saga ended on: "closing the app minimizes it to
tray; clicking the dashboard/dock icon restarts it instead of bringing it back."

- Root cause was a **bad test, not app behaviour**: an earlier conclusion that
  close destroys the X window came from `xdotool windowclose`, which is
  `XDestroyWindow` (fakes destruction - `BadWindow` afterwards). A real WM
  close (`wmctrl -i -c` = what the titlebar X does) only makes the app call
  `hide()`: the X window survives **unmapped**, geometry and title intact, the
  process set stays up (~10 procs).
- New restore path in the launcher: when the app runs with no managed window,
  launch a **second instance** - Electron's single-instance lock hands off to
  the primary, whose `second-instance` handler shows the existing window.
  Measured: dock click returns in **3.3 s**, window mapped at **2.2 s**, same
  window id, no restart, no state loss. Kill + cold boot (~15 s) is now only a
  fallback (no window after 8 s) and the only path that notifies.
- Documented trap: `xdotool windowmap <hidden-id>` looks better (~0.3 s) but the
  map is out of band - Chromium's visibility flag stays false, the app's next
  close becomes a no-op and close-to-tray silently dies until restart
  (verified: `WM_DELETE_WINDOW` delivered and ignored; unmap/remap does not
  heal it). Synthetic tray clicks are not available either: wine ignores
  `XSendEvent`/`xdotool click --window`, Wayland ignores pointer warps.
- Boot guard: click during a cold start (app age < 30 s) is a deliberate no-op,
  so double-clicking the icon can never kill a booting app (the previous code
  could).
- `tools/test-dock-restore.sh` added (asserts: click activates in place, real
  close -> click restores the same window, close still hides afterwards);
  replaces the stale `tools/test-tray-restore.sh`. README §9, §10, §11 updated.

## 8d58fc8 - Use the app's own tray icon; make close-to-tray sticky

- Dropped the hand-written `vibe-tray.py` SNI daemon (deleted from the repo, from
  `~/.local/bin` and from `~/.config/autostart`). It duplicated the app's own
  tray icon and freezes/restarts were reported from it.
- The app's own icon is a **wine/explorer systray icon** (14x14 X window,
  class `steam_app_0`, `_XEMBED_INFO`, docked in the top bar). It never shows up
  in `RegisteredStatusNotifierItems`, which is why an SNI daemon was the wrong
  answer. `install.sh` sets `showTrayIconEnabled: true` in the app config.
- Fixed "minimizes then comes back to fullscreen": the watcher no longer
  shows/activates/un-minimizes the main window. Verified the window stays
  hidden after close.

## c0658ac - Notification feedback + close-vs-minimize documentation

- `notify-send "Restoring window (cold start ~15s)..."` on the (then) only
  cold-start restore path, so a slow restore was never silent.
- README: documented what close actually does vs what minimize does
  (withdrawn/unmapped, not iconified).

## 2a0b85f - Repo title

- Titled the project `mistral-vibe-desktop-windows-to-linux-compat` (the Windows
  build, made to work on Linux); local checkout stays `~/Development/vibe-desktop-linux`.

## 8e2b37c - Pre-publication pass

- `install.sh` (one-shot: extract `app-64.7z` into the prefix, install scripts,
  compile edge-fix, install .desktop + autostart entries).
- `mistral-vibe-desktop.desktop`, `autostart-mistral-vibe-desktop.desktop`,
  MIT `LICENSE` for the scripts/docs, `tools/` harness, complete caveat list
  (README §11), secret scan of the whole tree.

## 34ee207 - Clickable GNOME tray icon (later removed, see 8d58fc8)

- Custom `vibe-tray.py` StatusNotifierItem so "close to tray" had something
  clickable. Superseded by the app's own icon.

## 364d49c + 5b53d97 - Boot time: measured, then mitigated

- Measured cold start: first X window at ~2 s, window mapped and painted at
  ~14 s; the ~12 s gap is CPU-bound app init (Electron loading the 302 MB
  `app.asar` + bytenode `.jsc`, main ~300 %, renderer ~150 %, utility ~80 %,
  gpu ~70 % CPU). `WINEDEBUG=-all` + `nice -n -5` do **not** help (16-17 s
  before and after).
- Mitigations: XDG autostart so the boot is paid at login; `WINEDEBUG=-all` and
  `nice -n -5` kept in the launcher anyway (log I/O, priority).

## b4017ac + 03412d0 + 40a4560 - "There are 2 (then 3) windows"

- Helper windows (`Input`, `Default IME`, the splash that becomes `Dictation`,
  5x5 stubs, the 166x45 popups) were being counted as app windows.
- Fix: the main window is the largest **managed** `steam_app_0` window whose
  title is not a helper name; the id is persisted in `/tmp/vibe-desktop-main.wid`
  and only switched when a non-helper candidate is >20 % larger (splash -> chat).
- Idle helpers are withdrawn with `windowunmap` (so they leave alt-tab/overview
  too) unless focused - a focused popup or the Dictation overlay is never
  touched. Net result: exactly one window (plus the app's own tray icon).

## 98ddd0c + 8f060d6 - Dictation overlay

- The Dictation window is the `le-chat-desktop` splash window, ~0.4 % smaller
  than the chat window, so it is identified by title, withdrawn while idle and
  left alone while focused. Dictation works with the overlay hidden.

## 1d408dc - White edge bars, second pass

- `vibe-edge-fix`: instead of only setting the window background pixel, fill 8 px
  edge strips with `XFillRectangle` every 200 ms, walking 3 levels deep. Verified
  0 white pixels on all four sides (right/bottom bars were the Electron 4 px
  resize frame; wine sets `WhitePixel` at creation because Chromium's class
  brush is NULL, so registry colours/metrics cannot reach it).

## 9dd3716 - Cold-launch race

- The watcher and the edge-fix daemon died instantly on a fresh launch (they
  checked for `Vibe.exe` at t=0, before wine had spawned it). The watcher now
  waits up to 180 s for the process, under a `flock` so only one loop runs.

## c6a9196 - Initial documentation of the install

- Why GE-Proton (wine-staging 11.19 paints only with `--disable-gpu`;
  proton-cachyos-slr never paints; GE-Proton10-32 with DXVK paints and its GPU
  process is stable), NSIS installer fails under wine so the payload is
  extracted by hand, launcher + edge-fix, and the first white-bar root cause.

---

## Current state (verified live, 2026-11-18)

- Cold launch: single window (1928x1023 at 1920,29), app's own tray icon in the
  top bar, 10 processes, no white edges on any side.
- Close -> hides to tray (window alive, unmapped). Dock icon -> same window back
  in ~3.3 s. Close again -> hides again. Repeatable.
- Boot: ~15 s cold (app init, see README §9); never paid from the dock icon.
- Known limits: the tray icon cannot be clicked programmatically (wine ignores
  synthetic input, Wayland blocks pointer warps), so the dock icon goes through
  the second-instance handoff; auto-update cannot self-apply (re-run
  `install.sh` with the new setup.exe); local (non-web) sessions use Windows
  helper binaries under Proton and are untested.
