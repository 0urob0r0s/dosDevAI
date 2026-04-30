#!/usr/bin/env bash
# dosemu-setup — idempotent installer for dosemu2 + FDPP + GUI deps.
#
# The Dockerfile invokes this once at image build time. Re-run manually
# only if the dosemu2 install gets corrupted or needs an upgrade.
#
# Installed:
#   - dosemu2          (the emulator)
#   - fdpp             (FreeDOS-derived 64-bit DOS core; loaded by dosemu2)
#   - fluxbox + xterm  (used for the optional VNC-with-window-manager mode)
#   - xdotool          (used by dosemu-vnc-start to focus the xterm window)
#
# All other deps (Xvfb, x11vnc, vncdotool) are already provided by the
# 86Box layer of this image.
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
    echo "[dosemu-setup] this script targets Debian/Ubuntu (apt-get)" >&2
    exit 1
fi

echo "[dosemu-setup] installing dosemu2 + fdpp + fluxbox + xterm + xdotool"

# dosemu2 is in the Ubuntu universe repo on noble. Some images ship with
# only main+restricted enabled — make sure universe is on.
sudo add-apt-repository -y universe 2>/dev/null || true

sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    dosemu2 \
    fdpp \
    fluxbox \
    xterm \
    xdotool

echo "[dosemu-setup] versions:"
dosemu --version 2>&1 | head -1 || true
dpkg -l fdpp     2>/dev/null | awk '/^ii/ {print "  fdpp:    " $3}'
dpkg -l fluxbox  2>/dev/null | awk '/^ii/ {print "  fluxbox: " $3}'

# Drop default user configs into HOME so `dosemu` works out of the box.
HOME_DIR="${HOME:-/home/coder}"
DEFAULTS_DIR="$(dirname "$0")"

if [ ! -f "${HOME_DIR}/.dosemurc" ]; then
    echo "[dosemu-setup] seeding ${HOME_DIR}/.dosemurc"
    cp "${DEFAULTS_DIR}/dosemurc.template" "${HOME_DIR}/.dosemurc"
fi
if [ ! -f "${HOME_DIR}/.dosemu-vnc.rc" ]; then
    echo "[dosemu-setup] seeding ${HOME_DIR}/.dosemu-vnc.rc"
    cp "${DEFAULTS_DIR}/dosemu-vnc.rc.template" "${HOME_DIR}/.dosemu-vnc.rc"
fi

# First run of `dosemu` per user creates ~/.dosemu/drive_c/ and writes
# fdppconf.sys. Doing it now (under noninteractive) means subsequent
# `dosemu-cmd` calls don't pay first-boot setup cost.
mkdir -p "${HOME_DIR}/.dosemu/drive_c"

echo "[dosemu-setup] done"
