#!/bin/bash
# T-A2: Cancellation propagates cleanly
# Interactive: requires Touch ID CANCELLATION
set -uo pipefail

echo "=== T-A2: Cancellation propagates cleanly ==="
echo "Action: Running vault exec"
echo ">>> Touch ID prompt will appear — please CANCEL (click Cancel button) <<<"
echo ""

STDERR_FILE=$(mktemp)
keypo-signer vault exec --label biometric --allow TEST_SECRET -- echo ok 2>"$STDERR_FILE"
EXIT_CODE=$?
STDERR=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"

if [ "$EXIT_CODE" -eq 1 ] && echo "$STDERR" | grep -qi "cancelled"; then
    echo "PASS: exit code 1, stderr contains 'cancelled'"
elif [ "$EXIT_CODE" -eq 128 ] && echo "$STDERR" | grep -qi "cancelled"; then
    echo "PASS: exit code 128, stderr contains 'cancelled'"
else
    echo "FAIL: exit code=$EXIT_CODE, stderr='$STDERR'"
    echo "Expected: exit 1 (or 128), stderr containing 'cancelled'"
    exit 1
fi
