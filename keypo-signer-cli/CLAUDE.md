---
title: keypo-signer-cli Project Guide
owner: @davidblumenfeld
last_verified: 2026-03-05
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
│   │   └── VaultDestroyCommand.swift   # vault destroy
│   └── KeypoCore/             # Library target — all SE and key management logic
│       ├── SecureEnclaveManager.swift   # SE signing key operations (create, sign, delete)
│       ├── KeyMetadataStore.swift       # ~/.keypo/keys.json read/write
│       ├── SignatureFormatter.swift     # DER parsing, r/s extraction, low-S normalization
│       ├── Models.swift                 # Codable structs for metadata and JSON output
│       ├── VaultManager.swift           # ECIES encryption/decryption, HMAC integrity, SE key lifecycle
│       ├── VaultStore.swift             # ~/.keypo/vault.json read/write, secret lookup
│       └── EnvFileParser.swift          # .env file parsing for vault import/exec
└── Tests/
    └── KeypoCoreTests/
        ├── SignatureFormatterTests.swift
        ├── VaultManagerTests.swift
        ├── VaultStoreTests.swift
        ├── VaultIntegrationTests.swift
        └── EnvFileParserTests.swift
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

6. **Metadata is a JSON file, not a database.** `~/.keypo/keys.json` stores key labels, public keys, policies, counters. No secret material. Config dir is 700, file is 600.

7. **Application tags follow the pattern `com.keypo.signer.<label>`.** This is how we look up SE keys in the Keychain.

8. **Vault: VaultManager handles crypto, VaultStore handles persistence, commands are thin wrappers.** `VaultManager` owns ECIES encryption/decryption (ECDH + HKDF-SHA256 + AES-256-GCM), HMAC integrity computation, and SE key agreement key lifecycle. `VaultStore` owns `~/.keypo/vault.json` read/write, file locking, and secret lookup across vaults. Vault command files in `keypo-signer/` are thin wrappers that parse arguments, call VaultManager/VaultStore, and format output.

9. **Vault LAContext sharing.** One `LAContext` per command invocation, passed to all `VaultManager` calls within that command. This avoids multiple Touch ID / passcode prompts for a single user action.

10. **Vault HMAC integrity verification before mutation.** Any command that mutates vault state (set, update, delete, import, destroy) MUST verify the HMAC integrity envelope before making changes. This prevents silent corruption propagation.

11. **Vault atomic writes.** All vault file writes go through `VaultStore`, which writes to a temp file then renames (same pattern as `KeyMetadataStore`).

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
- **Concurrent metadata writes.** Multiple signing processes can run in parallel. The metadata file (signing counters) needs atomic write handling — write to a temp file, then rename.
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
