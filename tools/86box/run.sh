#!/usr/bin/env bash
# Start 86Box headlessly on Xvfb + x11vnc.
#
# Installed as `86box-run` on PATH. Source lives in tools/86box/run.sh.
#
# Usage:
#   86box-run display-up               ensure Xvfb + x11vnc only (no 86Box)
#   86box-run start <vm-path>          start 86Box; vm-path holds 86box.cfg + dos.img
#   86box-run stop                     kill 86Box (keeps Xvfb + x11vnc up)
#   86box-run kill-all                 kill 86Box, x11vnc, Xvfb
#   86box-run status                   show what's running
#   86box-run wait-vnc                 block until VNC port is reachable
#
# Env (with defaults):
#   BOX86_HOME=/opt/86box                    extracted AppImage root
#   BOX86_ROMS=/opt/86box/roms               ROM tree
#   BOX86_DISPLAY=:99                        Xvfb display
#   BOX86_RES=1024x768                       Xvfb resolution
#   BOX86_VNC_PORT=5901                      x11vnc bind port
#   BOX86_LOG_DIR=/tmp/86box                 stdout/stderr log dir
set -euo pipefail

: "${BOX86_HOME:=/opt/86box}"
: "${BOX86_ROMS:=/opt/86box/roms}"
: "${BOX86_DISPLAY:=:99}"
: "${BOX86_RES:=1024x768}"
: "${BOX86_VNC_PORT:=5901}"
: "${BOX86_LOG_DIR:=/tmp/86box}"

mkdir -p "${BOX86_LOG_DIR}"

DISPLAY_NUM="${BOX86_DISPLAY#:}"
XVFB_LOG="${BOX86_LOG_DIR}/xvfb.log"
X11VNC_LOG="${BOX86_LOG_DIR}/x11vnc.log"
BOX_LOG="${BOX86_LOG_DIR}/86box.log"
BOX_PID_FILE="${BOX86_LOG_DIR}/86box.pid"

ensure_xvfb() {
    if [ ! -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
        nohup Xvfb "${BOX86_DISPLAY}" -screen 0 "${BOX86_RES}x24" -ac \
            > "${XVFB_LOG}" 2>&1 < /dev/null &
        disown
        for _ in $(seq 1 30); do
            [ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && return 0
            sleep 0.1
        done
        echo "Xvfb failed to start" >&2; exit 1
    fi
}

ensure_x11vnc() {
    if ! pgrep -f "x11vnc.*-rfbport ${BOX86_VNC_PORT}" >/dev/null 2>&1; then
        nohup x11vnc -display "${BOX86_DISPLAY}" -nopw -listen 0.0.0.0 \
            -rfbport "${BOX86_VNC_PORT}" -forever -shared \
            -noxdamage -quiet \
            > "${X11VNC_LOG}" 2>&1 < /dev/null &
        disown
    fi
}

start_box() {
    local vm_path="${1:?vm-path required}"
    [ -f "${vm_path}/86box.cfg" ] || { echo "no 86box.cfg in ${vm_path}" >&2; exit 1; }

    ensure_xvfb
    ensure_x11vnc

    if [ -f "${BOX_PID_FILE}" ] && kill -0 "$(cat "${BOX_PID_FILE}")" 2>/dev/null; then
        echo "86Box already running (PID $(cat "${BOX_PID_FILE}"))"
        return 0
    fi

    # Make 86box.cfg read-only so the emulator can't normalize hard-disk
    # CHS on shutdown (which would break boot on next start).
    chmod 0444 "${vm_path}/86box.cfg"

    cd "${BOX86_HOME}"
    nohup env DISPLAY="${BOX86_DISPLAY}" QT_QPA_PLATFORM=xcb \
        ./AppRun -P "${vm_path}" -C 86box.cfg -R "${BOX86_ROMS}" --noconfirm \
        > "${BOX_LOG}" 2>&1 < /dev/null &
    local pid=$!
    disown
    echo "${pid}" > "${BOX_PID_FILE}"
    echo "86Box started (PID ${pid}) — VNC ${BOX86_VNC_PORT}, log ${BOX_LOG}"

    # First-run AMIBIOS shows "CMOS Checksum Invalid / Press F1 / ESC" until
    # an NVRAM file (vm-path/nvr/*.nvr) is written. Send ESC a few times in
    # the background so the boot proceeds unattended. Cheap no-op once NVR
    # is established (key events go to a running DOS).
    (
        sleep 6
        for _ in 1 2 3 4 5; do
            "${HOME}/.local/bin/vncdo" -s "::${BOX86_VNC_PORT}" key esc \
                >/dev/null 2>&1 || true
            sleep 2
        done
    ) &
    disown
}

stop_box() {
    # SIGKILL only. SIGTERM lets 86Box gracefully write back its cfg, which
    # normalizes hard-disk CHS away from the values used to install DOS,
    # breaking subsequent boots ("Missing operating system"). The cfg is
    # also chmod'd 0444 in start_box() as defense in depth.
    if [ -f "${BOX_PID_FILE}" ]; then
        local pid; pid="$(cat "${BOX_PID_FILE}")"
        if kill -0 "${pid}" 2>/dev/null; then
            kill -9 "${pid}" 2>/dev/null || true
        fi
        rm -f "${BOX_PID_FILE}"
    fi
    pkill -9 -f "86Box.*86box.cfg" 2>/dev/null || true
}

kill_all() {
    stop_box
    pkill -f "x11vnc.*-rfbport ${BOX86_VNC_PORT}" 2>/dev/null || true
    pkill -f "Xvfb ${BOX86_DISPLAY} " 2>/dev/null || true
}

status() {
    echo "Xvfb ${BOX86_DISPLAY}:  $([ -e /tmp/.X11-unix/X${DISPLAY_NUM} ] && echo up || echo down)"
    echo "x11vnc :${BOX86_VNC_PORT}: $(pgrep -f "x11vnc.*-rfbport ${BOX86_VNC_PORT}" >/dev/null && echo up || echo down)"
    if [ -f "${BOX_PID_FILE}" ] && kill -0 "$(cat "${BOX_PID_FILE}")" 2>/dev/null; then
        echo "86Box:        up (PID $(cat "${BOX_PID_FILE}"))"
    else
        echo "86Box:        down"
    fi
}

wait_vnc() {
    for _ in $(seq 1 100); do
        python3 -c "
import socket
s=socket.socket(); s.settimeout(1)
try: s.connect(('127.0.0.1', ${BOX86_VNC_PORT})); print(s.recv(12).decode().strip()); s.close()
except: import sys; sys.exit(1)
" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "VNC ${BOX86_VNC_PORT} not reachable" >&2; exit 1
}

display_up() {
    ensure_xvfb
    ensure_x11vnc
    echo "headless display ready: Xvfb ${BOX86_DISPLAY}, x11vnc :${BOX86_VNC_PORT}"
}

case "${1:-}" in
    display-up) display_up;;
    start)      start_box "${2:?vm-path required}";;
    stop)       stop_box;;
    kill-all)   kill_all;;
    status)     status;;
    wait-vnc)   wait_vnc;;
    *)
        sed -n '2,17p' "$0"
        exit 1
        ;;
esac
