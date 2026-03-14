#!/bin/bash
# T-D1: Tool listed in Hermes
# Verifies the keypo_approve tool module is importable and has required attributes
set -uo pipefail

echo "=== T-D1: Tool listed / importable ==="

TOOL="$(cd "$(dirname "$0")/../../hermes/tools" && pwd)/keypo_approve.py"

python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('keypo_approve', '$TOOL')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert hasattr(mod, 'TOOL_NAME'), 'Missing TOOL_NAME'
assert hasattr(mod, 'TOOL_DESCRIPTION'), 'Missing TOOL_DESCRIPTION'
assert hasattr(mod, 'TOOL_PARAMETERS'), 'Missing TOOL_PARAMETERS'
assert hasattr(mod, 'run'), 'Missing run function'
print('PASS: keypo_approve module loads with all required attributes')
" 2>&1

if [ $? -ne 0 ]; then
    echo "FAIL"
    exit 1
fi
