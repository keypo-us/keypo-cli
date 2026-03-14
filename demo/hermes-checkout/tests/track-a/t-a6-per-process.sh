#!/bin/bash
# T-A6: Authenticated context is per-process
# Interactive: requires TWO separate Touch ID approvals
set -uo pipefail

echo "=== T-A6: Authenticated context is per-process ==="
echo "This test verifies that each vault exec gets its own biometric prompt."
echo ""
echo "Instructions:"
echo "  1. Open TWO terminal windows"
echo "  2. In terminal 1, run:"
echo "     keypo-signer vault exec --label biometric --allow TEST_SECRET -- echo ok"
echo "  3. Approve Touch ID in terminal 1"
echo "  4. IMMEDIATELY in terminal 2, run the same command"
echo "  5. Terminal 2 should get its OWN Touch ID prompt"
echo ""
echo "Did terminal 2 get its own Touch ID prompt? (y/n)"
read -p "> " ANSWER

if [ "$ANSWER" = "y" ]; then
    echo "PASS: authenticated context is per-process"
else
    echo "FAIL: LAContext leaked across process boundaries"
    exit 1
fi
