#!/bin/bash
# T-A5: Multiple secrets, single biometric prompt
# Precondition: biometric vault contains CARD_NUMBER, CARD_EXP_MONTH, CARD_CVV (or similar)
# Interactive: requires Touch ID approval — should only prompt ONCE
set -uo pipefail

echo "=== T-A5: Multiple secrets, single biometric prompt ==="
echo "Precondition: biometric vault must contain CARD_NUMBER, CARD_EXP_MONTH, CARD_CVV"
echo "Action: vault exec with all three secrets"
echo ">>> Touch ID should prompt ONCE — please APPROVE <<<"
echo ">>> If prompted more than once, this test FAILS <<<"
echo ""

STDERR_FILE=$(mktemp)
OUTPUT=$(keypo-signer vault exec --label biometric --allow 'CARD_NUMBER,CARD_EXP_MONTH,CARD_CVV' -- env 2>"$STDERR_FILE" | grep -E '^CARD_')
EXIT_CODE=${PIPESTATUS[0]}
rm -f "$STDERR_FILE"

COUNT=$(echo "$OUTPUT" | grep -c 'CARD_' || true)

if [ "$EXIT_CODE" -eq 0 ] && [ "$COUNT" -eq 3 ]; then
    echo "PASS: all 3 CARD_ vars present with single prompt"
    echo "$OUTPUT"
    echo ""
    read -p "Were you prompted for Touch ID only ONCE? (y/n): " ANSWER
    if [ "$ANSWER" = "y" ]; then
        echo "PASS: single biometric prompt confirmed"
    else
        echo "FAIL: multiple biometric prompts"
        exit 1
    fi
else
    echo "FAIL: exit code=$EXIT_CODE, found $COUNT CARD_ vars (expected 3)"
    exit 1
fi
