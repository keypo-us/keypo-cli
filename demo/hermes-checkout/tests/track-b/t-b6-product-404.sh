#!/bin/bash
# T-B6 — Product 404.
# Manifest with nonexistent product. Expect exit 3, stderr "PRODUCT_ERROR".

echo "T-B6: Nonexistent product should produce PRODUCT_ERROR"

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

MANIFEST='{"product_url":"https://shop.keypo.io/products/does-not-exist","quantity":1,"max_price":50.00}'

STDERR_FILE=$(mktemp)
echo "$MANIFEST" | node "$CHECKOUT" 2>"$STDERR_FILE"
EXIT_CODE=$?
STDERR_CONTENT=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"

PASS=true

if [ "$EXIT_CODE" -ne 3 ]; then
  echo "  FAIL: expected exit 3, got $EXIT_CODE"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

if ! echo "$STDERR_CONTENT" | grep -q "PRODUCT_ERROR"; then
  echo "  FAIL: stderr missing PRODUCT_ERROR"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "  PASS"
else
  echo "  FAIL"
fi
