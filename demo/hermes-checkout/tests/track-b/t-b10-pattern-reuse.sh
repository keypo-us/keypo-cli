#!/bin/bash
# T-B10 — Inspect checkout.js for Shopify DOM patterns (selector names, iframe approach).
# Simple grep-based check to verify reuse of established Shopify checkout patterns.

echo "T-B10: checkout.js uses Shopify DOM patterns from checkout-demo"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$SCRIPT_DIR/../../checkout/checkout.js"

PASS=true

# Check for iframe card-filling pattern
if ! grep -q "typeInCardIframe" "$CHECKOUT"; then
  echo "  FAIL: missing typeInCardIframe helper (iframe card pattern from shopify.js)"
  PASS=false
fi

# Check for /cart/add.js fetch pattern
if ! grep -q "cart/add.js" "$CHECKOUT"; then
  echo "  FAIL: missing /cart/add.js fetch pattern"
  PASS=false
fi

# Check for Shopify DOM selectors (autocomplete-based, from shopify.js)
if ! grep -q 'autocomplete="email"' "$CHECKOUT"; then
  echo "  FAIL: missing email autocomplete selector"
  PASS=false
fi

if ! grep -q 'autocomplete="given-name"' "$CHECKOUT"; then
  echo "  FAIL: missing given-name autocomplete selector"
  PASS=false
fi

if ! grep -q 'autocomplete="family-name"' "$CHECKOUT"; then
  echo "  FAIL: missing family-name autocomplete selector"
  PASS=false
fi

if ! grep -q 'autocomplete="address-line1"' "$CHECKOUT"; then
  echo "  FAIL: missing address-line1 autocomplete selector"
  PASS=false
fi

if ! grep -q 'autocomplete="postal-code"' "$CHECKOUT"; then
  echo "  FAIL: missing postal-code autocomplete selector"
  PASS=false
fi

# Check for iframe-based card field filling (aria-label matching from shopify.js)
if ! grep -q 'aria-label.*Card number' "$CHECKOUT"; then
  echo "  FAIL: missing Card number aria-label selector"
  PASS=false
fi

if ! grep -q 'aria-label.*Security code' "$CHECKOUT"; then
  echo "  FAIL: missing Security code aria-label selector"
  PASS=false
fi

if ! grep -q 'aria-label.*Expiration date' "$CHECKOUT"; then
  echo "  FAIL: missing Expiration date aria-label selector"
  PASS=false
fi

# Check for Pay now button detection
if ! grep -q "Pay now" "$CHECKOUT"; then
  echo "  FAIL: missing Pay now button detection"
  PASS=false
fi

# Check for stealth plugin usage
if ! grep -q "puppeteer-extra-plugin-stealth" "$CHECKOUT"; then
  echo "  FAIL: missing stealth plugin"
  PASS=false
fi

# Check for ShopifyAnalytics usage (variant detection from shopify.js)
if ! grep -q "ShopifyAnalytics" "$CHECKOUT"; then
  echo "  FAIL: missing ShopifyAnalytics variant detection"
  PASS=false
fi

# Check for address autocomplete dropdown dismiss (Escape key, from shopify.js)
if ! grep -q "Escape" "$CHECKOUT"; then
  echo "  FAIL: missing Escape key for address autocomplete dismiss"
  PASS=false
fi

if [ "$PASS" = true ]; then
  echo "  PASS"
else
  echo "  FAIL"
fi
