#!/bin/bash
# T-A3: Reason string appears in prompt
# Interactive: verify the Touch ID dialog shows the custom reason
set -uo pipefail

echo "=== T-A3: Reason string appears in prompt ==="
echo "Action: Running vault exec with --bio-reason 'Approve cookie purchase'"
echo ">>> Touch ID prompt will appear <<<"
echo ">>> VERIFY that the dialog shows: 'Approve cookie purchase' <<<"
echo ">>> Then APPROVE <<<"
echo ""

OUTPUT=$(keypo-signer vault exec --label biometric --bio-reason "Approve cookie purchase" --allow TEST_SECRET -- echo ok 2>/dev/null)
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ] && [ "$OUTPUT" = "ok" ]; then
    echo ""
    echo "Command succeeded. Did the Touch ID dialog show 'Approve cookie purchase'?"
    read -p "Enter y/n: " ANSWER
    if [ "$ANSWER" = "y" ]; then
        echo "PASS: reason string displayed correctly"
    else
        echo "FAIL: reason string was not displayed"
        exit 1
    fi
else
    echo "FAIL: command failed with exit code=$EXIT_CODE"
    exit 1
fi
