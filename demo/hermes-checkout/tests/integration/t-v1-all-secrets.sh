#!/bin/bash
# T-V1: All secrets present via vault exec
# Interactive: requires Touch ID approval
set -uo pipefail

echo "=== T-V1: All secrets present via vault exec ==="
echo ">>> Touch ID prompt will appear — please APPROVE <<<"

OUTPUT=$(keypo-signer vault exec --label biometric --allow '*' -- env 2>/dev/null | grep -E '^(CARD_|SHIP_)' | sort)
COUNT=$(echo "$OUTPUT" | grep -c '.' || true)

echo "$OUTPUT"
echo ""

if [ "$COUNT" -eq 14 ]; then
    echo "PASS: all 14 env vars present"
else
    echo "FAIL: found $COUNT vars, expected 14"
    exit 1
fi
