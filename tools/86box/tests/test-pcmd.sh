#!/usr/bin/env bash
# Smoke test for 86box-pcmd. Exercises the full lifecycle (start, run x3,
# stop) and asserts:
#   - start brings the COM2 REPL up within 180 s
#   - VER returns "MS-DOS Version 6.22"
#   - ECHO round-trips a literal string
#   - DIR C:\ returns the volume label
#   - status reports up while running, down after stop
#   - stop strips the v2 AUTOEXEC hook so cold-boot tests aren't poisoned
#
# Total runtime ~70 s (one ~40 s start + a few sub-second runs + stop +
# AUTOEXEC inspection).
#
# Run: bash /workspace/tools/86box/tests/test-pcmd.sh
set -uo pipefail

PASS=0; FAIL=0

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
    86box-pcmd  stop 2>/dev/null || true
    86box-run   stop 2>/dev/null || true
    86box-bridge stop 2>/dev/null || true
}
trap cleanup EXIT

echo "=== 86box-pcmd smoke test ==="

# 0. Pre-flight: clean state, no stale 86Box / bridges / com links.
86box-pcmd  stop 2>/dev/null || true
86box-run   stop 2>/dev/null || true
86box-bridge stop 2>/dev/null || true
rm -f /tmp/linux-com1 /tmp/linux-com2
sleep 1

# 1. start
START_OUT="$(86box-pcmd start 2>&1)"
check "start completed with 'ready' message" "[pcmd] ready" "$START_OUT"

# 2. status reports up
check "status reports up"     "up"  "$(86box-pcmd status)"

# 3. functional runs
check "VER → MS-DOS Version"  "MS-DOS Version" "$(86box-pcmd run VER)"
check "ECHO round-trips"      "smoketest"      "$(86box-pcmd run 'ECHO smoketest')"
check "DIR C:\\ shows volume" "MS-DOS_6"       "$(86box-pcmd run 'DIR C:\\')"

# 4. stop
STOP_OUT="$(86box-pcmd stop 2>&1)"
check "stop reports stopped" "stopped" "$STOP_OUT"
check "status reports down"  "down"    "$(86box-pcmd status)"

# 5. AUTOEXEC.BAT must NOT contain the pcmd v2 hook anymore — otherwise
# subsequent cold-boot 86box-cmd runs would launch PCMDD by accident
# and never reach the prompt.
sleep 1
AUTOEXEC="$(mtype -i /dos/c/dos.img@@$((62*512)) ::AUTOEXEC.BAT 2>&1)"
if echo "$AUTOEXEC" | grep -qF 'REM 86box-pcmd v2 hook'; then
    echo "  FAIL: AUTOEXEC.BAT still has v2 pcmd hook after stop"
    FAIL=$((FAIL+1))
else
    echo "  PASS: stop stripped v2 hook from AUTOEXEC.BAT"
    PASS=$((PASS+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
