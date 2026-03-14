#!/bin/bash
# T-C-sec5: Daemon vault exec still triggers biometric as dave
# Precondition: install-daemon.sh run, daemon as _keypo, dave logged in
# Interactive: requires Touch ID approval
set -uo pipefail

echo "=== T-C-sec5: Daemon vault exec triggers biometric as dave ==="
echo "Precondition: daemon running as _keypo, dave logged in"
echo ">>> Touch ID prompt will appear — please APPROVE <<<"

SOCK="/var/run/keypo/keypo-approvald.sock"
if [ ! -S "$SOCK" ]; then
    echo "SKIP: production socket not found (install-daemon.sh not set up)"
    exit 0
fi

RESP=$(echo '{"action":"request","request_id":"sec5","vault_label":"biometric","bio_reason":"Security test","manifest":{"test":true}}' | nc -U "$SOCK")
if ! echo "$RESP" | grep -q '"status":"staged"'; then
    echo "FAIL: request not staged: $RESP"
    exit 1
fi

RESP2=$(echo '{"action":"confirm","request_id":"sec5"}' | nc -U "$SOCK")
if echo "$RESP2" | grep -q '"status":"completed"'; then
    echo "PASS: biometric auth worked through UID isolation"
else
    echo "FAIL: $RESP2"
    exit 1
fi
