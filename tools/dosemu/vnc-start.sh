#!/usr/bin/env bash
# dosemu-vnc-start — launch a fluxbox+xterm+dosemu live-debug session
# on the headless VNC desktop (port 5901). For human-driven testing
# when you want to type at the DOS prompt and watch a real screen.
#
# This is a thin wrapper around `dosemu-run vnc`. Project-specific
# behaviors (e.g. mounting /dos/c/serdfs/dos/build, auto-launching the
# SerialDFS daemon) live here, not in `dosemu-run`, so the lower-level
# script stays generic.
#
# Usage:
#   dosemu-vnc-start                      # mount default /dos/c
#   dosemu-vnc-start /dos/c/serdfs/dos/build
#   dosemu-vnc-start --daemon "linux-daemon /tmp/dos-com1" \
#                    /dos/c/serdfs/dos/build
#
# Flags:
#   --daemon "CMD"   spawn CMD as a background process AFTER dosemu's
#                    PTY appears (useful for serial daemons). Multiple
#                    --daemon allowed.
#
# Connect:  `open vnc://localhost:5901`  (or any VNC client → 5901)
# Stop:     `dosemu-vnc-stop`

set -u

MOUNT_DIR="${BOX86_VM_PATH:-/dos/c}"
DAEMONS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --daemon) DAEMONS+=("$2"); shift 2 ;;
        -h|--help)
            sed -n '2,/^set -u/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) MOUNT_DIR="$1"; shift ;;
    esac
done

# Bring up Xvfb + x11vnc + fluxbox + xterm-running-dosemu via run.sh.
dosemu-run vnc -d "${MOUNT_DIR}"

# Wait for COM1 PTY to appear, then spawn user daemons.
if [ "${#DAEMONS[@]}" -gt 0 ]; then
    for _ in $(seq 1 30); do
        [ -L /tmp/dos-com1 ] && break
        sleep 0.5
    done
    if [ ! -L /tmp/dos-com1 ]; then
        echo "[dosemu-vnc-start] warning: /tmp/dos-com1 never appeared" >&2
    fi
    for d in "${DAEMONS[@]}"; do
        echo "[dosemu-vnc-start] launching daemon: $d"
        bash -c "$d" > "/tmp/dosemu-vnc-daemon-$$.log" 2>&1 &
    done
fi

cat <<MSG

────────────────────────────────────────────────────────────────────
  dosemu2 live session ready
  Open:    vnc://localhost:5901
  Mount:   ${MOUNT_DIR} → next free DOS drive (typically G:)
  COM1:    /tmp/dos-com1 (raw PTY — no bridge needed)
  Stop:    dosemu-vnc-stop
────────────────────────────────────────────────────────────────────
MSG
