---
name: linux-bridge
description: Load at the start of any coding session before running shell commands when the working environment is a Windows environment running under Wine/Proton on a Linux host (e.g. Vibe Desktop on Linux, a windows-on-wine dev box, or a Windows VM whose host or companion Linux VM is reachable over SSH). The Windows-side shell (Git for Windows under Wine) is severely broken - hangs on common syntax and has no real toolchain - so all shell work must go to the real Linux machine through the SSH bridge this skill sets up.
metadata:
  display-name: Linux Bridge
  short-description: SSH from the broken Wine shell to the real Linux host
---

# Linux Bridge — run all shell work on the real Linux machine

## 1. The situation

- The visible "Windows" environment is **Wine/Proton on a Linux machine** (bare metal
  host, or a Linux VM that hosts/sits beside the Windows environment).
- The shell tool you are given is Git Bash under Wine. It is broken. Measured on
  Vibe Desktop 1.1.0 + Git for Windows 2.56 under GE-Proton:
  - `$(...)` command substitution and `$?` expansions **hang** every time.
  - `mkdir`, `chmod`, `ssh-keygen` in the foreground **hang**.
  - Local pipes and writes from Git Bash to the Linux-root drive mount often **hang**.
  - There is no real toolchain inside the Windows environment (no python, node, gcc...).
- The real Linux machine (host or companion VM) has the full toolchain and is usually
  **one TCP hop away at `localhost`** — Wine shares the host's network stack, so
  `localhost` inside the Windows environment is the Linux machine itself. If the
  setup is a real VM instead, replace `localhost` with the address of the Linux
  machine (ask the user).
- Wine maps the Linux root filesystem as a drive, almost always `Z:` — in Git Bash
  that is `/z` (`/z/home`, `/z/usr`, `/z/etc`...). Verify with `mount` (lists
  `Z: on /z`).

## 2. One-time setup (skip if a working bridge already exists)

Check first: if `~/.ssh` inside Git Bash contains a bridge private key AND the
Linux side's `authorized_keys` has its pubkey, go straight to §3.

1. **Find the Linux username**: list `/z/home` (the home directories are named
   after the users). Call it `$LUSER`.
2. **Generate the keypair** from Git Bash. ssh-keygen can hang in the foreground,
   so run it through your background-process facility with stdin redirected:
   `ssh-keygen -t ed25519 -N '' -f ~/.ssh/vibe-bridge -C vibe-bridge -q </dev/null`
3. **Install the pubkey** into the Linux side: append the one line of
   `~/.ssh/vibe-bridge.pub` to `/z/home/$LUSER/.ssh/authorized_keys`. Do NOT
   write it from Git Bash (writes to the Linux-root mount hang) — use the
   harness's file tools (read the existing file, then write the merged content),
   or go through an already-working bridge.
4. **The Linux machine must run sshd and allow this key.** If connection is
   refused, either sshd is not running (needs `systemctl enable --now sshd` on
   the Linux side — ask/confirm with the user) or the address is not `localhost`
   (VM case). The key may need `authorized_keys` perms 600/`chmod` from the Linux
   side, but files created there by wine are usually fine; if auth fails
   `PasswordAuthentication`/`PubkeyAuthentication` may be disabled - read
   `/z/etc/ssh/sshd_config` for the active policy.
5. **Verify**: `ssh -i ~/.ssh/vibe-bridge -o IdentitiesOnly=yes -o BatchMode=yes
   -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $LUSER@localhost
   'uname -a'` should print a Linux kernel line.

## 3. The golden path for every shell command

Never pass commands to the login shell — the default login shell may be fish,
which rejects POSIX loops. **Stream a bash script over stdin instead.**

1. Write the remote script with the harness file tool to e.g.
   `~/lx-cmd.sh` (line endings are irrelevant, they get stripped remotely).
   End it with `echo __LX_DONE__` so completion is detectable.
2. Create this one-line helper once (single line matters: trailing ` #` absorbs
   whatever CR the file write adds; `tr -d "\r"` protects the streamed script
   from CRLF — remote bash chokes on `\r`):

   `exec ssh -T -i ~/.ssh/vibe-bridge -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $LUSER@localhost 'tr -d "\r" | /bin/bash -s' < "$1" #`

   Save as `~/lx.sh` (if the harness writes CRLF into it, being one line is what
   makes it survive). `timeout -k 2 N` in front makes runaway calls reapable.
3. Run it as a **background process** — ssh hangs at exit under Wine, so a
   foreground call may never return. Poll the output buffer until
   `__LX_DONE__` appears, then stop/reap the process:

```ts
const p = await tools.process.start({ command: "timeout -k 2 600 bash ~/lx.sh ~/lx-cmd.sh" });
let r: any = {};
for (let i = 0; i < 30; i++) {
  r = await tools.process.output({ processId: p.processId, from: "start", waitMs: 25000, maxBytes: 30000 });
  if (r.output.includes("__LX_DONE__") || r.status !== "running") break;
}
await tools.process.stop({ processId: p.processId }).catch(() => null);
```

(Adjust the timeout to the job; round trip is typically 1-3 s.)

## 4. Files, long jobs, servers

- **Reading Linux files**: harness file reads on the Linux-root drive paths
  (`Z:\...` / `/z/...`) work and are hang-proof — often faster than a bridge call.
- **Writing Linux files**: harness file writes on the Linux-root drive work
  (correct user ownership, mode ~0644). New files may get CRLF — strip `\r`
  remotely (`tr -d '\r'`) for anything parsed by Linux tools.
- **Long builds**: don't hold a call open for many minutes — start the job with
  `nohup job.sh > job.log 2>&1 &` in one bridge call, then poll `job.log` with
  harness file reads between turns.
- **Dev servers / long-lived processes**: start the ssh command itself as a
  background process WITHOUT `timeout`, e.g.
  `ssh -i ~/.ssh/vibe-bridge $LUSER@localhost 'cd /path && exec npm run dev'`,
  stream output as it arrives, kill with the process-stop call.

## 5. Do NOT (verified broken under Wine/Git-Bash)

- No `$(...)` / `$?` in Git-Bash commands; no foreground `mkdir`/`chmod`/`ssh-keygen`;
  no pipes for anything important; no foreground ssh (exit-hang); no SSH
  ControlMaster / `-M -S` ("muxclient: master hello exchange failed" — the AF_UNIX
  socket emulation is broken); no `start /unix` (hangs).

## 6. Undo

Remove the `vibe-bridge` line from the Linux side's `authorized_keys` and delete
`~/.ssh/vibe-bridge*` inside the Windows environment.
