#!/bin/bash
# T-B8 — Second price check catches shipping blowup.
# Product with known price ($1.00), max_price just above product but below product + shipping.
# Expect price check 1 passes, price check 2 fails with exit 2.

echo "T-B8: Shipping price check — max_price=1.50 on \$1.00 product should fail after shipping added"

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

# Keypo Logo Art is $1.00. Set max_price to $1.50 — above product, below product+shipping
MANIFEST='{"product_url":"https://shop.keypo.io/products/keypo-logo-art","quantity":1,"max_price":1.50}'

STDERR_FILE=$(mktemp)
echo "$MANIFEST" | node "$CHECKOUT" 2>"$STDERR_FILE"
EXIT_CODE=$?
STDERR_CONTENT=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"

PASS=true

if [ "$EXIT_CODE" -ne 2 ]; then
  echo "  FAIL: expected exit 2, got $EXIT_CODE"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

if ! echo "$STDERR_CONTENT" | grep -q "PRICE_CHECK_FAILED"; then
  echo "  FAIL: stderr missing PRICE_CHECK_FAILED"
  echo "  stderr: $STDERR_CONTENT"
  PASS=false
fi

# Verify price check 1 passed (status message)
if ! echo "$STDERR_CONTENT" | grep -q "Price check 1 passed"; then
  echo "  WARN: could not confirm price check 1 passed (may still be correct if total extraction differs)"
fi

if [ "$PASS" = true ]; then
  echo "  PASS"
else
  echo "  FAIL"
fi
