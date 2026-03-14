#!/bin/bash
# T-C-sec2: Hermes cannot replace the daemon binary
# Precondition: install-daemon.sh has been run
set -uo pipefail

echo "=== T-C-sec2: Hermes cannot replace daemon binary ==="

BINARY="/usr/local/libexec/keypo/keypo-approvald"
if [ ! -f "$BINARY" ]; then
    echo "SKIP: $BINARY not found (install-daemon.sh not set up)"
    exit 0
fi

echo "test" > "$BINARY" 2>&1
RESULT=$?

if [ $RESULT -ne 0 ]; then
    echo "PASS: write denied (Permission denied)"
else
    echo "FAIL: dave was able to overwrite the daemon binary"
    exit 1
fi
