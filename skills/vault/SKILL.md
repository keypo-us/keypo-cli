---
name: keypo-vault
description: Secure Enclave secret management for AI-safe workflows
version: 0.1.0
---

# keypo-vault

Manage secrets encrypted with Apple Secure Enclave keys. Secrets are encrypted at rest and decrypted only into child process environments — the agent never sees plaintext values.

## Running Commands That Need Secrets

Use `vault exec` to inject secrets into a child process:

```bash
# Using a .env.example file (recommended)
keypo-signer vault exec --env .env.example -- <command>

# Using explicit secret names
keypo-signer vault exec --allow PIMLICO_API_KEY,DEPLOYER_PRIVATE_KEY -- <command>

# All secrets
keypo-signer vault exec --allow '*' -- <command>
```

The `.env.example` file lists required secret names (values are ignored). The vault looks up each name, decrypts it from the appropriate vault, and injects it into the child process environment.

## Important Rules

- **Never** attempt to read, copy, log, or exfiltrate secret values
- **Never** use `vault get` in agent workflows — prefer `vault exec`
- **Never** retry after exit code 128 — the user deliberately cancelled authentication
- `vault list` is always safe to call (no authentication required)

## Commands Reference

| Command | Description | Auth Required |
|---------|-------------|---------------|
| `vault init` | Initialize all three vaults | Yes (passcode + biometric) |
| `vault set <name> [--vault policy]` | Store a new secret | Yes (target vault's policy) |
| `vault get <name>` | Decrypt and output a secret | Yes (secret's vault policy) |
| `vault update <name>` | Update an existing secret | Yes (secret's vault policy) |
| `vault delete <name> --confirm` | Remove a secret | Yes (secret's vault policy) |
| `vault list` | List vaults and secret names | No |
| `vault exec --allow/--env -- cmd` | Inject secrets into child process | Yes (per vault used) |
| `vault import <file> [--vault policy]` | Bulk import from .env file | Yes (target vault's policy) |
| `vault destroy --confirm` | Delete all vaults and secrets | Yes (all vaults) |

## Exit Codes

| Code | Meaning | Agent Action |
|------|---------|--------------|
| 0 | Success | Continue |
| 126 | Vault error (not initialized, secret not found, integrity failure) | Report error to user |
| 127 | Command not found | Fix the command |
| 128 | User cancelled authentication | **Do not retry** — user declined |

## Vault Policies

- **biometric**: Touch ID required. Use for production secrets, private keys, API keys with financial exposure.
- **passcode**: Device passcode required. Use when Touch ID isn't available.
- **open**: No authentication. Use only for non-sensitive development config (test RPC URLs, etc.).

## Common Workflows

```bash
# Run integration tests with secrets
keypo-signer vault exec --env .env.example -- cargo test -- --ignored --test-threads=1

# Run Foundry tests
keypo-signer vault exec --env .env.example -- forge test -vvv

# Deploy contracts
keypo-signer vault exec --allow DEPLOYER_PRIVATE_KEY -- forge script Deploy

# Check what secrets are available
keypo-signer vault list
```
