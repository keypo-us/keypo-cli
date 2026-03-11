# keypo-signer

Encrypted secret storage for macOS, backed by the Apple Secure Enclave. Secrets are encrypted with ECIES (ECDH + AES-256-GCM) using hardware-bound P-256 keys — they never exist in plaintext on disk. Also provides low-level P-256 signing for smart wallet operations.

- Encryption keys are generated inside and never leave the Secure Enclave hardware. Not even Apple can extract them.
- Three vault policies: `open` (no auth), `passcode` (device password), `biometric` (Touch ID).
- `vault exec` injects secrets into any process as environment variables — no `.env` files needed.
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
# Initialize vault encryption keys
keypo-signer vault init

# Store a secret
echo -n "sk_live_abc123" | keypo-signer vault set API_KEY --vault open

# Import secrets from an existing .env file
keypo-signer vault import --file .env --vault open

# Run a command with secrets injected as env vars
keypo-signer vault exec -- npm start

# Retrieve a single secret
keypo-signer vault get API_KEY
```

## Vault Commands

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

### Using vault exec

`vault exec` is the primary command for running processes with secrets. It decrypts all secrets across all vaults and injects them as environment variables into the subprocess. Use `--env` to filter to only the variables defined in a template file:

```bash
# Inject all vault secrets
keypo-signer vault exec -- npm start

# Inject only the variables listed in .env.example
keypo-signer vault exec --env .env.example -- npm start
```

This is the recommended way for AI agents to run commands that need secrets. See [skills/vault/SKILL.md](../skills/vault/SKILL.md) for agent usage.

## Vault Policies

| Policy | Flag | Behavior |
|---|---|---|
| Open | `--vault open` | No auth required. Usable whenever the device is unlocked. Best for automated processes and AI agents. |
| Passcode | `--vault passcode` | Device passcode required before each decrypt. |
| Biometric | `--vault biometric` | Touch ID required before each decrypt. If biometrics change (re-enrolled fingerprint), the vault becomes permanently inaccessible. |

Policies are set per-secret at storage time. They are enforced by the Secure Enclave hardware — listing and deleting secrets do not require auth.

## Signing Commands

Low-level P-256 signing for smart wallet operations. The `keypo-wallet` CLI calls these as a subprocess — most users won't need them directly.

| Command | Description |
|---|---|
| `create --label <name> --policy <policy>` | Create a new Secure Enclave signing key |
| `list` | List all managed keys |
| `info <label>` | Show key details (public key, policy, signing count) |
| `sign <hex> --key <label>` | Sign a hex-encoded digest |
| `verify <hex> --key <label> --r <hex> --s <hex>` | Verify a P-256 signature |
| `delete --label <name> --confirm` | Delete a key (irreversible) |
| `rotate --label <name>` | Rotate a key (create new, delete old) |

All commands support `--format json` for machine-readable output.

## Output Formats

- `--format json` — structured JSON (default)
- `--format pretty` — human-readable text
- `--format raw` — bare hex, no wrapper

See [JSON-FORMAT.md](JSON-FORMAT.md) for the exact JSON schema of each command's output.

## Key Details

- **Curve:** P-256 (secp256r1) — the only curve the Secure Enclave supports
- **Vault encryption:** ECIES — ECDH key agreement + HKDF-SHA256 + AES-256-GCM
- **Signatures:** ECDSA with low-S normalization (s <= curve_order/2)
- **Pre-hashed signing:** the tool signs the input bytes directly. It does NOT hash the input. Callers are responsible for hashing before calling sign.
- **Key storage:** private keys live in the Secure Enclave. Metadata is stored in `~/.keypo/keys.json`. Vault data is stored in `~/.keypo/vault.json`.

## Development

```bash
swift build
swift test
swift run keypo-signer <command>
```

See [the spec](../docs/archive/specs/keypo-signer-spec.md) for the full technical specification.

## Part of keypo-wallet

This tool is part of the [keypo-wallet](https://github.com/keypo-us/keypo-wallet) monorepo. The Rust CLI (`keypo-wallet`) calls `keypo-signer` as a subprocess for all signing operations. See the root README for the full system overview.
