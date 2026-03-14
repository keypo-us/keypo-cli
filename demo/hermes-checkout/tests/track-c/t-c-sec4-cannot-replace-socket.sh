#!/bin/bash
# T-C-sec4: Hermes cannot replace the socket
# Precondition: install-daemon.sh has been run
set -uo pipefail

echo "=== T-C-sec4: Hermes cannot replace socket ==="

SOCK="/var/run/keypo/keypo-approvald.sock"
if [ ! -S "$SOCK" ]; then
    echo "SKIP: $SOCK not found (install-daemon.sh not set up)"
    exit 0
fi

rm "$SOCK" 2>&1
RESULT=$?

if [ $RESULT -ne 0 ]; then
    echo "PASS: rm denied (Permission denied)"
else
    echo "FAIL: dave was able to delete the socket"
    exit 1
fi
