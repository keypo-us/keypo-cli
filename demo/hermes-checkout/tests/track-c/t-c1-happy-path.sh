#!/bin/bash
# T-C1: Stage-then-confirm happy path
# Interactive: requires Touch ID approval
# Precondition: biometric vault has TEST_VAR=works, daemon checkout-script prints it
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C1: Stage-then-confirm happy path ==="
echo "Precondition: biometric vault must contain TEST_VAR=works"
echo ">>> Touch ID prompt will appear — please APPROVE <<<"

# Create a test script that runs printenv TEST_VAR
TEST_SCRIPT=$(mktemp /tmp/keypo-test-XXXXXX.sh)
cat > "$TEST_SCRIPT" << 'SCRIPT'
#!/bin/bash
printenv TEST_VAR
SCRIPT
chmod +x "$TEST_SCRIPT"

start_daemon "$TEST_SCRIPT"

# Stage
RESP1=$(send_message '{"action":"request","request_id":"happy-1","vault_label":"biometric","bio_reason":"T-C1 test","manifest":{"test":true}}')
if ! echo "$RESP1" | grep -q '"status":"staged"'; then
    echo "FAIL: request not staged: $RESP1"
    rm -f "$TEST_SCRIPT"
    exit 1
fi

# Confirm (triggers vault exec + biometric)
RESP2=$(send_message '{"action":"confirm","request_id":"happy-1"}')
rm -f "$TEST_SCRIPT"

if echo "$RESP2" | grep -q '"status":"completed"' && echo "$RESP2" | grep -q 'works'; then
    echo "PASS: status=completed, stdout contains 'works'"
else
    echo "FAIL: unexpected response: $RESP2"
    exit 1
fi
