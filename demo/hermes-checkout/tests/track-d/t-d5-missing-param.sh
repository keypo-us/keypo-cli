#!/bin/bash
# T-D5: Missing required param rejected before socket call
set -uo pipefail

echo "=== T-D5: Missing param rejected before socket call ==="

TOOL="$(cd "$(dirname "$0")/../../hermes/tools" && pwd)/keypo_approve.py"

RESULT=$(python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('keypo_approve', '$TOOL')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
result = mod.run(action='request')  # missing vault_label, bio_reason, manifest
print(json.dumps(result))
" 2>&1)

if echo "$RESULT" | grep -q '"status": "error"' && echo "$RESULT" | grep -q 'vault_label'; then
    echo "PASS: rejected with missing vault_label error"
else
    echo "FAIL: unexpected result: $RESULT"
    exit 1
fi
