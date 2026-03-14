#!/bin/bash
# T-C2: Manifest arrives on child stdin
# Interactive: requires Touch ID approval
# Uses /bin/cat as checkout script to echo stdin to stdout
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C2: Manifest arrives on child stdin ==="
echo ">>> Touch ID prompt will appear — please APPROVE <<<"

start_daemon "/bin/cat"

# Stage with a manifest
RESP1=$(send_message '{"action":"request","request_id":"stdin-1","vault_label":"biometric","bio_reason":"T-C2 test","manifest":{"test":true}}')
if ! echo "$RESP1" | grep -q '"status":"staged"'; then
    echo "FAIL: request not staged: $RESP1"
    exit 1
fi

# Confirm — cat will read manifest from stdin and write to stdout
RESP2=$(send_message '{"action":"confirm","request_id":"stdin-1"}')

if echo "$RESP2" | grep -q '"test"'; then
    echo "PASS: manifest data appeared in stdout"
else
    echo "FAIL: manifest not in stdout: $RESP2"
    exit 1
fi
