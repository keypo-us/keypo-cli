# Checkout Demo

Vault-protected Shopify checkout. Credit card details are injected via `keypo-signer vault exec` (Touch ID required) — the agent never sees them.

## Skill

When the user asks to buy something, follow the instructions in [SKILL.md](SKILL.md).

## Vault safety rules

Follow the vault safety rules in [skills/keypo-signer/SKILL.md](../../skills/keypo-signer/SKILL.md) — especially:
- Never call `vault get` — use only `vault exec`
- Never write secrets to files
- Never populate the blank `CARD_*` fields in `.env.vault-template`
