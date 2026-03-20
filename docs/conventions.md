---
title: Coding Conventions
owner: "@davidblumenfeld"
last_verified: 2026-03-19
status: current
---

# Coding Conventions

Standards and gotchas for all three languages in the monorepo. These are enforced rules, not suggestions.

## Cross-Language Rules

- **Policy names**: `open` / `passcode` / `biometric`. Never use `none`. The specs originally said `none` -- this was corrected in Phase 0.
- **ERC-7821 batch mode**: Always use mode byte `0x01` (batch). Single calls are encoded as a one-element batch. Never use `0x00`. See [ADR-003](decisions/003-erc7821-batch-mode.md).
- **Low-S normalization**: Mandatory on all P-256 signatures. After signing, check `s > curve_order/2` and replace with `curve_order - s` if true. Applies to both Rust `MockSigner` and Swift `SecureEnclaveManager`.
- **keypo-signer create syntax**: Uses `--label <name>` flag, not a positional argument. `keypo-signer create --label <name> --policy <p>`.
- **P-256 pre-hash signing**: NEVER double-hash. See [ADR-002](decisions/002-p256-prehash-signing.md) for the full explanation.

## Rust (keypo-wallet)

### alloy 1.7 API

- **Provider creation**: `ProviderBuilder::new().connect_http(url)` -- NOT `on_http(url)`. The `on_http` method does not exist in alloy 1.7.
- **EIP-7702 feature flag**: Does NOT exist in alloy 1.x. EIP-7702 types are available via `alloy::eips::eip7702::*` through the default `eips` feature. Do not add `eip7702` to Cargo.toml features. See [ADR-004](decisions/004-alloy-version-pinning.md).
- **`dirs` crate version**: `dirs = "6"` (not 5).
- **`alloy-sol-types` 1.5.7**: `abi_decode()` takes 1 argument (no `validate: bool` parameter). Differs from older versions.
- **`provider.call()`**: Takes an owned `TransactionRequest`, not a reference. Use `.to()` and `.input(TransactionInput::new(...))`.

### P-256 Signing

- Use `PrehashSigner::sign_prehash()` from `p256::ecdsa::signature::hazmat`. NOT `Signer::sign()` which SHA-256 hashes the input before signing.
- The `P256Signer` trait is named to avoid collision with `alloy::signers::Signer`.
- The Rust crate shells out to the `keypo-signer` Swift CLI as a subprocess. See [ADR-005](decisions/005-keypo-signer-subprocess.md).

### ABI Encoding

- **WebAuthn signatures**: Use `sig.abi_encode_params()` (flat tuple encoding), NOT `abi.encode(struct)` which adds an outer offset.
- **`SolValue` import**: Must `use alloy::sol_types::SolValue` for `U256::abi_decode()` on return data.
- **UserOp hash**: ERC-4337 v0.7 packed format. Uses `abi_encode_params()` for both inner and outer hashes.

### Gas and Fees

- **Gas pricing**: `eth_gasPrice * 3/2` for maxFee, `eth_maxPriorityFeePerGas` with 0.1 gwei fallback. Always via standard RPC, never bundler URL.
- **preVerificationGas buffer**: `pvg * 11/10` (integer) applied unconditionally.
- **paymasterAndData encoding**: Gas limits as `u128::to_be_bytes()` (16 bytes), NOT raw hex-decode.
- **Gas field packing**: `accountGasLimits = pack(verificationGasLimit, callGasLimit)`, `gasFees = pack(maxPriorityFeePerGas, maxFeePerGas)`.

### EIP-7702 Setup

- Uses ephemeral secp256k1 key (NOT P-256) for the type-4 transaction. See [ADR-001](decisions/001-eip7702-ephemeral-eoa.md).
- Auth nonce: When sender == authority, `auth_nonce = current_nonce + 1` (sender's nonce is incremented BEFORE auth list processing per EIP-7702 spec).
- Gas limit: Type-4 txs need manual gas limit (500k) -- auto-estimation runs against empty EOA code.

### Paymaster

- **`apply_paymaster_data` must NOT overwrite gas fields with `None`**. When `pm_getPaymasterData` response omits `paymasterVerificationGasLimit` / `paymasterPostOpGasLimit`, preserve values from the gas estimator. Without this, AA33 paymaster revert occurs. See [ADR-006](decisions/006-paymaster-gas-field-preservation.md).

### Error Handling

- `Error::suggestion()` returns hints for 13 variants (SignerNotFound, AA21/AA25/AA33/AA34, etc.).
- `io::ErrorKind::NotFound` maps to `SignerNotFound` (not `SignerCommand`).
- RPC errors: AA-prefixed data shown as `"AA21 ... (message)"`, non-AA as `"RPC error code: message data"`. String data extracted via `.as_str()` to avoid JSON quote wrapping.

### Config Resolution

- 4-tier: CLI flag > env var > config file > error. See [ADR-007](decisions/007-4tier-config-resolution.md).

## Swift (keypo-signer)

- **Pre-hashed signing**: Cast 32-byte input to `SHA256Digest` via pointer reinterpret (`withUnsafeBytes` + `assumingMemoryBound`) — `SHA256Digest` has no public initializer. Then use `signature(for: Digest)`. NEVER use `signature(for: Data)` which SHA-256 hashes the input. NEVER use `SecKeyCreateSignature` which also hashes. See [ADR-002](decisions/002-p256-prehash-signing.md).
- **Key API**: Use `SecureEnclave.P256.Signing.PrivateKey` from CryptoKit (not Security framework's `SecKeyCreateSignature`).
- **JSON encoding**: `JSONEncoder` with `outputFormatting: [.prettyPrinted, .sortedKeys]`.
- **Application tag pattern**: `com.keypo.signer.<label>` -- this is how SE keys are looked up in the Keychain.
- **Label validation**: `^[a-z][a-z0-9-]{0,63}$`.
- **Output routing**: Structured output to stdout, errors to stderr.
- **Atomic file writes**: Write to temp file, then rename (for `~/.keypo/keys.json` metadata).

### Vault Conventions

- **Vault policy names**: `biometric`, `passcode`, `open` — same as signing keys. Vault keys use application tag `com.keypo.vault.<policy>`.
- **ECIES encryption**: ECDH with ephemeral P-256 key + HKDF-SHA256 (salt: ephemeral public key raw bytes) + AES-256-GCM. HKDF info string: `"keypo-vault-v1" || secret_name`.
- **HMAC integrity**: Key is `"keypo-vault-integrity-v1"`, computed over canonical JSON serialization of secrets dictionary using `.sortedKeys` output formatting. Verified before any mutation.
- **LAContext sharing**: One LAContext per command invocation, passed to all VaultManager calls. Avoids multiple auth prompts per action.
- **Secret name validation**: `^[A-Za-z_][A-Za-z0-9_]{0,127}$`. Different from signing key label validation (`^[a-z][a-z0-9-]{0,63}$`).
- **Vault key type**: `SecureEnclave.P256.KeyAgreement.PrivateKey` (not Signing). Used for ECDH key agreement.
- **Vault file**: `~/.keypo/vault.json`, permissions 600. Uses POSIX `flock` for concurrent access safety.

### Backup/Restore Conventions

- **Two-factor key derivation**: `HKDF-SHA256(syncedKey || Argon2id(passphrase))`. Both the iCloud Keychain synced key and the passphrase are required — losing either makes the backup unrecoverable.
- **Argon2id params**: ops=3, mem=64 MB, salt=16 bytes (random), output=32 bytes. Uses the `Sodium` package (libsodium wrapper). Algorithm: `Argon2ID13`.
- **HKDF-SHA256 (backup)**: IKM = `syncedKey || argon2Output`, salt = 32 bytes (random), info = `"keypo-vault-backup-v1"`, output = 32 bytes. The info string is distinct from vault ECIES (`"keypo-vault-v1"`).
- **iCloud Keychain synced key**: Service `"com.keypo.vault-backup"`, account `"backup-encryption-key"`, `kSecAttrSynchronizable: true`, `kSecAttrAccessible: afterFirstUnlock`. 256-bit random key.
- **iCloud Drive path**: `~/Library/Mobile Documents/com~apple~CloudDocs/Keypo/vault-backup.json`.
- **Passphrase**: 4-word Diceware (EFF short wordlist), case-sensitive. Confirmation by re-entering 2 random words from the generated passphrase.
- **iCloud pre-flight**: Check `isSignedIntoICloud` and `isICloudDriveAvailable` before backup/restore. Fail fast with a clear error if either is unavailable.
- **TTY detection**: `isatty(STDIN_FILENO)` determines interactive (diff display + merge prompt) vs JSON conflict output. Terminal users always get the interactive flow.
- **Two-phase merge**: Phase A verifies HMACs for all affected vaults (triggers auth prompts — one LAContext per policy). Phase B mutates with cached LAContexts (no additional auth). This is an exception to the "one LAContext per command" rule.
- **BackupBlob version**: Currently 1. Rejects unknown versions with `unsupportedVersion` error.

## Solidity (keypo-account)

- **Override specifier**: `_rawSignatureValidation` uses `override(AbstractSigner, SignerP256)` -- NOT `override(Account, SignerP256)`.
- **WebAuthn.verify**: Use the 5-parameter version `WebAuthn.verify(..., requireUV=false)`. The 4-parameter version defaults to `requireUV=true`.
- **WebAuthn challengeIndex**: Points to the `"` (quote) before `challenge` in clientDataJSON, not to the `c` character.
- **WebAuthn encoding**: Use `abi.encode(r, s, challengeIndex, typeIndex, authenticatorData, clientDataJSON)` (flat tuple), NOT `abi.encode(struct)` which adds an outer offset.
