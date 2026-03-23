# keypo-openclaw

Hardware-secured secrets for [OpenClaw](https://openclaw.ai), backed by the Apple Secure Enclave. Replaces plaintext API keys and tokens in OpenClaw config files with encrypted vault references — resolved at gateway startup via the batched exec provider protocol.

- One provider block in `openclaw.json` covers all secrets. Compare to 1Password, which requires one provider block per secret.
- Secrets are encrypted by hardware-bound P-256 keys in the Secure Enclave. They never exist in plaintext on disk.
- Adding a secret is one command: `keypo-openclaw add`. No manual config editing.
- Backs up to iCloud Drive with two-factor encryption (iCloud Keychain key + passphrase). Restore on any Mac with the same iCloud account.
- Works on headless Macs (Mac Mini, Mac Studio) with `--vault open` policy.

## Install

```bash
brew install keypo-us/tap/keypo-openclaw
```

This installs both keypo-openclaw and keypo-signer (the underlying vault engine). Requires Apple Silicon (M1+) and macOS 14+.

## Quick Start

```bash
# Initialize vault and register the keypo provider in OpenClaw
keypo-openclaw init

# Store secrets (values are encrypted in the Secure Enclave vault)
keypo-openclaw add TELEGRAM_BOT_TOKEN "123456:ABCDEF" --path channels.telegram.botToken
keypo-openclaw add ANTHROPIC_API_KEY "sk-ant-..." --path models.providers.anthropic.apiKey

# Restart your OpenClaw gateway — secrets resolve automatically
openclaw gateway

# Back up your secrets to iCloud Drive
keypo-openclaw backup
```

## How It Works

OpenClaw's SecretRef exec provider with `jsonOnly: true` uses a batched stdin/stdout JSON protocol. At gateway startup, OpenClaw spawns `keypo-openclaw resolve` once, sends all secret IDs, and receives all values in a single exchange.

```
OpenClaw Gateway                    keypo-openclaw resolve              keypo-signer
     |                                    |                                  |
     |-- stdin: {ids: [A, B, C]} -------->|                                  |
     |                                    |-- vault get A --format raw ----->|
     |                                    |<-- "value_a" --------------------|
     |                                    |-- vault get B --format raw ----->|
     |                                    |<-- "value_b" --------------------|
     |                                    |-- vault get C --format raw ----->|
     |                                    |<-- "value_c" --------------------|
     |<-- stdout: {values: {A, B, C}} ----|                                  |
     |                                    |                                  |
```

## Commands

| Command | Description |
|---|---|
| `init` | Initialize the vault and register the keypo provider in OpenClaw's config |
| `add <name> <value> --path <config.path>` | Store a secret and write a SecretRef to the config |
| `remove <name> [<name> ...]` | Remove secrets from the vault and clean up SecretRefs |
| `list` | List vault secrets with SecretRef cross-reference |
| `status` | Show integration health (signer, vault, provider, mismatches, backup) |
| `backup` | Encrypt and back up vault secrets to iCloud Drive |
| `backup --info` | Show backup status |
| `restore` | Restore vault secrets from iCloud Drive backup |
| `resolve` | Exec provider entry point (called by OpenClaw, not directly) |

### Adding Secrets

```bash
# Add to openclaw.json (default --vault open for daemon use)
keypo-openclaw add TELEGRAM_BOT_TOKEN "123456:ABCDEF" --path channels.telegram.botToken

# Add with biometric policy (requires Touch ID at every gateway start)
keypo-openclaw add ANTHROPIC_API_KEY "sk-ant-..." --path models.providers.anthropic.apiKey --vault biometric

# Add to auth-profiles.json
keypo-openclaw add ANTHROPIC_API_KEY "sk-ant-..." --auth-profile anthropic:default --auth-type api_key

# Add multiple secrets in one command (atomic)
keypo-openclaw add \
  TELEGRAM_BOT_TOKEN "123456:ABCDEF" --path channels.telegram.botToken \
  SLACK_BOT_TOKEN "xoxb-..." --path channels.slack.botToken

# Rotate a secret (updates vault, config unchanged)
keypo-openclaw add ANTHROPIC_API_KEY "sk-ant-new..." --path models.providers.anthropic.apiKey --update
```

### Removing Secrets

```bash
# Remove from both vault and config
keypo-openclaw remove DISCORD_TOKEN

# Remove multiple
keypo-openclaw remove DISCORD_TOKEN SLACK_BOT_TOKEN

# Remove from vault only (leave SecretRefs in config)
keypo-openclaw remove DISCORD_TOKEN --keep-config

# Remove from config only (leave secret in vault)
keypo-openclaw remove DISCORD_TOKEN --keep-vault
```

## OpenClaw Provider Configuration

`keypo-openclaw init` registers this provider block in `~/.openclaw/openclaw.json`:

```json
{
  "secrets": {
    "providers": {
      "keypo": {
        "source": "exec",
        "command": "/path/to/keypo-openclaw",
        "allowSymlinkCommand": true,
        "trustedDirs": ["/path/to/bin"],
        "args": ["resolve"],
        "passEnv": ["HOME", "PATH"],
        "jsonOnly": true
      }
    },
    "defaults": {
      "exec": "keypo"
    }
  }
}
```

Each secret becomes a one-line SecretRef:

```json
{ "source": "exec", "provider": "keypo", "id": "TELEGRAM_BOT_TOKEN" }
```

## Vault Policies

| Policy | Flag | Use Case |
|---|---|---|
| Open | `--vault open` (default) | Headless daemons, always-on gateways. No auth required. |
| Passcode | `--vault passcode` | Device passcode prompt at every gateway start. |
| Biometric | `--vault biometric` | Touch ID at every gateway start. Maximum security. |

Policies are set per-secret at storage time. Mix freely: store expensive API keys in `biometric` and channel tokens in `open`. The resolver handles mixed policies transparently.

## Headless Devices (Mac Mini / Mac Studio)

On Macs without Touch ID, initialize the vault with `--open-only`:

```bash
keypo-signer vault init --open-only
keypo-openclaw init
```

All secrets default to `--vault open`. The `passcode` and `biometric` tiers are not available without the corresponding hardware.

## Backup & Restore

```bash
# Back up all vault secrets to iCloud Drive
keypo-openclaw backup

# Check backup status
keypo-openclaw backup --info

# Restore on a new Mac (same iCloud account)
keypo-openclaw restore
```

Backup uses two-factor encryption: an iCloud Keychain synced key + a passphrase (displayed on first backup). Both are required to restore. After restoring, all SecretRefs in the OpenClaw config resolve on the next gateway start — no config changes needed.

## vs. 1Password

| | 1Password | keypo-openclaw |
|---|---|---|
| Config boilerplate | One 9-line provider block per secret | One provider block total |
| Adding a secret | Store in 1P + add provider block + add SecretRef + reload | One command + reload |
| Session management | Desktop app must be unlocked or service account token on disk | None. Secure Enclave is always available. |
| Cloud dependency | Secrets stored in 1Password cloud | None. Encrypted locally by hardware. |
| Secret extraction | Service account token on disk can pull all secrets | Not possible. Keys cannot leave the Secure Enclave. |
| Subscription | Required | Free |

## Development

```bash
cd keypo-openclaw
cargo build
cargo test
cargo clippy --all-targets -- -D warnings
```

## Part of keypo-wallet

This tool is part of the [keypo-wallet](https://github.com/keypo-us/keypo-wallet) monorepo. It calls [keypo-signer](../keypo-signer/) as a subprocess for all vault operations.
