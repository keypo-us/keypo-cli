#!/bin/bash
# T-C7: Staged request expires after 5 minutes
# NOTE: This test takes 5+ minutes to run
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C7: Staged request expires after 5 minutes ==="
echo "WARNING: This test takes 5+ minutes. Press Ctrl-C to skip."
echo ""

start_daemon "/bin/echo"

# Stage
RESP1=$(send_message '{"action":"request","request_id":"expiry-1","vault_label":"biometric","bio_reason":"Test","manifest":{"test":true}}')
if ! echo "$RESP1" | grep -q '"status":"staged"'; then
    echo "FAIL: request not staged: $RESP1"
    exit 1
fi

echo "Waiting 305 seconds for request to expire..."
sleep 305

# Try to confirm — should be expired
RESP2=$(send_message '{"action":"confirm","request_id":"expiry-1"}')

if echo "$RESP2" | grep -q '"status":"error"' && echo "$RESP2" | grep -q 'expired'; then
    echo "PASS: request expired after 5 minutes"
else
    echo "FAIL: unexpected response: $RESP2"
    exit 1
fi
