#!/bin/bash
# T-B5 — Full pipeline with expected card decline.
# All env vars with fake card (4242424242424242), real product on shop.keypo.io, generous max_price.
# Expect exit 4 (card decline = success!).

echo "T-B5: Full pipeline with fake card — expect CHECKOUT_ERROR (card decline)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$SCRIPT_DIR/../../checkout/checkout.js"

# Set all required env vars with fake card data
export CARD_NUMBER="4242424242424242"
export CARD_EXP_MONTH="12"
export CARD_EXP_YEAR="29"
export CARD_CVV="123"
export CARD_NAME="Test User"
export SHIP_FIRST_NAME="Test"
export SHIP_LAST_NAME="User"
export SHIP_ADDRESS1="123 Test St"
export SHIP_ADDRESS2=""
export SHIP_CITY="Glendale"
export SHIP_STATE="CA"
export SHIP_ZIP="91201"
export SHIP_COUNTRY="US"
export SHIP_PHONE="8185551234"

# Keypo Logo Art is $1.00 — set max_price generously
MANIFEST='{"product_url":"https://shop.keypo.io/products/keypo-logo-art","quantity":1,"max_price":50.00}'

STDERR_FILE=$(mktemp)
STDOUT_FILE=$(mktemp)
echo "$MANIFEST" | node "$CHECKOUT" >"$STDOUT_FILE" 2>"$STDERR_FILE"
EXIT_CODE=$?
STDERR_CONTENT=$(cat "$STDERR_FILE")
STDOUT_CONTENT=$(cat "$STDOUT_FILE")
rm -f "$STDERR_FILE" "$STDOUT_FILE"

PASS=true

if [ "$EXIT_CODE" -ne 4 ]; then
  echo "  FAIL: expected exit 4, got $EXIT_CODE"
  echo "  stdout: $STDOUT_CONTENT"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

if ! echo "$STDERR_CONTENT" | grep -q "CHECKOUT_ERROR"; then
  echo "  FAIL: stderr missing CHECKOUT_ERROR"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "  PASS"
else
  echo "  FAIL"
fi
