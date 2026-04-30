#!/usr/bin/env bash
# Reference end-to-end smoke for the build → run loop.
# Builds HELLO.EXE on Linux, runs it inside dosemu2 via a hostfs mount,
# asserts the captured output. ~10 s total on the dosemu2 path.
#
# A second, slower path (build → install-into-dos.img → run via 86Box,
# ~40 s total) is also exercised below to keep the 86Box toolkit
# regression-tested. Skipped by default; set EXAMPLE_HELLO_INCLUDE_86BOX=1
# to run it too.
#
# Run:
#     bash /workspace/examples/hello/test.sh
#
# Pass = exit 0 with all checks PASS.
set -uo pipefail

PASS=0; FAIL=0
HERE="$(cd "$(dirname "$0")" && pwd)"

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
    dosemu-run stop 2>/dev/null || true
    86box-run stop 2>/dev/null || true
}
trap cleanup EXIT

echo "=== hello example (dosemu2 path): build → run ==="

# 1. Build with Open Watcom
mkdir -p "$HERE/build"
( cd "$HERE" && wmake all ) >/tmp/hello-build.log 2>&1
check "HELLO.EXE built" "HELLO.EXE" \
    "$(ls -la "$HERE/build/HELLO.EXE" 2>&1 || cat /tmp/hello-build.log)"

# 2. Run inside dosemu2 via hostfs mount — no install step.
OUT="$(dosemu-cmd --mount "$HERE/build" "G:" "G:\\HELLO.EXE alpha beta" 2>&1)"
check "DOS prints greeting (dosemu2)"  "Hello from DOS"  "$OUT"
check "DOS echoes argv[1]=alpha (dosemu2)" "argv[1]=alpha" "$OUT"

# 3. Optional: same scenario via 86Box.
if [ "${EXAMPLE_HELLO_INCLUDE_86BOX:-0}" = "1" ]; then
    echo ""
    echo "=== hello example (86Box path): build → install → run ==="

    86box-run stop 2>/dev/null || true
    sleep 1
    86box-install-dos --to 'C:\HELLO' "$HERE/build/HELLO.EXE" >/dev/null
    check "HELLO.EXE in dos.img" "HELLO" \
        "$(mdir -i /dos/c/dos.img@@$((62*512)) ::HELLO 2>&1 | grep HELLO || echo MISSING)"

    OUT86="$(86box-cmd 'C:\HELLO\HELLO.EXE alpha beta' 2>&1)"
    check "DOS prints greeting (86Box)"  "Hello from DOS"  "$OUT86"
    check "DOS echoes argv[1]=alpha (86Box)" "argv[1]=alpha" "$OUT86"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
