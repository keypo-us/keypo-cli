#!/bin/bash
# T-C10: No temp manifest files on disk
# Interactive: requires Touch ID approval
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C10: No temp manifest files on disk ==="
echo ">>> Touch ID prompt will appear — please APPROVE <<<"

start_daemon "/bin/cat"

# Note any existing keypo-manifest files
BEFORE=$(ls /tmp/keypo-manifest-* 2>/dev/null | wc -l)

RESP1=$(send_message '{"action":"request","request_id":"temp-1","vault_label":"biometric","bio_reason":"T-C10 test","manifest":{"sensitive":"data"}}')
RESP2=$(send_message '{"action":"confirm","request_id":"temp-1"}')

AFTER=$(ls /tmp/keypo-manifest-* 2>/dev/null | wc -l)

if [ "$AFTER" -eq "$BEFORE" ]; then
    echo "PASS: no temp manifest files created"
else
    echo "FAIL: found new temp manifest files in /tmp/"
    ls /tmp/keypo-manifest-* 2>/dev/null
    exit 1
fi
