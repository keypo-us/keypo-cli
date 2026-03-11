# keypo-signer

A macOS CLI that manages P-256 signing keys inside the Apple Secure Enclave. It creates keys, signs data, and returns signatures. That's it.

- Private keys are generated inside and never leave the Secure Enclave hardware. Not even Apple can extract them.
- Three signing policies: `open` (no auth), `passcode` (device password), `biometric` (Touch ID).
- Any process that can shell out to a CLI can use it — AI agents, shell scripts, cron jobs, other tools.
- Outputs JSON by default for easy integration.

## Install

```bash
brew install keypo-us/tap/keypo-signer
```

> **Switching to keypo-wallet?** Run `brew uninstall keypo-signer` first,
> then `brew install keypo-us/tap/keypo-wallet`.

Requires Apple Silicon (M1+) and macOS 14+.

If you have `keypo-wallet` installed, `keypo-signer` is already bundled — no separate install needed.

## Quick Start

```bash
# Create a key with Touch ID protection
keypo-signer create --label my-key --policy biometric

# List all keys
keypo-signer list

# Sign a 32-byte hex digest
keypo-signer sign 0x<hex-digest> --key my-key

# Get JSON output
keypo-signer sign 0x<hex-digest> --key my-key --format json
```

## Commands

| Command | Description |
|---|---|
| `create --label <name> --policy <policy>` | Create a new Secure Enclave key |
| `list` | List all managed keys |
| `info <label>` | Show key details (public key, policy, signing count) |
| `sign <hex> --key <label>` | Sign a hex-encoded digest |
| `verify <hex> --key <label> --r <hex> --s <hex>` | Verify a P-256 signature |
| `delete --label <name> --confirm` | Delete a key (irreversible) |
| `rotate --label <name>` | Rotate a key (create new, delete old) |

All commands support `--format json` for machine-readable output.

## Vault Commands

Encrypted secret storage backed by the Secure Enclave. Secrets are encrypted with ECIES (ECDH + AES-256-GCM) using a Secure Enclave P-256 key agreement key, so they never exist in plaintext on disk.

| Command | Description |
|---|---|
| `vault init` | Create vault encryption keys for all three policies (open, passcode, biometric) |
| `vault set <name> --vault <policy>` | Store an encrypted secret |
| `vault get <name>` | Decrypt and print a secret |
| `vault update <name>` | Replace a secret's value |
| `vault delete <name> --confirm` | Delete a secret (irreversible) |
| `vault list` | List all vaults and their secret names (values are never shown) |
| `vault exec <command> [args...]` | Run a command with secrets injected as environment variables |
| `vault import --file <path> --vault <policy>` | Import secrets from a `.env` file |
| `vault destroy --confirm` | Delete all vaults, keys, and secrets (irreversible) |

### Vault Quick Start

```bash
# Initialize vault encryption keys
keypo-signer vault init

# Store a secret
echo -n "sk_live_abc123" | keypo-signer vault set API_KEY --vault open

# Retrieve it
keypo-signer vault get API_KEY

# Run a command with secrets as env vars
keypo-signer vault exec -- env | grep API_KEY

# Import from .env file
keypo-signer vault import --file .env --vault open
```

`vault exec` is the primary agent-facing command — it injects secrets into a subprocess without exposing them on the command line. See [skills/vault/SKILL.md](../skills/vault/SKILL.md) for agent usage.

## Signing Policies

| Policy | Flag | Behavior |
|---|---|---|
| Open | `--policy open` | No auth required. Key is usable whenever the device is unlocked. Best for automated processes. |
| Passcode | `--policy passcode` | Device passcode required before each sign. |
| Biometric | `--policy biometric` | Touch ID required before each sign. If biometrics change (re-enrolled fingerprint), the key becomes permanently inaccessible. |

Policies are set at key creation and cannot be changed. They are enforced by the Secure Enclave hardware for signing operations only — listing, deleting, and rotating keys do not require policy auth.

## Output Formats

- `--format json` — structured JSON (default)
- `--format pretty` — human-readable text
- `--format raw` — bare hex, no wrapper

See [JSON-FORMAT.md](JSON-FORMAT.md) for the exact JSON schema of each command's output.

## Key Details

- **Curve:** P-256 (secp256r1) — the only curve the Secure Enclave supports
- **Public keys:** uncompressed format with `0x04` prefix (65 bytes / 130 hex chars)
- **Signatures:** ECDSA with low-S normalization (s <= curve_order/2)
- **Pre-hashed signing:** the tool signs the input bytes directly. It does NOT hash the input. Callers are responsible for hashing before calling sign.
- **Key storage:** private keys live in the Secure Enclave. Metadata (labels, counters, public keys) is stored in `~/.keypo/keys.json`.

## Development

```bash
swift build
swift test
swift run keypo-signer <command>
```

See [the spec](../docs/archive/specs/keypo-signer-spec.md) for the full technical specification.

## Part of keypo-wallet

This tool is part of the [keypo-wallet](https://github.com/keypo-us/keypo-wallet) monorepo. The Rust CLI (`keypo-wallet`) calls `keypo-signer` as a subprocess for all signing operations. See the root README for the full system overview.
