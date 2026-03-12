#!/bin/bash
set -euo pipefail

TASK_ID="${1:?Usage: run-with-vault.sh <TASK_ID> [CARD_FRIENDLY_NAME]}"
export TASK_ID
[ -n "${2:-}" ] && export CARD_FRIENDLY_NAME="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR/bot"
exec keypo-signer vault exec \
  --env "$SCRIPT_DIR/.env.vault-template" \
  -- node ./scripts/start-task.js
