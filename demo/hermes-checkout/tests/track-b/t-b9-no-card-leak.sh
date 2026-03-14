#!/bin/bash
# T-B9 — Card data never appears in stdout or stderr.
# Run the full pipeline (same as T-B5), capture both streams, grep for card number, CVV, full expiry.
# Expect no matches.

echo "T-B9: Card data must not appear in stdout or stderr"

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

MANIFEST='{"product_url":"https://shop.keypo.io/products/keypo-logo-art","quantity":1,"max_price":50.00}'

STDERR_FILE=$(mktemp)
STDOUT_FILE=$(mktemp)
echo "$MANIFEST" | node "$CHECKOUT" >"$STDOUT_FILE" 2>"$STDERR_FILE"
# We don't care about exit code for this test

COMBINED=$(cat "$STDOUT_FILE" "$STDERR_FILE")
rm -f "$STDERR_FILE" "$STDOUT_FILE"

PASS=true

# Check for card number (full 16 digits)
if echo "$COMBINED" | grep -q "4242424242424242"; then
  echo "  FAIL: card number found in output"
  PASS=false
fi

# Check for CVV
# Use word-boundary-like check to avoid false positives on line numbers etc.
# CVV "123" is short, so check it doesn't appear as a standalone value after "CVV" or "cvv" or "security"
if echo "$COMBINED" | grep -qi "cvv.*123\|security.*code.*123"; then
  echo "  FAIL: CVV found in output near security/CVV context"
  PASS=false
fi

# Check for full expiry (12/29 or 1229)
if echo "$COMBINED" | grep -q "12/29\|1229"; then
  echo "  FAIL: full card expiry found in output"
  PASS=false
fi

# Check card name doesn't appear in card-related context
if echo "$COMBINED" | grep -qi "card.*name.*Test User\|name.*on.*card.*Test User"; then
  echo "  FAIL: card name found in card context in output"
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "  PASS"
else
  echo "  FAIL"
fi
