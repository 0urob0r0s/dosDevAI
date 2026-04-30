#!/usr/bin/env bash
# Idempotent 86Box installer for the dev sandbox container.
#
# - Downloads the 86Box Linux AppImage to /opt/86box-app/86Box.AppImage
# - Patches the AppImage's "AI 02" magic bytes (offset 8-10) so the kernel
#   can read it as a normal ELF when /dev/fuse is unavailable (Docker default).
# - Extracts the squashfs payload into /opt/86box/ via --appimage-extract.
# - Downloads the official 86Box ROM repo (master) and unpacks into /opt/86box/roms/.
#
# Designed for use in the Dockerfile (run once at build time) and for
# manual reinstall in a running container.
#
# Env (with defaults):
#   BOX86_VERSION=v5.3
#   BOX86_BUILD=b8200
#   BOX86_INSTALL_DIR=/opt/86box
#   BOX86_ROMS_DIR=/opt/86box/roms
set -euo pipefail

: "${BOX86_VERSION:=v5.3}"
: "${BOX86_BUILD:=b8200}"
: "${BOX86_INSTALL_DIR:=/opt/86box}"
: "${BOX86_ROMS_DIR:=/opt/86box/roms}"
: "${BOX86_APP_DIR:=/opt/86box-app}"

APPIMAGE_URL="${BOX86_APPIMAGE_URL:-https://github.com/86Box/86Box/releases/download/${BOX86_VERSION}/86Box-Linux-x86_64-${BOX86_BUILD}.AppImage}"
ROMS_URL="${BOX86_ROMS_URL:-https://github.com/86Box/roms/archive/refs/heads/master.zip}"

log() { printf '[86box-setup] %s\n' "$*"; }

ensure_dirs() {
    mkdir -p "${BOX86_APP_DIR}" "${BOX86_INSTALL_DIR}" "${BOX86_ROMS_DIR}"
}

fetch_appimage() {
    local target="${BOX86_APP_DIR}/86Box.AppImage"
    if [ -s "${target}" ]; then
        log "AppImage already present at ${target}"
        return 0
    fi
    log "fetching ${APPIMAGE_URL}"
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 \
        --speed-time 30 --speed-limit 1024 \
        "${APPIMAGE_URL}" -o "${target}"
    chmod +x "${target}"
}

patch_and_extract() {
    local img="${BOX86_APP_DIR}/86Box.AppImage"
    if [ -x "${BOX86_INSTALL_DIR}/usr/local/bin/86Box" ]; then
        log "86Box already extracted to ${BOX86_INSTALL_DIR}"
        return 0
    fi
    # Patch out the AppImage "AI" magic so the kernel/QEMU sees a plain ELF.
    local patched="${BOX86_APP_DIR}/86Box.patched"
    cp -f "${img}" "${patched}"
    printf '\x00\x00\x00' | dd of="${patched}" bs=1 seek=8 count=3 conv=notrunc \
        status=none
    chmod +x "${patched}"

    log "extracting AppImage into ${BOX86_INSTALL_DIR}"
    local tmp; tmp="$(mktemp -d)"
    ( cd "${tmp}" && "${patched}" --appimage-extract >/dev/null )
    cp -a "${tmp}/squashfs-root/." "${BOX86_INSTALL_DIR}/"
    rm -rf "${tmp}" "${patched}"
}

fetch_roms() {
    if [ -d "${BOX86_ROMS_DIR}/machines" ] && [ -n "$(ls -A "${BOX86_ROMS_DIR}/machines" 2>/dev/null)" ]; then
        log "ROM tree already populated at ${BOX86_ROMS_DIR}"
        return 0
    fi
    log "fetching ROM repo"
    local zip="${BOX86_APP_DIR}/roms.zip"
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 \
        --speed-time 30 --speed-limit 1024 \
        "${ROMS_URL}" -o "${zip}"
    local tmp; tmp="$(mktemp -d)"
    unzip -oq "${zip}" -d "${tmp}"
    cp -a "${tmp}"/roms-*/. "${BOX86_ROMS_DIR}/"
    rm -rf "${tmp}" "${zip}"
}

verify() {
    local bin="${BOX86_INSTALL_DIR}/usr/local/bin/86Box"
    [ -x "${bin}" ] || { echo "missing ${bin}" >&2; exit 1; }
    [ -d "${BOX86_ROMS_DIR}/machines/ninja" ] || {
        echo "missing ninja machine ROMs" >&2; exit 1; }
    log "OK: 86Box at ${bin}, ROMs at ${BOX86_ROMS_DIR}"
}

ensure_dirs
fetch_appimage
patch_and_extract
fetch_roms
verify
