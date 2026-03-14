#!/bin/bash
# T-C-sec6: Sudoers allowlist enforced
# Precondition: install-daemon.sh run, running as _keypo user
set -uo pipefail

echo "=== T-C-sec6: Sudoers allowlist enforced ==="
echo "This test must be run as _keypo user"
echo "Run: sudo -u _keypo bash $0"

CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "_keypo" ]; then
    echo "SKIP: not running as _keypo (current: $CURRENT_USER)"
    exit 0
fi

# Try to run an unauthorized command as dave
sudo -u dave keypo-signer vault exec --label biometric -- /bin/bash -c "echo pwned" 2>&1
RESULT=$?

if [ $RESULT -ne 0 ]; then
    echo "PASS: sudoers rejected unauthorized command"
else
    echo "FAIL: _keypo was able to run unauthorized command as dave"
    exit 1
fi
