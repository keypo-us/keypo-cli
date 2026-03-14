#!/bin/bash
# T-A1: LAContext path produces identical vault exec output
# Precondition: biometric vault contains TEST_SECRET=hello
# Interactive: requires Touch ID approval
set -uo pipefail

echo "=== T-A1: LAContext path produces identical vault exec output ==="
echo "Precondition: biometric vault must contain TEST_SECRET=hello"
echo "Action: Running vault exec with printenv TEST_SECRET"
echo ">>> Touch ID prompt will appear — please APPROVE <<<"
echo ""

OUTPUT=$(keypo-signer vault exec --label biometric --allow TEST_SECRET -- printenv TEST_SECRET 2>/dev/null)
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = "hello" ]; then
    echo "PASS: exit code 0, stdout='hello'"
else
    echo "FAIL: exit code=$EXIT_CODE, stdout='$OUTPUT' (expected exit 0, stdout 'hello')"
    exit 1
fi
