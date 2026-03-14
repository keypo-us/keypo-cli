#!/bin/bash
# T-A4: Secrets scoped to child process only
# Interactive: requires Touch ID approval
set -uo pipefail

echo "=== T-A4: Secrets scoped to child process only ==="
echo "Action: vault exec prints TEST_SECRET, then parent shell checks"
echo ">>> Touch ID prompt will appear — please APPROVE <<<"
echo ""

# Run vault exec — secret should be available to child
OUTPUT=$(keypo-signer vault exec --label biometric --allow TEST_SECRET -- printenv TEST_SECRET 2>/dev/null)
EXIT_CODE=$?

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "FAIL: vault exec failed with exit code=$EXIT_CODE"
    exit 1
fi

if [ "$OUTPUT" != "hello" ]; then
    echo "FAIL: child process did not see TEST_SECRET (got '$OUTPUT')"
    exit 1
fi

# Now check parent shell — should NOT have the secret
PARENT_VALUE="${TEST_SECRET:-}"
if [ -z "$PARENT_VALUE" ]; then
    echo "PASS: child saw TEST_SECRET='hello', parent shell has no TEST_SECRET"
else
    echo "FAIL: TEST_SECRET leaked to parent shell: '$PARENT_VALUE'"
    exit 1
fi
