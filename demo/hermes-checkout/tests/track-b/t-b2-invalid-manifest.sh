#!/bin/bash
# T-B2 — Invalid manifest from stdin.
# Pipe {} to stdin with all env vars set. Expect exit 5, stderr "CONFIG_ERROR".

echo "T-B2: Invalid manifest (empty object) should produce CONFIG_ERROR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$SCRIPT_DIR/../../checkout/checkout.js"

# Set all required env vars
export CARD_NUMBER="4242424242424242"
export CARD_EXP_MONTH="12"
export CARD_EXP_YEAR="29"
export CARD_CVV="123"
export CARD_NAME="Test User"
export SHIP_FIRST_NAME="Test"
export SHIP_LAST_NAME="User"
export SHIP_ADDRESS1="123 Test St"
export SHIP_CITY="Glendale"
export SHIP_STATE="CA"
export SHIP_ZIP="91201"
export SHIP_COUNTRY="US"
export SHIP_PHONE="8185551234"

STDERR_FILE=$(mktemp)
echo '{}' | node "$CHECKOUT" 2>"$STDERR_FILE"
EXIT_CODE=$?
STDERR_CONTENT=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"

PASS=true

if [ "$EXIT_CODE" -ne 5 ]; then
  echo "  FAIL: expected exit 5, got $EXIT_CODE"
  PASS=false
fi

if ! echo "$STDERR_CONTENT" | grep -q "CONFIG_ERROR"; then
  echo "  FAIL: stderr missing CONFIG_ERROR"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "  PASS"
else
  echo "  FAIL"
fi
