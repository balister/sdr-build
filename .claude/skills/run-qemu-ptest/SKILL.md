---
name: run-qemu-ptest
description: Build and boot a bitbake-built qemu ptest image (gnuradio4-ptest-image for GNU Radio 4, gnuradio-ptest-image for GNU Radio 3.x / gnuradio-ptest; MACHINE=qemuarm64) under QEMU and drive it over SSH — run ptest-runner, run arbitrary commands, take console output, shut it down. Use when asked to run/boot/test a ptest image in qemu, run gnuradio or gnuradio4 ptests on target, or verify a recipe change actually boots and passes its tests.
---

This is a Yocto/OpenEmbedded build tree (submodules: bitbake, openembedded-core,
meta-openembedded, meta-sdr, meta-qt6; build output in `build/`, gitignored). The
driven artifact is a `bitbake`-built qemu image in
`build/tmp/deploy/images/<machine>/`. Drive it via
`.claude/skills/run-qemu-ptest/driver.sh` — it builds the image, boots it in a
detached tmux session (serial console redirected to a log, not interactive) and
gives you SSH (via QEMU's slirp hostfwd on `127.0.0.1:2222`) as the actual command
channel. Don't scrape the tmux pane for command output — that was tried first and
the pane echoes queued keystrokes before they execute, producing false "done"
matches (see Gotchas). SSH is the reliable path.

All paths below are relative to the repo root (this file's directory is
`.claude/skills/run-qemu-ptest/`).

## Images

| image | ptest packages (`ptest-runner -l`) | use for |
|---|---|---|
| `gnuradio4-ptest-image` | gnuradio4-core, gnuradio4-library, gnuradio4-blocks, gnuradio4-control-plane, gnuradio4-studio-blocks | GNU Radio 4 |
| `gnuradio-ptest-image` | gnuradio | GNU Radio 3.x (`gnuradio-ptest`) |

`gnuradio-ptest-image.bb` requires `gnuradio-image.bb` and adds
`ptest-runner gnuradio-ptest`. Older meta-sdr revisions had it as a copy of the
gnuradio4 recipe (only `gnuradio4-core-ptest`, no `gnuradio-ptest`). If
`ptest-runner -l` on that image shows `gnuradio4-core` instead of `gnuradio`,
meta-sdr is stale.

## Prerequisites

`sshpass` and `tmux`. Already present in this container; if missing:

```bash
sudo dnf install -y sshpass tmux      # Fedora (this container)
sudo apt-get install -y sshpass tmux  # Debian/Ubuntu
```

## Build

```bash
.claude/skills/run-qemu-ptest/driver.sh build [MACHINE] [IMAGE...]   # default: qemuarm64 gnuradio4-ptest-image
.claude/skills/run-qemu-ptest/driver.sh build qemuarm64 gnuradio-ptest-image gnuradio4-ptest-image
```

`build` exports `MACHINE`, sources the OE env and runs bitbake. A full rebuild
after a submodule bump takes hours; run it in the background. Manual equivalent:

```bash
export MACHINE=qemuarm64          # must be in the env -- see Gotchas
source ./openembedded-core/oe-init-build-env ./build ./bitbake
bitbake gnuradio-ptest-image
```

## Run (agent path)

```bash
.claude/skills/run-qemu-ptest/driver.sh boot [MACHINE] [IMAGE]   # default: qemuarm64 gnuradio4-ptest-image
.claude/skills/run-qemu-ptest/driver.sh wait-ssh [TIMEOUT_S]     # default 90s; blocks until SSH works AND guest arch matches MACHINE
.claude/skills/run-qemu-ptest/driver.sh exec '<command>'         # run one command on target, prints its output
.claude/skills/run-qemu-ptest/driver.sh ptest [pkg...]            # ptest-runner; no args = every ptest installed in the image
.claude/skills/run-qemu-ptest/driver.sh stop                      # poweroff over ssh, falls back to tmux kill-session
```

Typical sequence, GNU Radio 4 (the defaults):

```bash
.claude/skills/run-qemu-ptest/driver.sh boot                         # qemuarm64 gnuradio4-ptest-image
.claude/skills/run-qemu-ptest/driver.sh wait-ssh 400
.claude/skills/run-qemu-ptest/driver.sh ptest > gr4.log 2>&1         # all 5 gnuradio4-* pkgs, ~15 min; run in background
.claude/skills/run-qemu-ptest/driver.sh stop
```

Typical sequence, GNU Radio 3.x:

```bash
.claude/skills/run-qemu-ptest/driver.sh boot qemuarm64 gnuradio-ptest-image
.claude/skills/run-qemu-ptest/driver.sh wait-ssh 400
.claude/skills/run-qemu-ptest/driver.sh ptest gnuradio > gr.log 2>&1   # ~16 min under TCG; run in background
.claude/skills/run-qemu-ptest/driver.sh stop
```

Run a single gnuradio4 test binary (e.g. to recheck a flaky one) — each package's
tests live under `/usr/lib/<pkg>/ptest/`, e.g.
`/usr/lib/gnuradio4-core/ptest/core/test/qa_thread_pool`:

```bash
.claude/skills/run-qemu-ptest/driver.sh exec 'cd /usr/lib/gnuradio4-core/ptest/core/test && ./qa_thread_pool; echo rc=$?'
```

`exec`/`ptest` return the remote command's real exit code (ssh propagates it), so
`$?` after a driver call tells you pass/fail without parsing text. Summarize a log
per package with:

```bash
awk '/^BEGIN/{p=$2} /^(PASS|FAIL|SKIP)/{c[p" "$1]++} END{for(k in c)print k, c[k]}' gr.log | sort
```

Boot console output (kernel + systemd boot log, not command output) lands at
`build/tmp/qemu-driver-console.log` if you need to debug a boot failure.

| command | what it does |
|---|---|
| `build [MACHINE] [IMAGE...]` | `MACHINE=... bitbake IMAGE...` |
| `boot [MACHINE] [IMAGE]` | `runqemu <deploy>/<MACHINE>/<IMAGE>-<MACHINE>.rootfs.qemuboot.conf nographic slirp snapshot` in tmux session `oe-qemu`; records MACHINE for `wait-ssh` |
| `wait-ssh [TIMEOUT_S]` | Polls port 2222, retries login until sshd accepts it, then fails (rc 2) if `uname -m` doesn't match the booted MACHINE |
| `exec <cmd>` | `sshpass -p '' ssh -p 2222 root@127.0.0.1 '<cmd>'` — empty-password root login |
| `ptest [pkg...]` | Runs `ptest-runner` remotely with the given package list (or all) |
| `stop` | `poweroff` over ssh; kills the tmux session as a fallback if it doesn't exit in ~30s |

Boot to SSH takes ~1–2 min on qemuarm64 (TCG, no KVM) — use `wait-ssh 400`.

## Run (human path)

```bash
export MACHINE=qemuarm64
cd build && runqemu tmp/deploy/images/qemuarm64/gnuradio4-ptest-image-qemuarm64.rootfs.qemuboot.conf snapshot
```

Opens the normal graphical QEMU window with a login prompt (root, no password).
`Ctrl-A X` or close the window to quit.

## Test — last verified results (qemuarm64, 2026-10-13)

| image | package | result | runtime |
|---|---|---|---|
| gnuradio-ptest-image | gnuradio | 255 pass, 0 fail | ~16 min (956–992 s) |
| gnuradio4-ptest-image | gnuradio4-core | 44 pass, or 43 + 1 `qa_thread_pool` flake | ~80 s |
| gnuradio4-ptest-image | gnuradio4-library | 55 pass | ~200 s |
| gnuradio4-ptest-image | gnuradio4-blocks | 92 pass | ~460 s |
| gnuradio4-ptest-image | gnuradio4-control-plane | 4 pass (its gtest suites: 1 + 66 + 93 + 7 `[  PASSED  ]`) | ~165 s |
| gnuradio4-ptest-image | gnuradio4-studio-blocks | 5 pass | ~2 s |

gnuradio4-ptest-image total: ~15 min, `TOTAL: 5 FAIL: 0` or `FAIL: 1` (the flake
below). `ptest` exits 1 whenever any package fails, so on a nonzero exit check
*which* test failed before calling it a regression.

Known noise, not regressions:

- `qa_thread_pool` "contention tests" in `gnuradio4-core`
  (`FAILED in: .../qa_thread_pool.cpp:68 - test condition: [false]`) is a
  known-flaky timing race (asserts the thread pool's exact size right after
  enqueueing two overlapping tasks); worse under TCG. On 2026-10-13 it failed in
  2 of 3 full `gnuradio4-core` runs and 1 of 5 standalone reruns. A lone failure
  there isn't a regression signal; rerun the binary standalone (above) a few
  times to confirm.
- `gnuradio4-core`'s `qa_buffer` prints `CircularBuffer.hpp ... Assertion ...
  failed` lines — those are expected death tests; the test itself PASSes.
- `gnuradio` logs include `vmcircbuf ... failed to open` / `Doesn't work` for the
  createfilemapping factory and `wavfile_sink :error: sf_open(1) failed:
  no_file.wav` — expected; the sysv_shm factory is used and those tests PASS.

## Gotchas

- **MACHINE must be exported in the shell, not set in a `bitbake -R` postfile.**
  local.conf has `MACHINE ??= "qemux86-64"`. `bitbake.conf` includes
  `conf/machine/${MACHINE}.conf` before postfiles are parsed, so `MACHINE =
  "qemuarm64"` in a `-R` file builds x86-64 binaries (bzImage, core2 rootfs)
  but deploys them under `deploy/images/qemuarm64/*-qemuarm64.*`. runqemu then
  launches `qemu-system-x86_64` and everything *looks* fine over SSH. This
  happened on 2026-10-13; stray x86 artifacts (e.g. `bzImage`) may still sit
  in the qemuarm64 deploy dir — harmless, since the qemuboot.conf names the
  right kernel. `wait-ssh`'s arch check exists to catch this.
- **`runqemu MACHINE IMAGE` can boot the wrong machine** (it re-resolves MACHINE
  via `bitbake -e`, which falls back to local.conf's qemux86-64). `boot` passes
  the qemuboot.conf path instead.
- **`oe-init-build-env` fails under `set -u`** (`BBSERVER: unbound variable`);
  the driver wraps it in `set +u`.
- **The deploy image is `.zst`-compressed** (`qb_default_fstype = ext4.zst`).
  runqemu without `snapshot` fails with `.zst images are only supported with
  snapshot mode`. The driver always passes `snapshot`.
- **`:append` values need a leading space.** The old `gnuradio-ptest-image.bb`
  had `CORE_IMAGE_EXTRA_INSTALL:append = "ptest-runner ..."`, which glued onto
  whatever came before (`Nothing RPROVIDES 'gnuradio-ptestptest-runner'`).
- **Don't drive the app by scraping the tmux pane.** `tmux send-keys` followed by
  `capture-pane -p | grep -q DONE_MARKER` matched instantly on the *echoed,
  not-yet-executed* keystrokes of the queued command (local tty echo), not on
  real completion. SSH sidesteps this: `ssh_cmd` doesn't return until the
  remote command actually exits, and its exit code is real.
- **`wait-ssh`'s two-stage wait is necessary.** The hostfwd TCP port accepts
  connections slightly before sshd is ready to authenticate.
- **BusyBox userspace on target** — `head -N` (GNU style) fails; it's `head -n N`.
- **Empty-password root SSH needs explicit ssh options**, not just a blank
  password: `-o PreferredAuthentications=password -o PubkeyAuthentication=no`,
  piped through `sshpass -p ''`.
