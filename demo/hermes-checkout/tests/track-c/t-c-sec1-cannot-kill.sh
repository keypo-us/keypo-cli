#!/bin/bash
# T-C-sec1: Hermes (dave) cannot kill the daemon
# Precondition: install-daemon.sh has been run, daemon running as _keypo
set -uo pipefail

echo "=== T-C-sec1: Hermes cannot kill daemon ==="
echo "Precondition: daemon must be running as _keypo user"

DAEMON_PID=$(pgrep -u _keypo keypo-approvald 2>/dev/null)
if [ -z "$DAEMON_PID" ]; then
    echo "SKIP: daemon not running as _keypo (install-daemon.sh not set up)"
    exit 0
fi

kill "$DAEMON_PID" 2>&1
RESULT=$?

if [ $RESULT -ne 0 ]; then
    echo "PASS: kill failed (Operation not permitted)"
else
    # Check if daemon is still running
    if kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "FAIL: kill returned 0 but daemon still running (unexpected)"
    else
        echo "FAIL: dave was able to kill the _keypo daemon"
        exit 1
    fi
fi
