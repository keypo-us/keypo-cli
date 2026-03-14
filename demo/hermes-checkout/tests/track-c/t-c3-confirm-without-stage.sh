#!/bin/bash
# T-C3: Confirm without prior stage
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C3: Confirm without prior stage ==="

# Use /bin/echo as a simple checkout script (won't actually run)
start_daemon "/bin/echo"

RESPONSE=$(send_message '{"action":"confirm","request_id":"nonexistent-id"}')

if echo "$RESPONSE" | grep -q '"status":"error"' && echo "$RESPONSE" | grep -q 'no staged request'; then
    echo "PASS: got error with 'no staged request'"
else
    echo "FAIL: unexpected response: $RESPONSE"
    exit 1
fi
