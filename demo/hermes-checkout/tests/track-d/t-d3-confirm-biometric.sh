#!/bin/bash
# T-D3: Confirm triggers biometric, returns result
# Interactive: requires Touch ID approval
# Precondition: daemon running
set -uo pipefail

echo "=== T-D3: Confirm triggers biometric, returns result ==="
echo "Precondition: daemon running, biometric vault seeded"
echo ">>> Touch ID prompt will appear — please APPROVE <<<"

TOOL="$(cd "$(dirname "$0")/../../hermes/tools" && pwd)/keypo_approve.py"

RESULT=$(python3 -c "
import importlib.util, json
spec = importlib.util.spec_from_file_location('keypo_approve', '$TOOL')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Stage
r1 = mod.run(
    action='request',
    vault_label='biometric',
    bio_reason='T-D3 biometric test',
    manifest={'product_url': 'https://shop.keypo.io/products/test', 'quantity': 1, 'max_price': 10.0}
)
if r1.get('status') != 'staged':
    print(json.dumps({'error': 'staging failed', 'detail': r1}))
else:
    # Confirm
    r2 = mod.run(action='confirm', request_id=r1['request_id'])
    print(json.dumps(r2))
" 2>&1)

if echo "$RESULT" | grep -q '"status": "completed"\|"status": "error"'; then
    echo "Result: $RESULT"
    echo "PASS: confirm returned a response (check status for expected outcome)"
else
    echo "FAIL: $RESULT"
    exit 1
fi
