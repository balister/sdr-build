#!/bin/bash
# Driver for booting a bitbake-built qemu*.rootfs image and driving it over SSH.
# See ../SKILL.md for the documented, verified usage.
set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
TMUX_SESSION="oe-qemu"
SSH_PORT=2222
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o ConnectTimeout=5 -p "$SSH_PORT")
CONSOLE_LOG="$BUILD_DIR/tmp/qemu-driver-console.log"
MACHINE_FILE="$BUILD_DIR/tmp/qemu-driver-machine"

ssh_cmd() { sshpass -p '' ssh "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }

# MACHINE must come from the environment: local.conf only has a ??= default, and
# setting it in a bitbake -R postfile is too late (machine conf is already included).
oe_env() {
    export MACHINE="$1"
    cd "$REPO_ROOT" || exit 1
    set +u   # oe-init-build-env references unset vars (BBSERVER)
    source ./openembedded-core/oe-init-build-env ./build ./bitbake >/dev/null
    set -u
}

expected_arch() {
    case "$1" in
        qemuarm64) echo aarch64 ;;
        qemux86-64) echo x86_64 ;;
        qemuarm) echo armv7l ;;
        *) echo "" ;;
    esac
}

cmd_build() {
    local machine="${1:-qemuarm64}"; shift
    local images=("$@")
    [ ${#images[@]} -eq 0 ] && images=(gnuradio4-ptest-image)
    ( oe_env "$machine"; bitbake "${images[@]}" )
}

cmd_boot() {
    local machine="${1:-qemuarm64}" image="${2:-gnuradio4-ptest-image}"
    local conf="$BUILD_DIR/tmp/deploy/images/$machine/$image-$machine.rootfs.qemuboot.conf"
    [ -e "$conf" ] || { echo "No $conf -- build it first" >&2; return 1; }
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null
    mkdir -p "$(dirname "$CONSOLE_LOG")"
    echo "$machine" >"$MACHINE_FILE"
    (
        oe_env "$machine"
        # Pass the qemuboot.conf path, not "MACHINE IMAGE", so runqemu can't resolve another machine.
        tmux new-session -d -s "$TMUX_SESSION" -x 220 -y 50 \
            "runqemu '$conf' nographic slirp snapshot qemuparams='-m 2048' 2>&1 | tee '$CONSOLE_LOG'"
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
    local i arch want
    for i in $(seq 1 30); do
        if arch=$(ssh_cmd uname -m 2>/dev/null); then
            want=$(expected_arch "$(cat "$MACHINE_FILE" 2>/dev/null)")
            if [ -n "$want" ] && [ "$arch" != "$want" ]; then
                echo "WRONG VM: guest is $arch, expected $want (stale VM on port $SSH_PORT or wrong image?)" >&2
                return 2
            fi
            echo "SSH ready on 127.0.0.1:$SSH_PORT (guest arch $arch)"
            return 0
        fi
        sleep 3
    done
    echo "TIMED OUT waiting for SSH login" >&2
    return 1
}

cmd_exec() {
    ssh_cmd "$@"
}

cmd_ptest() {
    # No args: ptest-runner runs every ptest installed in the image (see `ptest-runner -l`).
    ssh_cmd "ptest-runner $*"
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
    build)    shift; cmd_build "$@" ;;
    boot)     shift; cmd_boot "$@" ;;
    wait-ssh) shift; cmd_wait_ssh "$@" ;;
    exec)     shift; cmd_exec "$@" ;;
    ptest)    shift; cmd_ptest "$@" ;;
    stop)     shift; cmd_stop "$@" ;;
    *)
        echo "Usage: $0 {build [MACHINE] [IMAGE...] | boot [MACHINE] [IMAGE] | wait-ssh [TIMEOUT_S] | exec <cmd...> | ptest [pkg...] | stop}" >&2
        exit 1
        ;;
esac
