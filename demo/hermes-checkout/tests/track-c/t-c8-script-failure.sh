#!/bin/bash
# T-C8: Checkout script failure propagated
# Interactive: requires Touch ID approval
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C8: Checkout script failure propagated ==="
echo ">>> Touch ID prompt will appear — please APPROVE <<<"

# Create a script that fails with exit code 2 and writes to stderr
TEST_SCRIPT=$(mktemp /tmp/keypo-test-XXXXXX.sh)
cat > "$TEST_SCRIPT" << 'SCRIPT'
#!/bin/bash
echo "PRICE_CHECK_FAILED: cart $50.00 exceeds max $10.00" >&2
exit 2
SCRIPT
chmod +x "$TEST_SCRIPT"

start_daemon "$TEST_SCRIPT"

RESP1=$(send_message '{"action":"request","request_id":"fail-1","vault_label":"biometric","bio_reason":"T-C8 test","manifest":{"test":true}}')
RESP2=$(send_message '{"action":"confirm","request_id":"fail-1"}')
rm -f "$TEST_SCRIPT"

if echo "$RESP2" | grep -q '"status":"error"' && echo "$RESP2" | grep -q '"exit_code":2'; then
    echo "PASS: failure propagated with exit_code=2"
else
    echo "FAIL: unexpected response: $RESP2"
    exit 1
fi
