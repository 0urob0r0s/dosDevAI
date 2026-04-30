#!/usr/bin/env bash
# Build the DOS-side helper executables shipped with the toolkit.
# Idempotent — only rebuilds if sources are newer than outputs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"

CFLAGS="-bt=dos -ms -0 -os -s -d0 -we -wx"
SRCS=( "$HERE/pcmdd.c" "$HERE/seruart.c" "$HERE/seruart.h" )

needs_rebuild=0
if [ ! -f "$OUT/PCMDD.EXE" ]; then
    needs_rebuild=1
else
    for f in "${SRCS[@]}"; do
        if [ "$f" -nt "$OUT/PCMDD.EXE" ]; then needs_rebuild=1; break; fi
    done
fi

if [ "$needs_rebuild" -eq 0 ]; then
    echo "PCMDD.EXE up to date"
    exit 0
fi

echo "Building PCMDD.EXE..."
( cd "$HERE" && wcl $CFLAGS -fe="$OUT/PCMDD.EXE" pcmdd.c seruart.c )
# wcl drops .o files in CWD; tidy.
rm -f "$HERE"/*.o "$HERE"/*.obj "$HERE"/*.map "$HERE"/*.err
ls -la "$OUT/PCMDD.EXE"
