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
