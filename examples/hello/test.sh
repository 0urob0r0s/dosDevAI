#!/usr/bin/env bash
# Reference end-to-end smoke for the build → install → test loop.
# Builds HELLO.EXE on Linux, installs into dos.img, runs it inside 86Box,
# and asserts the captured output. ~40 s total (mostly the 86Box cold boot).
#
# Run:
#     bash /workspace/examples/hello/test.sh
#
# Pass = exit 0 with "Results: 4 passed, 0 failed".
set -uo pipefail

PASS=0; FAIL=0
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/hello-example.out

check() {
    local desc="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -qF "$expected"; then
        echo "  PASS: $desc"; PASS=$((PASS+1))
    else
        echo "  FAIL: $desc"
        echo "        expected: $expected"
        echo "        got:      $(echo "$actual" | head -3)"
        FAIL=$((FAIL+1))
    fi
}

cleanup() {
    86box-run stop 2>/dev/null || true
}
trap cleanup EXIT

echo "=== hello example: build → install → test ==="

# 1. Build with Open Watcom
mkdir -p "$HERE/build"
( cd "$HERE" && wmake all ) >/tmp/hello-build.log 2>&1
check "HELLO.EXE built" "HELLO.EXE" "$(ls -la "$HERE/build/HELLO.EXE" 2>&1 || cat /tmp/hello-build.log)"

# 2. Install into dos.img (86Box must be stopped — install-dos refuses otherwise)
86box-run stop 2>/dev/null || true
sleep 1
86box-install-dos --to 'C:\HELLO' "$HERE/build/HELLO.EXE" >/dev/null
check "HELLO.EXE in dos.img" "HELLO" \
    "$(mdir -i /dos/c/dos.img@@$((62*512)) ::HELLO 2>&1 | grep HELLO || echo MISSING)"

# 3. Run inside DOS, capture stdout
86box-cmd 'C:\HELLO\HELLO.EXE alpha beta' > "$OUT" 2>&1
OUT_TEXT="$(cat "$OUT" 2>/dev/null || echo MISSING)"
check "DOS prints greeting"  "Hello from DOS"  "$OUT_TEXT"
check "DOS echoes argv[1]=alpha" "argv[1]=alpha" "$OUT_TEXT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
