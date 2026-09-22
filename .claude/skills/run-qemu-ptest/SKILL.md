---
name: run-qemu-ptest
description: Boot a bitbake-built qemu image (default gnuradio4-ptest-image on MACHINE=qemuarm64) under QEMU and drive it over SSH — run ptest-runner, run arbitrary commands, take console output, shut it down. Use when asked to run/boot/test the ptest image in qemu, run ptests on target, or verify a recipe change actually boots and passes its tests.
---

This is a Yocto/OpenEmbedded build tree (submodules: bitbake, openembedded-core,
meta-openembedded, meta-sdr, meta-qt5; build output in `build/`, gitignored). The
driven artifact is a `bitbake`-built qemu image already sitting in
`build/tmp/deploy/images/<machine>/`. Drive it via
`.claude/skills/run-qemu-ptest/driver.sh` — it boots the image in a detached tmux
session (serial console redirected to a log, not interactive) and gives you SSH
(via QEMU's slirp hostfwd on `127.0.0.1:2222`) as the actual command channel. Don't
scrape the tmux pane for command output — that was tried first and the pane
echoes queued keystrokes before they execute, producing false "done" matches
(see Gotchas). SSH is the reliable path.

All paths below are relative to the repo root (this file's directory is
`.claude/skills/run-qemu-ptest/`).

## Prerequisites

`sshpass` and `tmux`. Already present in this container; if missing:

```bash
sudo dnf install -y sshpass tmux      # Fedora (this container)
sudo apt-get install -y sshpass tmux  # Debian/Ubuntu
```

## Build (produces the image the driver boots)

The OE build environment must be sourced first — from the repo root:

```bash
source ./openembedded-core/oe-init-build-env ./build ./bitbake
export MACHINE=qemuarm64
bitbake gnuradio4-ptest-image
```

This drops `gnuradio4-ptest-image-qemuarm64.rootfs.ext4.zst` (+ `.qemuboot.conf`)
into `build/tmp/deploy/images/qemuarm64/`. The driver's `boot` subcommand also
tries to source the build env itself if `runqemu` isn't already on `PATH`, so a
fresh shell works too — it just needs the image already built.

## Run (agent path)

```bash
.claude/skills/run-qemu-ptest/driver.sh boot [MACHINE] [IMAGE]   # default: qemuarm64 gnuradio4-ptest-image
.claude/skills/run-qemu-ptest/driver.sh wait-ssh [TIMEOUT_S]     # default 90s; blocks until SSH login succeeds
.claude/skills/run-qemu-ptest/driver.sh exec '<command>'         # run one command on target, prints its output
.claude/skills/run-qemu-ptest/driver.sh ptest [pkg...]            # runs ptest-runner; no args = the 4 gnuradio4-* ptest pkgs
.claude/skills/run-qemu-ptest/driver.sh stop                      # poweroff over ssh, falls back to tmux kill-session
```

Typical sequence:

```bash
.claude/skills/run-qemu-ptest/driver.sh boot
.claude/skills/run-qemu-ptest/driver.sh wait-ssh
.claude/skills/run-qemu-ptest/driver.sh ptest gnuradio4-core gnuradio4-library
.claude/skills/run-qemu-ptest/driver.sh stop
```

`exec`/`ptest` return the remote command's real exit code (ssh propagates it), so
`$?` after a driver call tells you pass/fail without parsing text.

Boot console output (kernel + systemd boot log, not command output) lands at
`build/tmp/qemu-driver-console.log` if you need to debug a boot failure.

| command | what it does |
|---|---|
| `boot [MACHINE] [IMAGE]` | Launches `runqemu MACHINE IMAGE nographic slirp snapshot` in tmux session `oe-qemu` |
| `wait-ssh [TIMEOUT_S]` | Polls port 2222, then retries login until sshd actually accepts it |
| `exec <cmd>` | `sshpass -p '' ssh -p 2222 root@127.0.0.1 '<cmd>'` — empty-password root login |
| `ptest [pkg...]` | Runs `ptest-runner` remotely with the given package list (or the image's default 4) |
| `stop` | `poweroff` over ssh; kills the tmux session as a fallback if it doesn't exit in ~30s |

## Run (human path)

```bash
cd build && runqemu qemuarm64 gnuradio4-ptest-image
```

Opens the normal graphical QEMU window with a login prompt (root, no password).
`Ctrl-A X` or close the window to quit.

## Test

`ptest gnuradio4-core gnuradio4-library gnuradio4-blocks gnuradio4-control-plane`
covers the packages in this image. Last verified run: 184 passed / 1 failed / 0
skipped (plus separate gtest suites in gnuradio4-control-plane all passing). The
one failure, `qa_thread_pool`'s "contention tests" suite in `gnuradio4-core`, is a
known-flaky timing race (asserts the thread pool's exact size immediately after
enqueueing two overlapping tasks) — reran the binary 3× standalone and got
pass/fail/pass, so a lone failure there isn't a regression signal.

## Gotchas

- **The deploy image is `.zst`-compressed** (`qb_default_fstype = ext4.zst` in
  `.qemuboot.conf`). Plain `runqemu MACHINE IMAGE` fails with `.zst images are
  only supported with snapshot mode`. The driver always passes `snapshot`.
- **Don't drive the app by scraping the tmux pane.** `tmux send-keys` followed by
  `capture-pane -p | grep -q DONE_MARKER` matched instantly on the *echoed,
  not-yet-executed* keystrokes of the queued command (local tty echo), not on
  real completion — a multi-minute `ptest-runner` run looked "done" seconds after
  being queued. SSH sidesteps this entirely: `ssh_cmd` doesn't return until the
  remote command actually exits, and its exit code is real.
- **`wait-ssh`'s two-stage wait is necessary.** The hostfwd TCP port accepts
  connections slightly before sshd is ready to authenticate; a bare "port open"
  check occasionally raced a login failure. The driver polls the port, then
  retries an actual login up to 15×.
- **BusyBox userspace on target** — `head -N` (GNU style) fails; it's `head -n N`.
  Matters if you write ad-hoc `exec` commands.
- **Empty-password root SSH needs explicit ssh options**, not just a blank
  password: `-o PreferredAuthentications=password -o PubkeyAuthentication=no`,
  piped through `sshpass -p ''`. Without forcing password auth, ssh tries
  pubkey/other methods first and never reaches the empty-password prompt.
