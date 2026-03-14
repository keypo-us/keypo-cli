#!/bin/bash
# T-D6: Hermes follows procedure on buy request
# This is a manual test — verify Hermes behavior interactively
echo "=== T-D6: Hermes follows procedure on buy request ==="
echo ""
echo "MANUAL TEST — run in Hermes with keypo toolset enabled:"
echo '  "Buy me a dozen cookies from Levain Bakery."'
echo ""
echo "Expected behavior:"
echo "  1. Hermes searches for the product"
echo "  2. Hermes finds it on a Shopify store"
echo "  3. Hermes states the price"
echo "  4. Hermes proposes a max_price (price + 15%)"
echo "  5. Hermes asks for confirmation BEFORE any tool calls"
echo ""
echo "SKIP: manual Hermes test"
