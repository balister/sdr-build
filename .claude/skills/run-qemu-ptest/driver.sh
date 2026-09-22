#!/bin/bash
# Driver for booting a bitbake-built qemu*.rootfs image and driving it over SSH.
# See ../SKILL.md for the documented, verified usage.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
TMUX_SESSION="oe-qemu"
SSH_PORT=2222
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ConnectTimeout=5 -p "$SSH_PORT")
CONSOLE_LOG="$BUILD_DIR/tmp/qemu-driver-console.log"

ssh_cmd() { sshpass -p '' ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }

cmd_boot() {
    local machine="${1:-qemuarm64}" image="${2:-gnuradio4-ptest-image}"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
    mkdir -p "$(dirname "$CONSOLE_LOG")"
    (
        cd "$BUILD_DIR" || exit 1
        # oe-init-build-env is a no-op re-source if already done; harmless either way.
        if ! command -v runqemu >/dev/null 2>&1; then
            source "$REPO_ROOT/openembedded-core/oe-init-build-env" "$BUILD_DIR" "$REPO_ROOT/bitbake" >/dev/null
        fi
        export MACHINE="$machine"
        tmux new-session -d -s "$TMUX_SESSION" -x 220 -y 50 \
            "runqemu $machine $image nographic slirp snapshot qemuparams='-m 2048' 2>&1 | tee '$CONSOLE_LOG'"
    )
    echo "Booting $image for MACHINE=$machine in tmux session '$TMUX_SESSION' (console: $CONSOLE_LOG)"
}

cmd_wait_ssh() {
    local timeout="${1:-90}" waited=0
    until (echo >"/dev/tcp/127.0.0.1/$SSH_PORT") 2>/dev/null; do
        sleep 2; waited=$((waited + 2))
        [ "$waited" -ge "$timeout" ] && { echo "TIMED OUT waiting for SSH port $SSH_PORT" >&2; return 1; }
    done
    # Port can accept TCP slightly before sshd is ready to authenticate; retry the login itself.
    local i
    for i in $(seq 1 15); do
        ssh_cmd true 2>/dev/null && { echo "SSH ready on 127.0.0.1:$SSH_PORT"; return 0; }
        sleep 3
    done
    echo "TIMED OUT waiting for SSH login" >&2
    return 1
}

cmd_exec() {
    ssh_cmd "$@"
}

cmd_ptest() {
    # Default package list matches this repo's gnuradio4-ptest-image contents.
    local pkgs=("$@")
    [ ${#pkgs[@]} -eq 0 ] && pkgs=(gnuradio4-core gnuradio4-library gnuradio4-blocks gnuradio4-control-plane)
    ssh_cmd "ptest-runner ${pkgs[*]}"
}

cmd_stop() {
    ssh_cmd poweroff 2>/dev/null
    local i
    for i in $(seq 1 15); do
        tmux has-session -t "$TMUX_SESSION" 2>/dev/null || { echo "VM stopped"; return 0; }
        sleep 2
    done
    echo "VM didn't shut down cleanly, killing tmux session" >&2
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
}

case "${1:-}" in
    boot)     shift; cmd_boot "$@" ;;
    wait-ssh) shift; cmd_wait_ssh "$@" ;;
    exec)     shift; cmd_exec "$@" ;;
    ptest)    shift; cmd_ptest "$@" ;;
    stop)     shift; cmd_stop "$@" ;;
    *)
        echo "Usage: $0 {boot [MACHINE] [IMAGE] | wait-ssh [TIMEOUT_S] | exec <cmd...> | ptest [pkg...] | stop}" >&2
        exit 1
        ;;
esac
