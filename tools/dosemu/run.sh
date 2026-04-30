#!/usr/bin/env bash
# dosemu-run — start/stop/status the dumb-mode dosemu instance and the
# headless display stack.
#
# Two modes of operation:
#
#   dumb        — the AI / batch mode. dosemu reads stdin and writes the
#                 DOS screen as plain text to stdout. Best for non-
#                 interactive test drivers. No GUI, no VNC tokens.
#                 (Use `dosemu-cmd` for the per-call cleanroom variant.)
#
#   vnc         — the human / live-debug mode. fluxbox + xterm under
#                 Xvfb, dosemu running inside the xterm in dumb video.
#                 The user connects to vnc://localhost:5901, sees an
#                 xterm window in fluxbox, types at the DOS prompt.
#                 (Equivalent to `dosemu-vnc-start`.)
#
# Usage:
#   dosemu-run display-up                  # bring up Xvfb + x11vnc only
#   dosemu-run dumb [-d <dir>] [-- args]   # foreground dumb session
#   dosemu-run vnc  [-d <dir>]             # background fluxbox session
#   dosemu-run stop                        # kill all dosemu / fluxbox / xterm
#   dosemu-run kill-all                    # also stop x11vnc + Xvfb
#   dosemu-run status                      # what's up
#
# Env: BOX86_VNC_PORT (default 5901), BOX86_DISPLAY (default :99).
set -u

CMD="${1:-status}"
shift || true

DISPLAY_NUM="${BOX86_DISPLAY:-:99}"
VNC_PORT="${BOX86_VNC_PORT:-5901}"
LOG_DIR="${DOSEMU_LOG_DIR:-/tmp/dosemu}"
mkdir -p "${LOG_DIR}"

is_running() {
    pgrep -f "$1" >/dev/null 2>&1
}

start_xvfb() {
    if is_running "Xvfb ${DISPLAY_NUM}"; then return; fi
    echo "[dosemu-run] starting Xvfb on ${DISPLAY_NUM}"
    Xvfb "${DISPLAY_NUM}" -screen 0 1024x768x24 -ac \
        > "${LOG_DIR}/xvfb.log" 2>&1 &
    sleep 0.5
}

start_x11vnc() {
    if is_running "x11vnc.*-display ${DISPLAY_NUM}"; then return; fi
    echo "[dosemu-run] starting x11vnc :${VNC_PORT}"
    x11vnc -display "${DISPLAY_NUM}" -nopw -listen 0.0.0.0 \
           -rfbport "${VNC_PORT}" -forever -shared -noxdamage -quiet \
        > "${LOG_DIR}/x11vnc.log" 2>&1 &
    sleep 0.5
}

case "${CMD}" in

display-up)
    start_xvfb
    start_x11vnc
    echo "[dosemu-run] display ready: vnc://localhost:${VNC_PORT}"
    ;;

dumb)
    # Foreground dumb-mode dosemu. Caller pipes input or types live.
    # Pass `-d <dir>` flags through verbatim; dosemu auto-assigns the
    # next free drive letter (typically G:).
    exec dosemu -dumb -n -f "$HOME/.dosemurc" "$@"
    ;;

vnc)
    start_xvfb
    start_x11vnc

    # Reap any prior dosemu/xterm/fluxbox owned by this session,
    # NOT the Xvfb/x11vnc background services.
    ps -eo pid,ppid,args | awk '
        $2==1 && /dosemu2\.bin|\/usr\/bin\/dosemu|fluxbox|xterm/ \
              && !/Xvfb|x11vnc/ {print $1}
    ' | xargs -r kill -9 2>/dev/null || true
    rm -f /tmp/dos-com1
    sleep 1

    echo "[dosemu-run] starting fluxbox on ${DISPLAY_NUM}"
    DISPLAY="${DISPLAY_NUM}" fluxbox > "${LOG_DIR}/fluxbox.log" 2>&1 &
    sleep 1

    DEXTRA=()
    while [ $# -gt 0 ]; do
        DEXTRA+=("$1"); shift
    done

    echo "[dosemu-run] launching xterm with dosemu inside"
    DISPLAY="${DISPLAY_NUM}" xterm -fa Monospace -fs 12 \
        -geometry 100x36+0+0 -T "DOSEMU2" \
        -e bash -c "dosemu -dumb -n -f $HOME/.dosemu-vnc.rc ${DEXTRA[*]}" \
        > "${LOG_DIR}/dosemu-vnc.log" 2>&1 &

    sleep 1
    DISPLAY="${DISPLAY_NUM}" xdotool search --name "DOSEMU2" \
        windowactivate 2>/dev/null || true
    cat <<MSG
────────────────────────────────────────────────────────────────────
  dosemu2 ready on VNC :${VNC_PORT}
  Mode:    dumb video inside xterm, fluxbox-managed
  Logs:    ${LOG_DIR}/dosemu-vnc.log
  Stop:    dosemu-run stop  (or dosemu-vnc-stop)
────────────────────────────────────────────────────────────────────
MSG
    ;;

stop)
    # Reap dosemu + fluxbox + xterm under this user, but leave the
    # display stack (Xvfb + x11vnc) alone — restarting them is slow
    # and they're cheap to leave running.
    ps -eo pid,ppid,args | awk '
        $2==1 && /dosemu2\.bin|\/usr\/bin\/dosemu|fluxbox|xterm/ \
              && !/Xvfb|x11vnc/ {print $1}
    ' | xargs -r kill -9 2>/dev/null || true
    pkill -9 -f 'qemu-x86_64.*dosemu2\.bin' 2>/dev/null || true
    rm -f /tmp/dos-com1 /tmp/dos-stdin /tmp/dos-stdin-h
    echo "[dosemu-run] stopped"
    ;;

kill-all)
    "$0" stop
    pkill -9 -f "x11vnc.*-display ${DISPLAY_NUM}" 2>/dev/null || true
    pkill -9 -f "Xvfb ${DISPLAY_NUM}" 2>/dev/null || true
    echo "[dosemu-run] all dosemu + display stack down"
    ;;

status)
    is_running "Xvfb ${DISPLAY_NUM}" \
        && echo "  Xvfb       : up (${DISPLAY_NUM})" \
        || echo "  Xvfb       : down"
    is_running "x11vnc.*-display ${DISPLAY_NUM}" \
        && echo "  x11vnc     : up (port ${VNC_PORT})" \
        || echo "  x11vnc     : down"
    is_running "dosemu2.bin" \
        && echo "  dosemu     : up" \
        || echo "  dosemu     : down"
    is_running "fluxbox" \
        && echo "  fluxbox    : up" \
        || echo "  fluxbox    : down"
    [ -L /tmp/dos-com1 ] \
        && echo "  /tmp/dos-com1 -> $(readlink /tmp/dos-com1)" \
        || echo "  /tmp/dos-com1 : missing"
    ;;

*)
    echo "usage: dosemu-run {display-up|dumb|vnc|stop|kill-all|status}" >&2
    exit 2
    ;;
esac
