#!/bin/bash
# T-V2: No secret name collisions across vaults
set -uo pipefail

echo "=== T-V2: No secret name collisions across vaults ==="

# List all secrets and check for duplicates across vaults
OUTPUT=$(keypo-signer vault list --format json 2>/dev/null)

DUPES=$(echo "$OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
names = {}
for vault in data.get('vaults', []):
    label = vault.get('label', '')
    for secret in vault.get('secrets', []):
        name = secret.get('name', '')
        if name in names:
            print(f'DUPLICATE: {name} in {names[name]} and {label}')
        names[name] = label
" 2>&1)

if [ -z "$DUPES" ]; then
    echo "PASS: no duplicate secret names across vaults"
else
    echo "FAIL: found duplicates:"
    echo "$DUPES"
    exit 1
fi
