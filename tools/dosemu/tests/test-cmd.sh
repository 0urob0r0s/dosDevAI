#!/usr/bin/env bash
# tests/test-cmd.sh — smoke test for `dosemu-cmd`.
#
# Verifies that the cleanroom driver:
#   1. boots dosemu
#   2. runs basic DOS commands and captures their output
#   3. assigns a hostfs mount to G:
#   4. tears down cleanly (no stale processes / FIFOs)
set -u

PASS=0; FAIL=0
check() {
    local name="$1"; shift
    if "$@"; then
        echo "  PASS: ${name}"; PASS=$((PASS+1))
    else
        echo "  FAIL: ${name}"; FAIL=$((FAIL+1))
    fi
}

echo "=== dosemu-cmd smoke ==="

OUT=$(dosemu-cmd "VER" 2>&1)
check "VER prints something containing FreeDOS or DOS" \
    bash -c "echo '${OUT}' | grep -qiE 'freedos|dos'"

# Mount /tmp/test-mount-$$ as a host dir, drop one file in, verify DIR sees it.
T=/tmp/test-mount-$$
mkdir -p "${T}"
echo TEST > "${T}/HELLO.TXT"
OUT=$(dosemu-cmd --mount "${T}" "G:" "DIR /B" 2>&1)
check "G: drive lists HELLO.TXT" \
    bash -c "echo '${OUT}' | grep -qi 'HELLO.TXT'"
rm -rf "${T}"

# After teardown, no dosemu / qemu-x86_64-wrapping-dosemu / dos-com1 left.
# Match only actual dosemu BINARY paths, not random commandlines (e.g.
# this test script's own argv) that happen to contain the literal string.
sleep 2
check "no stale dosemu" \
    bash -c "! pgrep -f '/usr/libexec/dosemu2/dosemu2[.]bin' >/dev/null"
check "no stale /tmp/dos-com1" \
    bash -c "! [ -e /tmp/dos-com1 ]"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
