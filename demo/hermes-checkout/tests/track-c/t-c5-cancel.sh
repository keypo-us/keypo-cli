#!/bin/bash
# T-C5: Cancel clears staged request
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C5: Cancel clears staged request ==="

start_daemon "/bin/echo"

# Stage
RESP1=$(send_message '{"action":"request","request_id":"req-cancel","vault_label":"biometric","bio_reason":"Test","manifest":{"test":true}}')
if ! echo "$RESP1" | grep -q '"status":"staged"'; then
    echo "FAIL: request not staged: $RESP1"
    exit 1
fi

# Cancel
RESP2=$(send_message '{"action":"cancel","request_id":"req-cancel"}')
if ! echo "$RESP2" | grep -q '"status":"cancelled"'; then
    echo "FAIL: cancel did not return 'cancelled': $RESP2"
    exit 1
fi

# Confirm should now fail
RESP3=$(send_message '{"action":"confirm","request_id":"req-cancel"}')
if echo "$RESP3" | grep -q 'no staged request'; then
    echo "PASS: cancel cleared staged request, confirm returns 'no staged request'"
else
    echo "FAIL: unexpected response after cancel: $RESP3"
    exit 1
fi
