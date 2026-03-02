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

## Notes

- All hex values use `0x` prefix
- Signatures are ECDSA P-256 with low-S normalization (s ≤ curve_order/2)
- The tool signs pre-hashed data — it does NOT hash the input
- Public keys are uncompressed format: `0x04` || 32-byte x || 32-byte y
