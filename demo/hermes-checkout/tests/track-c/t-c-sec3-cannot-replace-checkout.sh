#!/bin/bash
# T-C-sec3: Hermes cannot replace checkout.js
# Precondition: install-daemon.sh has been run
set -uo pipefail

echo "=== T-C-sec3: Hermes cannot replace checkout.js ==="

SCRIPT="/usr/local/libexec/keypo/checkout.js"
if [ ! -f "$SCRIPT" ]; then
    echo "SKIP: $SCRIPT not found (install-daemon.sh not set up)"
    exit 0
fi

echo "test" > "$SCRIPT" 2>&1
RESULT=$?

if [ $RESULT -ne 0 ]; then
    echo "PASS: write denied (Permission denied)"
else
    echo "FAIL: dave was able to overwrite checkout.js"
    exit 1
fi
