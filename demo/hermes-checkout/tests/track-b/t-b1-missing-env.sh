#!/bin/bash
# T-B1 — Missing env var caught before browser launch.
# Set all env vars except CARD_CVV. Pipe valid manifest. Expect exit 5, stderr contains "CONFIG_ERROR" and "CARD_CVV".
# Must complete in < 2 seconds.

echo "T-B1: Missing env var (CARD_CVV) should produce CONFIG_ERROR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$SCRIPT_DIR/../../checkout/checkout.js"

# Set all required env vars EXCEPT CARD_CVV
export CARD_NUMBER="4242424242424242"
export CARD_EXP_MONTH="12"
export CARD_EXP_YEAR="29"
unset CARD_CVV 2>/dev/null || true
export CARD_NAME="Test User"
export SHIP_FIRST_NAME="Test"
export SHIP_LAST_NAME="User"
export SHIP_ADDRESS1="123 Test St"
export SHIP_CITY="Glendale"
export SHIP_STATE="CA"
export SHIP_ZIP="91201"
export SHIP_COUNTRY="US"
export SHIP_PHONE="8185551234"

MANIFEST='{"product_url":"https://shop.keypo.io/products/keypo-logo-art","quantity":1,"max_price":50.00}'

STDERR_FILE=$(mktemp)
echo "$MANIFEST" | node "$CHECKOUT" 2>"$STDERR_FILE"
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

if ! echo "$STDERR_CONTENT" | grep -q "CARD_CVV"; then
  echo "  FAIL: stderr missing CARD_CVV"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "  PASS"
else
  echo "  FAIL"
fi
