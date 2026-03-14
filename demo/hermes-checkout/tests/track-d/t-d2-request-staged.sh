#!/bin/bash
# T-D2: Request returns staged with request_id
# Precondition: daemon running
set -uo pipefail

echo "=== T-D2: Request returns staged with request_id ==="
echo "Precondition: keypo-approvald must be running"

TOOL="$(cd "$(dirname "$0")/../../hermes/tools" && pwd)/keypo_approve.py"

RESULT=$(python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('keypo_approve', '$TOOL')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
result = mod.run(
    action='request',
    vault_label='biometric',
    bio_reason='T-D2 test',
    manifest={'product_url': 'https://shop.keypo.io/products/test', 'quantity': 1, 'max_price': 10.0}
)
print(json.dumps(result))
" 2>&1)

if echo "$RESULT" | grep -q '"status": "staged"' && echo "$RESULT" | grep -q 'request_id'; then
    echo "PASS: status=staged with request_id"
    # Cancel the staged request to clean up
    REQUEST_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_id'])")
    python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('keypo_approve', '$TOOL')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.run(action='cancel', request_id='$REQUEST_ID')
" 2>/dev/null
else
    echo "FAIL: $RESULT"
    exit 1
fi
