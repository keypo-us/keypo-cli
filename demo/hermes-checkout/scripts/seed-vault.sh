#!/bin/bash
# Seed the biometric vault with card and shipping secrets for the checkout demo.
# Usage:
#   ./seed-vault.sh          # Interactive: prompts for all values
#   ./seed-vault.sh --test   # Pre-fills fake card data, prompts for shipping only
set -euo pipefail

VAULT_LABEL="biometric"

set_secret() {
    local name="$1"
    local value="$2"
    if [ -z "$value" ]; then
        echo "  ⊘ $name (skipped, empty)"
        return
    fi
    echo -n "$value" | keypo-signer vault set "$name" --vault "$VAULT_LABEL" --stdin
    echo "  ✓ $name"
}

prompt_secret() {
    local name="$1"
    local prompt="$2"
    local default="${3:-}"
    if [ -n "$default" ]; then
        read -p "  $prompt [$default]: " value
        value="${value:-$default}"
    else
        read -p "  $prompt: " value
    fi
    set_secret "$name" "$value"
}

echo "=== Keypo Vault Seeder ==="
echo ""

if [ "${1:-}" = "--test" ]; then
    echo "Mode: TEST (fake card data)"
    echo ""
    echo "Setting card secrets (fake data)..."
    set_secret "CARD_NUMBER" "4242424242424242"
    set_secret "CARD_EXP_MONTH" "12"
    set_secret "CARD_EXP_YEAR" "29"
    set_secret "CARD_CVV" "123"
    set_secret "CARD_NAME" "Test User"
    echo ""
    echo "Enter shipping address:"
    prompt_secret "SHIP_FIRST_NAME" "First name" "Test"
    prompt_secret "SHIP_LAST_NAME" "Last name" "User"
    prompt_secret "SHIP_ADDRESS1" "Address line 1" "123 Test St"
    prompt_secret "SHIP_ADDRESS2" "Address line 2 (optional)" ""
    prompt_secret "SHIP_CITY" "City" "Glendale"
    prompt_secret "SHIP_STATE" "State code" "CA"
    prompt_secret "SHIP_ZIP" "Zip code" "91201"
    prompt_secret "SHIP_COUNTRY" "Country code" "US"
    prompt_secret "SHIP_PHONE" "Phone number" "8185551234"
else
    echo "Mode: INTERACTIVE (real data)"
    echo "WARNING: You are entering real payment credentials."
    echo ""
    echo "Enter card details:"
    prompt_secret "CARD_NUMBER" "Card number"
    prompt_secret "CARD_EXP_MONTH" "Expiry month (2-digit)"
    prompt_secret "CARD_EXP_YEAR" "Expiry year (2 or 4-digit)"
    prompt_secret "CARD_CVV" "CVV"
    prompt_secret "CARD_NAME" "Cardholder name"
    echo ""
    echo "Enter shipping address:"
    prompt_secret "SHIP_FIRST_NAME" "First name"
    prompt_secret "SHIP_LAST_NAME" "Last name"
    prompt_secret "SHIP_ADDRESS1" "Address line 1"
    prompt_secret "SHIP_ADDRESS2" "Address line 2 (optional)" ""
    prompt_secret "SHIP_CITY" "City"
    prompt_secret "SHIP_STATE" "State/province code"
    prompt_secret "SHIP_ZIP" "Postal code"
    prompt_secret "SHIP_COUNTRY" "Country code"
    prompt_secret "SHIP_PHONE" "Phone number"
fi

echo ""
echo "Done! All secrets stored in '$VAULT_LABEL' vault."
echo "Verify with: keypo-signer vault exec --label $VAULT_LABEL --allow '*' -- env | grep -E '^(CARD_|SHIP_)'"
