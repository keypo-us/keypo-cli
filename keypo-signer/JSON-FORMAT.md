---
title: keypo-signer JSON Output Format
owner: "@davidblumenfeld"
last_verified: 2026-03-19
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
  "skipped": [],
  "createdAt": "2026-03-01T12:00:00Z"
}
```

On devices without Touch ID or with `--open-only`:

```json
{
  "vaults": [
    { "vaultKeyId": "com.keypo.vault.open", "policy": "open" }
  ],
  "skipped": ["passcode", "biometric"],
  "createdAt": "2026-03-01T12:00:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `vaults` | array | One entry per created policy tier |
| `vaults[].vaultKeyId` | string | `com.keypo.vault.<policy>` |
| `vaults[].policy` | string | `open`, `passcode`, or `biometric` |
| `skipped` | array | Policy tiers that could not be created (empty if all succeeded) |
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

### `vault backup --format json`

```json
{
  "backedUp": true,
  "secretCount": 3,
  "vaultNames": ["biometric", "open", "passcode"],
  "createdAt": "2026-03-01T12:00:00Z",
  "deviceName": "MacBook-Air"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `backedUp` | boolean | Always `true` |
| `secretCount` | number | Total secrets backed up across all vaults |
| `vaultNames` | array | Policy names of vaults included in the backup |
| `createdAt` | string | ISO 8601 timestamp of backup creation |
| `deviceName` | string | Name of the device that created the backup |

### `vault backup info --format json`

```json
{
  "backupExists": true,
  "createdAt": "2026-03-01T12:00:00Z",
  "deviceName": "MacBook-Air",
  "secretCount": 3,
  "vaultNames": ["biometric", "open", "passcode"],
  "previousBackupExists": false,
  "syncedKeyAvailable": true,
  "localSecretsNotBackedUp": 1
}
```

| Field | Type | Description |
|-------|------|-------------|
| `backupExists` | boolean | Whether a backup exists in iCloud Drive |
| `createdAt` | string \| null | ISO 8601 timestamp of backup, or null if no backup |
| `deviceName` | string \| null | Device that created the backup, or null |
| `secretCount` | number \| null | Secrets in the backup, or null if no backup |
| `vaultNames` | array \| null | Vault policies in the backup, or null |
| `previousBackupExists` | boolean | Whether a previous (rotated) backup exists |
| `syncedKeyAvailable` | boolean | Whether the iCloud Keychain synced key is available |
| `localSecretsNotBackedUp` | number | Count of local secrets not present in the backup |

### `vault backup reset --format json`

```json
{
  "reset": true,
  "secretCount": 3,
  "vaultNames": ["biometric", "open", "passcode"],
  "createdAt": "2026-03-01T12:00:00Z"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `reset` | boolean | Always `true` |
| `secretCount` | number | Total secrets in the new backup |
| `vaultNames` | array | Vault policies included |
| `createdAt` | string | ISO 8601 timestamp of new backup |

### `vault restore --format json`

Two possible responses depending on whether there is a conflict with an existing local vault.

**Success** (no conflict, or after replace/merge):

```json
{
  "restored": true,
  "secretCount": 3,
  "vaultNames": ["biometric", "open", "passcode"],
  "restoredAt": "2026-03-01T12:00:00Z",
  "fromPrevious": false,
  "action": "restore",
  "mergedCount": null
}
```

| Field | Type | Description |
|-------|------|-------------|
| `restored` | boolean | Always `true` |
| `secretCount` | number | Total secrets restored |
| `vaultNames` | array | Vault policies restored |
| `restoredAt` | string | ISO 8601 timestamp |
| `fromPrevious` | boolean | `true` if restored from the previous (rotated) backup |
| `action` | string | `"restore"` (no local vault), `"replace"`, or `"merge"` |
| `mergedCount` | number \| null | Number of backup-only secrets added (only for `"merge"`, null otherwise) |

**Conflict** (non-interactive / piped, exit code 2):

```json
{
  "status": "conflict",
  "message": "Local vault exists. Re-run with --format pretty for interactive merge.",
  "localOnly": [{"name": "NEW_SECRET", "policy": "open"}],
  "backupOnly": [{"name": "PROD_TOKEN", "policy": "passcode"}],
  "inBoth": [{"name": "API_KEY", "policy": "open"}]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Always `"conflict"` |
| `message` | string | Guidance to re-run interactively |
| `localOnly` | array | Secrets only in the local vault (`name`, `policy`) |
| `backupOnly` | array | Secrets only in the backup (`name`, `policy`) |
| `inBoth` | array | Secrets present in both (`name`, `policy`) |

Only emitted when stdin is not a TTY (piped/scripted usage). Interactive terminal sessions always get the diff + prompt flow.

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
| 1 | Backup/restore: iCloud unavailable, synced key not found, backup not found, decryption failed, merge failed |
| 2 | Restore conflict (JSON mode only): local vault exists, diff returned |
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
