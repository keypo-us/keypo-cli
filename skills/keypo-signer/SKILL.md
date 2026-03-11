---
name: keypo-signer
description: Use when managing Secure Enclave signing keys or encrypted secrets.
  Use for creating/listing/deleting P-256 keys, signing digests, running commands
  with secrets injected via vault exec, storing/retrieving encrypted secrets.
  Also use when an agent needs API keys, private keys, or credentials injected
  into a subprocess without exposing them.
version: "0.1.0"
metadata:
  author: keypo-us
  compatibility: macOS Apple Silicon only
---

# keypo-signer

A CLI for hardware-bound P-256 key management and encrypted secret storage using the Apple Secure Enclave. Keys never leave the hardware. Secrets are encrypted at rest and decrypted only into child process environments.

**Install:** `brew install keypo-us/tap/keypo-signer`
This installs the `keypo-signer` Swift CLI for Secure Enclave key management and encrypted vault operations.

**Source:** https://github.com/keypo-us/keypo-cli

---

## CLI Usage Rule

**Before using any keypo-signer command for the first time in a session, run `keypo-signer help <command>` to learn the exact flags, syntax, and examples.** The help output is the authoritative reference for each command.

```bash
keypo-signer help vault exec   # learn vault exec flags before using
keypo-signer help create       # learn create flags before creating keys
keypo-signer help sign         # learn sign flags before signing
```

Do not guess flag names or assume positional arguments. Every command documents its interface via `help`.

---

## Running Commands with Secrets (vault exec)

Use `vault exec` to inject decrypted secrets into a child process environment. The agent never sees plaintext values — secrets flow directly from the encrypted vault into the child process.

### Basic patterns

```bash
# Using a .env.example file (recommended — values are ignored, only names matter)
keypo-signer vault exec --env .env.example -- cargo test

# Using explicit secret names
keypo-signer vault exec --allow PIMLICO_API_KEY,DEPLOYER_PRIVATE_KEY -- cargo test

# All secrets from all vaults
keypo-signer vault exec --allow '*' -- forge test -vvv
```

### The .env.example convention

The `--env` flag reads a file for **key names only** — values are ignored. Use a `.env.example` with empty or dummy values:

```
# .env.example
PIMLICO_API_KEY=
DEPLOYER_PRIVATE_KEY=placeholder
BASE_SEPOLIA_RPC_URL=https://example.com
```

The vault looks up each name, finds which vault stores it, decrypts it, and injects it into the child process environment.

### Combining --allow and --env

Both flags can be used together. Names are unioned and deduplicated:

```bash
keypo-signer vault exec --env .env.example --allow EXTRA_SECRET -- ./deploy.sh
```

### Argument passing rules

The `--` separator is **required**. Everything after `--` is the command to execute.

**Simple commands** — pass the command and its arguments directly:

```bash
keypo-signer vault exec --env .env.example -- cargo test -- --ignored --test-threads=1
keypo-signer vault exec --allow '*' -- forge script Deploy
```

**Shell expressions** — when you need shell features (pipes, variable expansion, subshells), use `sh -c`:

```bash
keypo-signer vault exec --env .env.example -- sh -c 'echo $SECRET_NAME'
keypo-signer vault exec --allow '*' -- sh -c 'curl -H "Authorization: Bearer $API_KEY" https://api.example.com'
```

**sh -c coalescing** — when using `sh -c`, all arguments after `-c` are automatically joined into a single string. This means you don't need to quote the entire expression:

```bash
# These are equivalent:
keypo-signer vault exec --allow '*' -- sh -c 'echo $FOO && echo $BAR'
keypo-signer vault exec --allow '*' -- sh -c echo $FOO && echo $BAR
```

### What NOT to do

- **Never** use `vault get` in agent workflows — it outputs plaintext to stdout. Use `vault exec` instead.
- **Never** retry after exit code 128 — the user deliberately cancelled authentication.
- **Never** attempt to read, log, capture, or exfiltrate secret values. Secrets must stay inside the child process.
- **Never** pipe `vault get` output into environment variables or files.

### Exit codes

| Code | Meaning | Agent Action |
|------|---------|--------------|
| 0 | Success | Continue |
| 126 | Vault error (not initialized, secret not found, integrity failure) | Report error to user |
| 127 | Command not found | Fix the command path |
| 128 | User cancelled authentication | **Do not retry** — user declined |
| 128+N | Child killed by signal N | Report signal to user |

### Behavioral details

| Topic | Detail |
|---|---|
| Environment inheritance | Child inherits parent env + decrypted secrets overlaid (secrets take precedence) |
| Auth prompts | One prompt per vault per invocation. Vaults loaded in order: open, passcode, biometric |
| stderr output | Prints `keypo-vault: decrypting N secret(s) for: <command>` to stderr before running |
| Exit code forwarding | Child's exit code is forwarded directly. Signal kills map to 128 + signal number |

### Common patterns

```bash
# Run integration tests with secrets
keypo-signer vault exec --env .env.example -- cargo test -- --ignored --test-threads=1

# Run Foundry tests
keypo-signer vault exec --env .env.example -- forge test -vvv

# Deploy contracts
keypo-signer vault exec --allow DEPLOYER_PRIVATE_KEY -- forge script Deploy

# Multi-tool composition: secrets + keypo-wallet
keypo-signer vault exec --allow PIMLICO_API_KEY --allow KEYPO_RPC_URL -- keypo-wallet send --key agent --to 0x... --value 1000

# Check what secrets are available (no auth required)
keypo-signer vault list
```

---

## Storing Secrets

### Initialize vaults

```bash
keypo-signer vault init
```

Creates three vaults: `open`, `passcode`, and `biometric`. Each is backed by its own Secure Enclave key.

### Store a secret

```bash
keypo-signer vault set MY_API_KEY --vault biometric
```

Prompts for the secret value interactively (never pass secrets as command arguments). Default vault is `biometric`.

### Bulk import from .env file

```bash
keypo-signer vault import .env --vault passcode
```

Reads key=value pairs from the file and stores each as a separate secret.

### Update a secret

```bash
keypo-signer vault update MY_API_KEY
```

Prompts for the new value. The secret stays in its original vault.

### Delete a secret

```bash
keypo-signer vault delete MY_API_KEY --confirm
```

The `--confirm` flag is required to prevent accidental deletion.

### List secrets (safe, no auth)

```bash
keypo-signer vault list
```

Shows vault names and secret names. No decryption occurs.

### Destroy all vaults

```bash
keypo-signer vault destroy --confirm
```

Permanently deletes all vaults, secrets, and vault keys. Irreversible.

---

## Vault Policies

| Policy | Auth | Use for |
|--------|------|---------|
| **biometric** | Touch ID | Production secrets, private keys, API keys with financial exposure |
| **passcode** | Device passcode | When Touch ID isn't available or for moderate-sensitivity secrets |
| **open** | None | Non-sensitive dev config only (test RPC URLs, public endpoints) |

For agent workflows, store secrets in `open` or `passcode` vaults. `biometric` requires interactive Touch ID which blocks automation.

---

## Key Management

### Create a key

```bash
keypo-signer create --label my-key --policy open
```

Generates a P-256 key in the Secure Enclave. Policies: `open`, `passcode`, `biometric`.

### List keys

```bash
keypo-signer list
```

Shows all managed keys with labels, policies, and creation dates.

### Key details

```bash
keypo-signer info --label my-key
```

Shows public key, policy, and metadata for a specific key.

### Sign a digest

```bash
keypo-signer sign --label my-key --digest 0x<32-byte-hex>
```

Signs a raw 32-byte digest. Uses prehash signing (no double-hashing). Output is a DER-encoded P-256 signature.

### Verify a signature

```bash
keypo-signer verify --public-key 0x<pubkey> --digest 0x<digest> --signature 0x<sig>
```

### Delete a key

```bash
keypo-signer delete --label my-key --confirm
```

Permanently destroys the key from the Secure Enclave. Irreversible.

### Rotate a key

```bash
keypo-signer rotate --label my-key
```

Generates a new key with the same label and policy, replacing the old one.

---

## Commands Reference

| Command | Description | Auth Required |
|---------|-------------|---------------|
| `create` | Generate a new P-256 key in the Secure Enclave | Yes (policy-dependent) |
| `list` | List all managed keys | No |
| `info` | Show key details or system info | No |
| `sign` | Sign a digest with a key | Yes (key's policy) |
| `verify` | Verify a signature | No |
| `delete` | Destroy a key permanently | Yes (key's policy) |
| `rotate` | Replace a key keeping label and policy | Yes (key's policy) |
| `vault init` | Initialize all three vaults | Yes (passcode + biometric) |
| `vault set` | Store a new secret | Yes (target vault's policy) |
| `vault get` | Decrypt and output a secret | Yes (secret's vault policy) |
| `vault update` | Update an existing secret | Yes (secret's vault policy) |
| `vault delete` | Remove a secret | Yes (secret's vault policy) |
| `vault list` | List vaults and secret names | No |
| `vault exec` | Inject secrets into child process | Yes (per vault used) |
| `vault import` | Bulk import from .env file | Yes (target vault's policy) |
| `vault destroy` | Delete all vaults and secrets | Yes (all vaults) |

Run `keypo-signer help <command>` or `keypo-signer help vault <subcommand>` for flags and examples.

---

## Security Notes

- Private keys **never** leave the Secure Enclave. No export command exists.
- Secrets are encrypted at rest using Secure Enclave keys and decrypted only into child process environments.
- Use `vault exec` instead of `vault get` in all automated workflows.
- For agent use, `open` policy keys and vaults avoid interactive auth prompts.
- For high-value secrets, prefer `biometric` or `passcode` vaults with interactive user approval.
