#!/usr/bin/env bash
# 86box-install-dos — mcopy host files into dos.img at a DOS path.
#
# 86Box doesn't have DOSBox-X's host-mount feature, so any project's
# DOS-side build artifacts (.EXE, .COM, data files) need to be copied
# into the dos.img before they can be run inside DOS. This tool wraps
# the mtools incantation (`mcopy -o -i dos.img@@$((62*512))`) and the
# directory-creation dance.
#
# Usage:
#   86box-install-dos --to 'C:\PROJ\BUILD' file1.exe file2.com ...
#   86box-install-dos --to 'C:\TOOLS' --src ./build --pattern '*.EXE'
#   86box-install-dos --to 'C:\PROJ' --src ./bin     # copies all of ./bin
#
# Multiple --src + --pattern pairs are NOT supported; one of:
#   - explicit positional file list, OR
#   - one --src dir (with optional --pattern; defaults to all files in dir).
#
# Flags:
#   --to PATH      destination DOS path (e.g. 'C:\SERDFS\DOS\BUILD'). Required.
#                  Will be created if missing.
#   --src DIR      source directory (alternative to positional files).
#   --pattern GLOB shell glob to filter --src files (default: *).
#   --img PATH     dos.img path (default: $BOX86_VM_PATH/dos.img → /dos/c/dos.img).
#   --offset N     LBA × 512 offset of the FAT partition. Default 31744
#                  (62 × 512 — matches the bundled MS-DOS 6.22 template).
#   --quiet        suppress per-file output, only print summary.
#
# Safety: refuses to run while 86Box is up — concurrent mtools+IDE
# writes against dos.img cause FAT cache divergence (DOS BUFFERS
# disagrees with on-disk state, file corruption follows). Stop 86Box
# (`86box-run stop`), install, restart.
set -uo pipefail

: "${BOX86_VM_PATH:=/dos/c}"
IMG="${BOX86_VM_PATH}/dos.img"
OFFSET=$((62 * 512))
DEST=""
SRC_DIR=""
PATTERN="*"
QUIET=0
declare -a FILES=()

usage() { sed -n '2,30p' "$0"; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --to)      DEST="$2";    shift 2;;
        --src)     SRC_DIR="$2"; shift 2;;
        --pattern) PATTERN="$2"; shift 2;;
        --img)     IMG="$2";     shift 2;;
        --offset)  OFFSET="$2";  shift 2;;
        --quiet|-q) QUIET=1;     shift;;
        -h|--help) usage;;
        --)        shift; FILES+=("$@"); break;;
        -*)        echo "unknown flag: $1" >&2; exit 2;;
        *)         FILES+=("$1"); shift;;
    esac
done

[ -n "$DEST" ] || { echo "ERROR: --to <DOS path> is required" >&2; usage; }
[ -f "$IMG" ] || { echo "ERROR: dos.img not at $IMG" >&2; exit 1; }

if pgrep -f "[8]6Box.*86box.cfg" >/dev/null 2>&1; then
    echo "ERROR: 86Box is running. Stop it first ('86box-run stop'); concurrent" >&2
    echo "       writes against dos.img diverge from DOS BUFFERS." >&2
    exit 1
fi

# Materialize the file list.
if [ -n "$SRC_DIR" ]; then
    [ -d "$SRC_DIR" ] || { echo "ERROR: --src $SRC_DIR not a directory" >&2; exit 1; }
    [ "${#FILES[@]}" -eq 0 ] || { echo "ERROR: --src and positional files are mutually exclusive" >&2; exit 1; }
    shopt -s nullglob
    FILES=( "$SRC_DIR"/$PATTERN )
    shopt -u nullglob
fi
[ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no source files to install" >&2; exit 1; }

# Translate the DOS path: strip drive letter, replace '\' with '/'.
# 'C:\PROJ\BUILD' → 'PROJ/BUILD'; '\PROJ' → 'PROJ'; 'PROJ' as-is.
mtools_path="${DEST#[A-Za-z]:}"   # strip 'C:'
mtools_path="${mtools_path//\\//}"
mtools_path="${mtools_path#/}"    # strip leading slash

# Create the directory chain idempotently.
IFS='/' read -ra parts <<< "$mtools_path"
acc=""
for part in "${parts[@]}"; do
    [ -z "$part" ] && continue
    acc="${acc:+$acc/}$part"
    mmd -i "$IMG@@$OFFSET" "::$acc" >/dev/null 2>&1 || true
done

# Copy each file in (mcopy -o = overwrite without prompting).
n=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || { echo "  skip (not a file): $f" >&2; continue; }
    name="$(basename "$f")"
    target="::${mtools_path}/${name}"
    [ "$QUIET" -eq 0 ] && echo "  → ${DEST%\\}\\${name}"
    mcopy -o -i "$IMG@@$OFFSET" "$f" "$target"
    n=$((n + 1))
done

echo "[install-dos] $n file(s) copied to ${IMG}: ${DEST}"
