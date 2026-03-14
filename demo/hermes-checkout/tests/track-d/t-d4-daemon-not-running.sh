#!/bin/bash
# T-D4: Daemon not running returns actionable error
set -uo pipefail

echo "=== T-D4: Daemon not running returns actionable error ==="

TOOL="$(cd "$(dirname "$0")/../../hermes/tools" && pwd)/keypo_approve.py"

# Use a socket path that doesn't exist
export KEYPO_DAEMON_SOCKET="/tmp/keypo-nonexistent-test.sock"

RESULT=$(python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('keypo_approve', '$TOOL')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
result = mod.run(action='request', vault_label='biometric', bio_reason='test', manifest={'test': True})
print(json.dumps(result))
" 2>&1)

if echo "$RESULT" | grep -q '"status": "error"' && echo "$RESULT" | grep -qi 'not found\|running'; then
    echo "PASS: got error mentioning socket not found / daemon not running"
else
    echo "FAIL: unexpected result: $RESULT"
    exit 1
fi
