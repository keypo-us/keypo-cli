---
title: keypo-signer JSON Output Format
owner: @davidblumenfeld
last_verified: 2026-03-05
status: current
---

# keypo-signer JSON Output Format

Verified output format for `keypo-signer` commands when using `--format json`. This document is the reference for the Rust crate's `KeypoSigner` parser.

## `create --label <name> --policy <policy> --format json`

```json
{
  "keyId": "com.keypo.signer.<label>",
  "publicKey": "0x04...",
  "policy": "open",
  "curve": "P-256"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `keyId` | string | Application tag: `com.keypo.signer.<label>` |
| `publicKey` | string | Uncompressed P-256 public key, `0x04` \|\| qx \|\| qy (65 bytes, 130 hex chars + prefix) |
| `policy` | string | `open`, `passcode`, or `biometric` |
| `curve` | string | Always `"P-256"` |

## `list --format json`

```json
{
  "keys": [
    {
      "keyId": "com.keypo.signer.<label>",
      "publicKey": "0x04...",
      "policy": "open",
      "status": "active",
      "signingCount": 42,
      "lastUsedAt": "2026-03-01T12:00:00Z"
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `keys` | array | All managed keys |
| `keys[].keyId` | string | Application tag |
| `keys[].publicKey` | string | Uncompressed public key |
| `keys[].policy` | string | `open`, `passcode`, or `biometric` |
| `keys[].status` | string | Key status (e.g., `"active"`) |
| `keys[].signingCount` | number | Total signatures produced |
| `keys[].lastUsedAt` | string \| null | ISO 8601 timestamp of last signing, or null |

## `info <label> --format json`

```json
{
  "keyId": "com.keypo.signer.<label>",
  "publicKey": "0x04...",
  "curve": "P-256",
  "policy": "open",
  "status": "active",
  "previousPublicKeys": [],
  "createdAt": "2026-03-01T12:00:00Z",
  "signingCount": 42
}
```

| Field | Type | Description |
|-------|------|-------------|
| `keyId` | string | Application tag |
| `publicKey` | string | Current uncompressed public key |
| `curve` | string | Always `"P-256"` |
| `policy` | string | `open`, `passcode`, or `biometric` |
| `status` | string | Key status |
| `previousPublicKeys` | array | Public keys from before key rotation (empty if never rotated) |
| `createdAt` | string | ISO 8601 creation timestamp |
| `signingCount` | number | Total signatures produced |

## `sign <hex-data> --key <label> --format json`

```json
{
  "r": "0x...",
  "s": "0x...",
  "keyId": "com.keypo.signer.<label>",
  "algorithm": "ES256",
  "publicKey": "0x04..."
}
```

| Field | Type | Description |
|-------|------|-------------|
| `r` | string | `0x`-prefixed hex, 32 bytes big-endian |
| `s` | string | `0x`-prefixed hex, 32 bytes big-endian, **low-S normalized** |
| `keyId` | string | Application tag of the signing key |
| `algorithm` | string | Always `"ES256"` |
| `publicKey` | string | Uncompressed public key of the signing key |

## Vault Commands

### `vault init --format json`

```json
{
  "vaults": [
    { "vaultKeyId": "com.keypo.vault.open", "policy": "open" },
    { "vaultKeyId": "com.keypo.vault.passcode", "policy": "passcode" },
    { "vaultKeyId": "com.keypo.vault.biometric", "policy": "biometric" }
  ],
  "createdAt": "2026-03-01T12:00:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `vaults` | array | One entry per policy |
| `vaults[].vaultKeyId` | string | `com.keypo.vault.<policy>` |
| `vaults[].policy` | string | `open`, `passcode`, or `biometric` |
| `createdAt` | string | ISO 8601 timestamp |

### `vault set <name> --vault <policy> --format json`

Value is read from stdin.

```json
{
  "name": "API_KEY",
  "vault": "open",
  "action": "created",
  "createdAt": "2026-03-01T12:00:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Secret name |
| `vault` | string | Policy vault used (`open`, `passcode`, `biometric`) |
| `action` | string | Always `"created"` |
| `createdAt` | string | ISO 8601 timestamp |

### `vault get <name> --format json`

```json
{
  "name": "API_KEY",
  "vault": "open",
  "value": "sk_live_abc123"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Secret name |
| `vault` | string | Policy vault the secret was found in |
| `value` | string | Decrypted secret value |

### `vault update <name> --format json`

Value is read from stdin.

```json
{
  "name": "API_KEY",
  "vault": "open",
  "action": "updated",
  "updatedAt": "2026-03-01T12:00:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Secret name |
| `vault` | string | Policy vault used |
| `action` | string | Always `"updated"` |
| `updatedAt` | string | ISO 8601 timestamp |

### `vault delete <name> --confirm --format json`

```json
{
  "name": "API_KEY",
  "vault": "open",
  "deleted": true,
  "deletedAt": "2026-03-01T12:00:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Secret name |
| `vault` | string | Policy vault the secret was in |
| `deleted` | boolean | Always `true` |
| `deletedAt` | string | ISO 8601 timestamp |

### `vault list --format json`

```json
{
  "vaults": [
    {
      "policy": "open",
      "vaultKeyId": "com.keypo.vault.open",
      "createdAt": "2026-03-01T12:00:00Z",
      "secrets": [
        {
          "name": "API_KEY",
          "createdAt": "2026-03-01T12:00:00Z",
          "updatedAt": "2026-03-01T12:00:00Z"
        }
      ],
      "secretCount": 1
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `vaults` | array | One entry per initialized policy vault |
| `vaults[].policy` | string | `open`, `passcode`, or `biometric` |
| `vaults[].vaultKeyId` | string | `com.keypo.vault.<policy>` |
| `vaults[].createdAt` | string | ISO 8601 timestamp |
| `vaults[].secrets` | array | Secrets in this vault (names only, no values) |
| `vaults[].secrets[].name` | string | Secret name |
| `vaults[].secrets[].createdAt` | string | ISO 8601 timestamp |
| `vaults[].secrets[].updatedAt` | string | ISO 8601 timestamp |
| `vaults[].secretCount` | number | Number of secrets in this vault |

### `vault exec <command> [args...]`

No JSON output. `vault exec` runs a subprocess with secrets injected as environment variables and exits with the child process's exit code. It does not support `--format json`.

### `vault import --file <path> --vault <policy> --format json`

```json
{
  "vault": "open",
  "imported": [
    { "name": "API_KEY", "action": "created" }
  ],
  "skipped": [
    { "name": "DB_URL", "reason": "already exists" }
  ],
  "importedCount": 1,
  "skippedCount": 1
}
```

| Field | Type | Description |
|-------|------|-------------|
| `vault` | string | Policy vault imported into |
| `imported` | array | Successfully imported secrets |
| `imported[].name` | string | Secret name |
| `imported[].action` | string | `"created"` |
| `skipped` | array | Secrets that were skipped |
| `skipped[].name` | string | Secret name |
| `skipped[].reason` | string | Why the secret was skipped (e.g., `"already exists"`) |
| `importedCount` | number | Number imported |
| `skippedCount` | number | Number skipped |

### `vault destroy --confirm --format json`

```json
{
  "destroyed": true,
  "vaultsDestroyed": ["open", "passcode", "biometric"],
  "totalSecretsDeleted": 5,
  "destroyedAt": "2026-03-01T12:00:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `destroyed` | boolean | Always `true` |
| `vaultsDestroyed` | array | Policy names of destroyed vaults |
| `totalSecretsDeleted` | number | Total secrets deleted across all vaults |
| `destroyedAt` | string | ISO 8601 timestamp |

### Vault Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Vault not initialized, load failed, or already initialized (`init`) |
| 2 | Invalid secret name, secret not found, SE unavailable (`init`), or parse error (`import`) |
| 3 | Secret already exists (`set`), key/encryption error, or `--confirm` missing (`delete`/`destroy`) |
| 4 | Authentication cancelled (`init`/`set`/`update`/`delete`/`destroy`), corrupt key (`set`/`update`), or invalid name (`import`) |
| 5 | Empty value (`set`/`update`), integrity check failed (`get`/`delete`), or auth cancelled (`import`) |
| 6 | Integrity check failed (`set`/`update`), or encryption error (`import`) |
| 7 | Authentication cancelled (`set`) |
| 126 | `vault exec`: parameter validation failed |
| 127 | `vault exec`: command not found |
| 128 | `vault exec`: authentication cancelled |

## Notes

- All hex values use `0x` prefix
- Signatures are ECDSA P-256 with low-S normalization (s ≤ curve_order/2)
- The tool signs pre-hashed data — it does NOT hash the input
- Public keys are uncompressed format: `0x04` || 32-byte x || 32-byte y
- Vault secrets are encrypted with ECIES (ECDH + HKDF-SHA256 + AES-256-GCM)
- Secret names must match `^[A-Za-z_][A-Za-z0-9_]{0,127}$`
