#!/usr/bin/env bash
# dosemu-vnc-stop — tear down the dosemu-vnc-start session.
#
# Kills dosemu, fluxbox, xterm. Leaves Xvfb + x11vnc up (cheap and the
# next session reuses them). Use `dosemu-run kill-all` to nuke the
# display stack too.
#
# Also reaps common project-side daemons (linux.serdfsd) and removes
# the /tmp/dos-com1 PTY symlink so the next session starts clean.

dosemu-run stop
pkill -9 -f 'linux\.serdfsd' 2>/dev/null || true
pkill -9 -f 'qemu-x86_64.*serdfsd' 2>/dev/null || true
rm -f /tmp/dos-com1 /tmp/dosemu-vnc-daemon-*.log

echo "[dosemu-vnc-stop] stopped"
