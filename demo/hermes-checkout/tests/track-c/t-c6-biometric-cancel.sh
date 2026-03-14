#!/bin/bash
# T-C6: Biometric cancel returns error, command never runs
# Interactive: requires Touch ID CANCELLATION
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C6: Biometric cancel returns error ==="
echo ">>> Touch ID prompt will appear — please CANCEL <<<"

# Use a script that creates a marker file — if it runs, the test fails
MARKER=$(mktemp /tmp/keypo-marker-XXXXXX)
rm -f "$MARKER"
TEST_SCRIPT=$(mktemp /tmp/keypo-test-XXXXXX.sh)
cat > "$TEST_SCRIPT" << SCRIPT
#!/bin/bash
touch "$MARKER"
cat
SCRIPT
chmod +x "$TEST_SCRIPT"

start_daemon "$TEST_SCRIPT"

RESP1=$(send_message '{"action":"request","request_id":"cancel-1","vault_label":"biometric","bio_reason":"T-C6 cancel test","manifest":{"test":true}}')
RESP2=$(send_message '{"action":"confirm","request_id":"cancel-1"}')

rm -f "$TEST_SCRIPT"

if echo "$RESP2" | grep -q '"status":"error"' && echo "$RESP2" | grep -qi 'cancelled'; then
    if [ -f "$MARKER" ]; then
        echo "FAIL: checkout script ran despite biometric cancellation"
        rm -f "$MARKER"
        exit 1
    fi
    echo "PASS: error with 'cancelled', checkout script never ran"
else
    echo "FAIL: unexpected response: $RESP2"
    rm -f "$MARKER"
    exit 1
fi
