#!/usr/bin/env bash
# Container entrypoint:
#   1. seed /dos/c/dos.img from the baked DOS template on first run
#   2. patch CONFIG.SYS (LASTDRIVE=Z) and AUTOEXEC.BAT (86box-cmd hook)
#      so redirector projects (e.g. SerialDFS) can map drives X..Z
#   3. generate a default 86box.cfg if the project doesn't have one
#   4. start the headless display stack (Xvfb + x11vnc) so the host's
#      `vnc://localhost:5901` is reachable from container start, even
#      before any 86Box session is launched
#   5. exec the requested command
#
# Why a flat raw .img instead of a dynamic .vhd:
#   - mtools can read/write .img directly via @@offset, no qemu-img round-trip
#   - dynamic .vhd → mtools requires raw conversion, which qemu-img normalizes
#     CHS geometry on, which breaks DOS boot (it relies on the original CHS)
#   - 86Box reads raw images natively (set hdd_01_fn = dos.img)
#   - The host filesystem keeps the file sparse (only ~6 MB on disk for 234 MB
#     virtual size on ext4/btrfs/tmpfs)
set -euo pipefail

mkdir -p /workspace /dos/c /dos/src /home/coder/.claude

DOS_IMG=/dos/c/dos.img
TEMPLATE_VHD=/opt/dos-c-base/template_dos-c.vhd
OFF=$((62 * 512))

# First-run bootstrap: convert template VHD → raw image. Subsequent starts
# preserve project state (the bind mount keeps /dos/c/dos.img).
if [ ! -f "${DOS_IMG}" ] && [ -f "${TEMPLATE_VHD}" ]; then
    echo "[entrypoint] seeding ${DOS_IMG} from template (one-time)"
    qemu-img convert -O raw "${TEMPLATE_VHD}" "${DOS_IMG}"
fi

# Idempotent patches against the current dos.img (also re-applied if the
# user replaces the image with `rm /dos/c/dos.img && entrypoint.sh`).
if [ -f "${DOS_IMG}" ]; then
    # AUTOEXEC.BAT hook for 86box-cmd's per-call RUN.BAT pickup.
    SENTINEL_AE="REM 86box-cmd hook"
    cur=$(mktemp); new=$(mktemp)
    mtype -i "${DOS_IMG}@@${OFF}" ::AUTOEXEC.BAT > "${cur}" 2>/dev/null || true
    if ! grep -q "${SENTINEL_AE}" "${cur}"; then
        echo "[entrypoint] installing AUTOEXEC.BAT hook for 86box-cmd"
        {
            cat "${cur}"
            printf '\r\n%s\r\n' "${SENTINEL_AE}"
            printf 'IF EXIST A:\\RUN.BAT CALL A:\\RUN.BAT\r\n'
        } > "${new}"
        mcopy -o -i "${DOS_IMG}@@${OFF}" "${new}" ::AUTOEXEC.BAT
    fi
    rm -f "${cur}" "${new}"

    # CONFIG.SYS LASTDRIVE=Z so redirector drive letters X..Z are valid.
    # Without this, INT 2Fh AH=11h drive-mapping projects fail at install
    # with "Unable to activate the local drive mapping".
    cur=$(mktemp); new=$(mktemp)
    mtype -i "${DOS_IMG}@@${OFF}" ::CONFIG.SYS > "${cur}" 2>/dev/null || true
    if ! grep -qi 'LASTDRIVE' "${cur}"; then
        echo "[entrypoint] installing CONFIG.SYS LASTDRIVE=Z"
        {
            cat "${cur}"
            printf '\r\nLASTDRIVE=Z\r\n'
        } > "${new}"
        mcopy -o -i "${DOS_IMG}@@${OFF}" "${new}" ::CONFIG.SYS
    fi
    rm -f "${cur}" "${new}"
fi

# Generate a default 86box.cfg if the project doesn't have one yet.
if [ ! -f /dos/c/86box.cfg ] && [ -f "${DOS_IMG}" ]; then
    echo "[entrypoint] generating /dos/c/86box.cfg (default ninja machine + serial1 passthrough)"
    /usr/local/bin/86box-gen-config --out /dos/c/86box.cfg --vhd dos.img --serial1-passthrough
fi

# Seed /workspace/examples/ from the baked copy if missing. Idempotent —
# only restores files the user hasn't created. Lets a fresh project (which
# bind-mounts an empty ./workspace) still find the reference example.
EX_BAKE=/opt/dos-c-base/examples
EX_LIVE=/workspace/examples
if [ -d "${EX_BAKE}" ] && [ ! -d "${EX_LIVE}" ]; then
    echo "[entrypoint] seeding /workspace/examples/ from baked reference"
    mkdir -p "${EX_LIVE}"
    cp -an "${EX_BAKE}/." "${EX_LIVE}/"
fi

# Start the headless display stack so port 5901 (mapped to the host) is
# reachable from the moment the container is up. 86Box itself only starts
# on demand via `86box-cmd` / `86box-run start`. If the user launches
# `claude` instead of `bash`, the display stack is already warm.
86box-run display-up >/dev/null 2>&1 || true

exec "$@"
