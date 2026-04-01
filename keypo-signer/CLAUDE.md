---
title: keypo-signer Project Guide
owner: "@davidblumenfeld"
last_verified: 2026-03-19
status: current
---

# CLAUDE.md

## Project Overview

keypo-signer is a macOS CLI tool that manages P-256 signing keys and encrypted secrets inside the Apple Secure Enclave. It creates keys, signs data, rotates keys, deletes keys, and provides encrypted secret storage (vault). It outputs JSON by default.

The full specification is in `../docs/archive/specs/keypo-signer-spec.md`. That document is the source of truth for all behavior, output formats, exit codes, and test cases. Read it before making changes.

## Tech Stack

- **Language**: Swift
- **Build system**: Swift Package Manager
- **Minimum deployment**: macOS 14 (Sonoma), Apple Silicon only (arm64)
- **Frameworks**: CryptoKit, Security, LocalAuthentication, Foundation
- **External dependency**: swift-argument-parser (Apple)
- **No other external dependencies**

## Project Structure

```
keypo-signer/
├── Package.swift
├── CLAUDE.md
├── README.md
├── Sources/
│   ├── keypo-signer/          # Executable target — CLI entry point
│   │   ├── main.swift         # Argument parsing, command routing, output formatting
│   │   ├── CreateCommand.swift, DeleteCommand.swift, ...  # Signing key commands
│   │   ├── VaultCommand.swift          # Parent vault command (subcommand routing)
│   │   ├── VaultInitCommand.swift      # vault init
│   │   ├── VaultSetCommand.swift       # vault set
│   │   ├── VaultGetCommand.swift       # vault get
│   │   ├── VaultUpdateCommand.swift    # vault update
│   │   ├── VaultDeleteCommand.swift    # vault delete
│   │   ├── VaultListCommand.swift      # vault list
│   │   ├── VaultExecCommand.swift      # vault exec
│   │   ├── VaultImportCommand.swift    # vault import
│   │   ├── VaultDestroyCommand.swift   # vault destroy
│   │   └── Backup/
│   │       ├── BackupCommand.swift         # vault backup
│   │       ├── BackupInfoCommand.swift     # vault backup info
│   │       ├── BackupResetCommand.swift    # vault backup reset
│   │       └── RestoreCommand.swift        # vault restore (diff, merge, replace)
│   └── KeypoCore/             # Library target — all SE and key management logic
│       ├── SecureEnclaveManager.swift   # SE signing key operations (create, sign, delete)
│       ├── KeyMetadataStoring.swift      # Protocol for key metadata persistence
│       ├── KeyMetadataStore.swift       # File-based store (~/.keypo/keys.json, legacy/--config)
│       ├── KeychainMetadataStore.swift  # Keychain-backed store (default, app-scoped)
│       ├── KeyMetadataMigrator.swift    # One-time migration from file store to Keychain
│       ├── SignatureFormatter.swift     # DER parsing, r/s extraction, low-S normalization
│       ├── Models.swift                 # Codable structs for metadata and JSON output
│       ├── VaultStoring.swift            # Protocol for vault persistence + shared lookup extension
│       ├── VaultManager.swift           # ECIES encryption/decryption, HMAC integrity, SE key lifecycle
│       ├── VaultStore.swift             # File-based vault store (~/.keypo/vault.json, legacy/--config)
│       ├── KeychainVaultStore.swift     # Keychain-backed vault store (default, one item per policy tier)
│       ├── VaultMigrator.swift          # One-time migration from vault.json to Keychain
│       ├── EnvFileParser.swift          # .env file parsing for vault import/exec
│       └── Backup/
│           ├── BackupBlob.swift            # BackupPayload, BackupVault, BackupSecret models
│           ├── BackupCrypto.swift          # Argon2id + HKDF key derivation, AES-GCM encrypt/decrypt
│           ├── BackupDiff.swift            # computeRestoreDiff(), SecretRef, RestoreDiff
│           ├── BackupState.swift           # Backup nudge counter, state tracking
│           ├── iCloudDrive.swift           # iCloud Drive read/write, backup rotation
│           ├── iCloudStatus.swift          # iCloud availability pre-flight checks
│           ├── KeychainSync.swift          # iCloud Keychain synced key read/write
│           ├── PassphraseGenerator.swift   # Diceware-style passphrase generation
│           ├── PassphraseStrength.swift    # Passphrase format hint for restore prompts
│           └── Wordlist.swift              # EFF short wordlist for passphrase generation
└── Tests/
    └── KeypoCoreTests/
        ├── SignatureFormatterTests.swift
        ├── KeychainMetadataStoreTests.swift
        ├── KeyMetadataStoreTests.swift
        ├── KeyMetadataMigratorTests.swift
        ├── KeychainVaultStoreTests.swift
        ├── VaultStoreProtocolTests.swift
        ├── VaultMigratorTests.swift
        ├── VaultManagerTests.swift
        ├── VaultStoreTests.swift
        ├── VaultIntegrationTests.swift
        ├── EnvFileParserTests.swift
        ├── ExecArgsHelperTests.swift
        ├── BackupDiffTests.swift
        ├── BackupCryptoTests.swift
        ├── BackupStateTests.swift
        ├── BackupBlobTests.swift
        ├── iCloudDriveTests.swift
        ├── PassphraseGeneratorTests.swift
        └── WordlistTests.swift
```

## Build Commands

```bash
# Build
swift build

# Build release
swift build -c release

# Run
swift run keypo-signer <command>

# Run tests
swift test
```

## Architecture Rules

1. **KeypoCore is the library, keypo-signer is the thin CLI wrapper.** All Secure Enclave operations, metadata management, and signature formatting live in KeypoCore. The executable target only handles argument parsing and output formatting. This separation exists so a future GUI app or server mode can reuse KeypoCore.

2. **CryptoKit for signing, Security framework for key lifecycle.** Use `SecureEnclave.P256.Signing.PrivateKey` from CryptoKit for signing operations (it accepts pre-hashed input, avoiding double-hash). Use Security framework (`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`) for key storage and lookup in the Keychain. Use `SecAccessControlCreateWithFlags` for policy creation.

3. **Pre-hashed signing only.** The CLI accepts hex-encoded data and signs it directly. No hashing is applied by the tool. This is critical — callers pass already-hashed data and double-hashing would break verification.

4. **Low-S normalization is mandatory.** After every sign operation, check if s > curve_order/2 and replace with curve_order - s if so. The P-256 curve order is `0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551`.

5. **Three access control policies: open, passcode, biometric.** These map to SecAccessControl flags. The policy is set at key creation and is immutable. Only signing is gated by the policy (hardware-enforced). Delete and rotate are not gated by the key's policy.

6. **Signing key metadata is stored in the macOS Keychain** using `kSecClassGenericPassword` items scoped to the app's access group (`FWJKHZ4TZD.com.keypo.signer`). The `dataRepresentation` (opaque SE token) is stored as `kSecValueData`; all other metadata (publicKey, policy, counters, etc.) is stored as a JSON-encoded `Data` blob in `kSecAttrGeneric`. The `--config` flag falls back to the legacy file-based store (`~/.keypo/keys.json`). On first run, keys.json is auto-migrated to Keychain and renamed to `keys.json.migrated`.

7. **`updateKey` vs `replaceKey`.** `updateKey` updates metadata but MUST NOT change `dataRepresentation` (the SE token). It throws `storeError` if the caller passes a different token. For key rotation (which produces a new SE key), use `replaceKey` — this atomically replaces the entire entry including the SE token. The error type for both stores is `KeypoError.storeError(String)`.

8. **Application tags follow the pattern `com.keypo.signer.<label>`.** This is how we look up SE keys in the Keychain.

9. **Vault: VaultManager handles crypto, VaultStoring handles persistence, commands are thin wrappers.** `VaultManager` owns ECIES encryption/decryption (ECDH + HKDF-SHA256 + AES-256-GCM), HMAC integrity computation, and SE key agreement key lifecycle. The `VaultStoring` protocol abstracts persistence — `KeychainVaultStore` (default) stores one `kSecClassGenericPassword` item per policy tier in the Keychain scoped to `FWJKHZ4TZD.com.keypo.signer`; `VaultStore` (legacy/`--config`) uses `~/.keypo/vault.json`. On first run, vault.json is auto-migrated to Keychain and renamed to `vault.json.migrated`. The `findSecret`, `allSecretNames`, and `isNameGloballyUnique` methods are protocol extension methods shared by both stores.

10. **Vault LAContext sharing.** One `LAContext` per command invocation, passed to all `VaultManager` calls within that command. This avoids multiple Touch ID / passcode prompts for a single user action.

11. **Vault HMAC integrity verification before mutation.** Any command that mutates vault state (set, update, delete, import, destroy) MUST verify the HMAC integrity envelope before making changes. This prevents silent corruption propagation.

12. **Vault atomic writes.** File store: writes to a temp file then renames (same pattern as `KeyMetadataStore`). Keychain store: per-item SecItemUpdate/SecItemAdd is atomic; multi-tier saves are not transactional (acceptable for single-user CLI). `SecItemDelete` with broad queries may only delete one item per call on macOS — vault uses per-tier deletion. Vault Keychain items have a 50 KB size limit per tier.

13. **Restore two-phase merge.** `vault restore` with merge verifies HMACs in Phase A (may trigger auth prompts for passcode/biometric vaults), then mutates in Phase B using cached LAContexts. This is an exception to rule 10's "one LAContext per command" — merge creates one LAContext per policy because different policies require independent authentication.

14. **TTY detection for interactive vs JSON output.** `vault restore` uses `isatty(STDIN_FILENO)` to determine whether to show the interactive diff/prompt or emit JSON conflict output. This ensures terminal users always get the interactive flow even when `--format json` is the default.

## Coding Conventions

- Use Foundation's `JSONEncoder` / `JSONDecoder` for all JSON. Set `outputFormatting` to `[.prettyPrinted, .sortedKeys]` for JSON output mode.
- All errors go to stderr. All structured output goes to stdout.
- Exit codes are specified per-command in the spec. Use them exactly.
- Label validation: lowercase alphanumeric and hyphens, must start with a letter, 1-64 chars. Regex: `^[a-z][a-z0-9-]{0,63}$`
- Public keys are output as uncompressed hex with `0x04` prefix (130 hex chars total).
- Signatures are output as hex with `0x` prefix.
- Timestamps are ISO 8601 with timezone (use `ISO8601DateFormatter`).
- The `--format raw` flag outputs bare hex with no newline wrapper or JSON.
- The `--format pretty` flag outputs human-readable text, not JSON.
- Handle errors gracefully — never crash on bad input, missing files, or missing SE keys.

## Key Gotchas

- **SecKeyCreateSignature hashes the input.** Do NOT use it. Use CryptoKit's `SecureEnclave.P256.Signing.PrivateKey.signature(for:)` instead. This is the single most important implementation detail.
- **SecItemDelete does not respect the key's access control policy.** Any process that knows the application tag can delete a key. This is by design — we don't gate delete behind the key's policy.
- **ECDSA signatures are non-deterministic.** Signing the same data twice produces different signatures. Both are valid. Tests must account for this.
- **`.biometryCurrentSet` invalidates the key if biometrics change.** If a user re-enrolls their fingerprint, biometric-policy keys become permanently inaccessible. This is intentional Apple behavior.
- **Concurrent metadata writes.** Multiple signing processes can run in parallel. Keychain store: individual operations are atomic per-item; `incrementSignCount` has a read-modify-write race (acceptable — counter is informational). File store: uses flock for serialization.
- **`kSecReturnData` + `kSecMatchLimitAll` returns errSecParam (-50)** on some macOS versions. `loadKeys` works around this by querying attributes only, then fetching each key individually via `findKey`.
- **SE key lookup.** Use `SecItemCopyMatching` with `kSecAttrApplicationTag` set to `com.keypo.signer.<label>` to find keys. Set `kSecAttrTokenID` to `kSecAttrTokenIDSecureEnclave` to ensure we only match SE keys.
- **Vault uses KeyAgreement keys, not Signing keys.** Vault encryption uses `SecureEnclave.P256.KeyAgreement.PrivateKey` (for ECDH), NOT `SecureEnclave.P256.Signing.PrivateKey`. These are different key types with different Keychain application tags (`com.keypo.vault.<policy>` vs `com.keypo.signer.<label>`).
- **ECDH authentication cancellation detection.** LAContext cancellation during ECDH throws errors that need both code `-2` check AND string-based fallback detection (the error domain varies across macOS versions).

## Testing

Tests are defined in ../docs/archive/specs/keypo-signer-spec.md. **You MUST pass ALL tests in Categories 1-6 before the implementation is considered complete.** These are automated tests using open-policy keys and can run without human interaction. Do not move on to new features or optimizations until every test in Categories 1-6 passes.

Category 7 requires human interaction (passcode and biometric policies) and will be run manually by the developer.

For unit tests in `KeypoCoreTests`, use `--config` to isolate test state in a temp directory. Prefix all test key labels with `test-`.

The two most critical tests are:
1. **T2.2** — Signature verifies with an external tool (openssl or Python ecdsa). This proves standards compliance.
2. **T6.7** — Cross-verification with openssl. Same idea but with explicit PEM conversion steps.

If these two tests pass, the signing output is correct.

## Distribution

- Homebrew tap: `keypo/homebrew-tap`
- Binary: arm64 only (Apple Silicon required for SE)
- Code-signed and notarized for Gatekeeper
- Formula test: `keypo-signer info --system` (works without SE)
