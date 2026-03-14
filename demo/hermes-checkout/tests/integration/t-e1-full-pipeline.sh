#!/bin/bash
# T-E1: Full pipeline with expected decline
# Interactive: requires Hermes running with keypo toolset + daemon running
echo "=== T-E1: Full pipeline with expected decline ==="
echo ""
echo "MANUAL INTEGRATION TEST"
echo "Prerequisites:"
echo "  1. Daemon running: keypo-approvald --socket /tmp/keypo-approvald.sock --checkout-script ./checkout/checkout.js"
echo "  2. Hermes running with keypo toolset"
echo "  3. Vault seeded with fake card data (seed-vault.sh --test)"
echo ""
echo "Action: Tell Hermes 'Buy me [product] from shop.keypo.io'"
echo ""
echo "Expected flow:"
echo "  Hermes finds product → shows summary → user types 'yes' → Touch ID → checkout runs → Shopify declines fake card"
echo "  Hermes reports checkout error mentioning card decline. No order placed."
echo ""
echo "SKIP: manual integration test"
