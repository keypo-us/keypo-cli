#!/bin/bash
# T-C9: Socket cleaned up on shutdown
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo "=== T-C9: Socket cleaned up on shutdown ==="

# Don't use the helper trap — we manage cleanup manually here
trap - EXIT

start_daemon "/bin/echo"

# Verify socket exists
if [ ! -S "$SOCKET_PATH" ]; then
    echo "FAIL: socket not created at $SOCKET_PATH"
    stop_daemon
    exit 1
fi

# Send SIGTERM
kill "$DAEMON_PID" 2>/dev/null
wait "$DAEMON_PID" 2>/dev/null
EXIT_CODE=$?

sleep 0.5

if [ -S "$SOCKET_PATH" ]; then
    echo "FAIL: socket still exists after SIGTERM"
    rm -f "$SOCKET_PATH"
    exit 1
fi

echo "PASS: socket removed after SIGTERM"
