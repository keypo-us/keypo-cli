#!/bin/bash
# T-C4: Double stage rejected
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C4: Double stage rejected ==="

start_daemon "/bin/echo"

# Stage first request
RESP1=$(send_message '{"action":"request","request_id":"req-1","vault_label":"biometric","bio_reason":"Test","manifest":{"test":true}}')
if ! echo "$RESP1" | grep -q '"status":"staged"'; then
    echo "FAIL: first request not staged: $RESP1"
    exit 1
fi

# Stage second request without confirming first
RESP2=$(send_message '{"action":"request","request_id":"req-2","vault_label":"biometric","bio_reason":"Test","manifest":{"test":true}}')

if echo "$RESP2" | grep -q '"status":"error"' && echo "$RESP2" | grep -q 'already staged'; then
    echo "PASS: second request rejected with 'already staged'"
else
    echo "FAIL: unexpected response: $RESP2"
    exit 1
fi
