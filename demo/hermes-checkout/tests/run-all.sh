#!/bin/bash
# Run all automatable tests in dependency order.
# Tests requiring interactive biometric, Hermes, or final-demo credentials are skipped.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
SKIP=0

run_test() {
    local test_file="$1"
    echo "────────────────────────────────────────"
    OUTPUT=$(bash "$test_file" 2>&1)
    echo "$OUTPUT"
    if echo "$OUTPUT" | grep -q "PASS"; then
        PASS=$((PASS + 1))
    elif echo "$OUTPUT" | grep -q "SKIP"; then
        SKIP=$((SKIP + 1))
    else
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

echo "═══════════════════════════════════════════"
echo "  Keypo Hermes Checkout — Test Suite"
echo "═══════════════════════════════════════════"
echo ""

# Track B — Automated tests (no browser needed)
echo ">>> Track B: Checkout Script (automated) <<<"
run_test "$SCRIPT_DIR/track-b/t-b1-missing-env.sh"
run_test "$SCRIPT_DIR/track-b/t-b2-invalid-manifest.sh"
run_test "$SCRIPT_DIR/track-b/t-b3-empty-stdin.sh"

# Track D — Automated tests (no daemon needed)
echo ">>> Track D: Hermes Tool (automated) <<<"
run_test "$SCRIPT_DIR/track-d/t-d1-tool-listed.sh"
run_test "$SCRIPT_DIR/track-d/t-d4-daemon-not-running.sh"
run_test "$SCRIPT_DIR/track-d/t-d5-missing-param.sh"

# Track C — Automated tests (daemon socket protocol, no biometric)
echo ">>> Track C: Daemon Protocol (automated) <<<"
run_test "$SCRIPT_DIR/track-c/t-c3-confirm-without-stage.sh"
run_test "$SCRIPT_DIR/track-c/t-c4-double-stage.sh"
run_test "$SCRIPT_DIR/track-c/t-c5-cancel.sh"
run_test "$SCRIPT_DIR/track-c/t-c9-socket-cleanup.sh"

echo "════════════════════════════════════════════"
echo ""
echo "RESULTS: $PASS passed, $FAIL failed, $SKIP skipped"
echo ""

# List skipped interactive tests
echo "Skipped (interactive / manual):"
echo "  Track A: T-A1–T-A6 (require Touch ID hardware)"
echo "  Track B: T-B4–T-B8 (require shop.keypo.io), T-B9–T-B11"
echo "  Track C: T-C1, T-C2, T-C6–T-C8, T-C10 (require Touch ID)"
echo "  Track C: T-C-sec1–T-C-sec6 (require install-daemon.sh)"
echo "  Track D: T-D2, T-D3 (require daemon), T-D6–T-D9 (require Hermes)"
echo "  Integration: T-V1, T-V2, T-E1–T-E7"
echo "  Stage 2/3: T-F1–T-F2, T-G1–T-G7"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
