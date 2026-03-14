#!/bin/bash
# Shared helpers for Track C daemon tests

SOCKET_PATH="/tmp/keypo-approvald-test.sock"
DAEMON_PID=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
APPROVALD="$REPO_ROOT/demo/hermes-checkout/approvald/.build/debug/keypo-approvald"

# Start daemon with a test checkout script
start_daemon() {
    local checkout_script="${1:-/bin/cat}"
    rm -f "$SOCKET_PATH"
    "$APPROVALD" --socket "$SOCKET_PATH" --checkout-script "$checkout_script" 2>/dev/null &
    DAEMON_PID=$!
    # Wait for socket to appear
    for i in $(seq 1 20); do
        [ -S "$SOCKET_PATH" ] && break
        sleep 0.1
    done
    if [ ! -S "$SOCKET_PATH" ]; then
        echo "ERROR: daemon did not create socket within 2 seconds"
        exit 1
    fi
}

# Stop daemon
stop_daemon() {
    if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill "$DAEMON_PID" 2>/dev/null
        wait "$DAEMON_PID" 2>/dev/null
    fi
    DAEMON_PID=""
    rm -f "$SOCKET_PATH"
}

# Send a JSON message to the daemon and read response via Python
send_message() {
    local json="$1"
    python3 -c "
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect('$SOCKET_PATH')
sock.sendall(('''$json''' + '\n').encode())
data = b''
while True:
    chunk = sock.recv(65536)
    if not chunk:
        break
    data += chunk
    if b'\n' in data:
        break
sock.close()
print(data.decode().strip())
"
}

# Cleanup on exit
cleanup() {
    stop_daemon
}
trap cleanup EXIT
