# CLAUDE.md — keypo-wallet monorepo

## Monorepo Layout

```
keypo-wallet/                    # Monorepo root
├── keypo-account/               # Foundry project — Solidity smart account contract
│   ├── foundry.toml
│   ├── src/                     # Solidity sources
│   ├── test/                    # Forge tests
│   └── script/                  # Deployment scripts
├── keypo-wallet/                # Rust crate + CLI — account setup, signing, bundler interaction
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── bin/main.rs
│   │   ├── impls/               # AccountImplementation trait impls
│   │   └── abi/                 # Contract ABI JSON files
│   └── tests/
├── keypo-signer-cli/            # Swift CLI — Secure Enclave P-256 key management
│   ├── Package.swift
│   ├── Sources/
│   ├── Tests/
│   ├── README.md                # Overview, install, commands
│   └── JSON-FORMAT.md           # JSON output format reference
├── homebrew/                    # Homebrew tap (migrated from keypo-us/homebrew-tap)
│   └── Formula/keypo-signer.rb
├── deployments/                 # Per-chain deployment records (JSON)
├── tests/
│   ├── integration/             # Full-stack integration tests
│   └── webauthn-frontend/       # Test-only WebAuthn frontend
└── .github/workflows/           # CI workflows
```

## Spec Documents (archived)

- `docs/archive/specs/keypo-wallet-spec.md` — Rust crate + CLI specification
- `docs/archive/specs/keypo-account-spec.md` — Solidity smart account specification
- `docs/archive/specs/keypo-signer-spec.md` — Swift CLI specification

## Phase 0 Findings (Corrections to Specs)

### Policy name: `open` (not `none`)
keypo-signer-cli uses `open` / `passcode` / `biometric` as policy names. The specs originally referenced `none` — this has been corrected. Always use `open` when referring to the no-auth policy.

### alloy version: 1.7 (not 0.12)
The Rust crate uses `alloy = "1.7"`. EIP-7702 types are available via `alloy::eips::eip7702::*` through the default `eips` feature. The `eip7702` feature flag does not exist in alloy 1.x — do not add it.

### dirs version: 6 (not 5)
`dirs = "6"` is the current version.

### ERC-7821 batch mode
Always use mode byte `0x01` (batch mode) for ERC-7821 `execute(bytes32 mode, bytes executionData)`. Single calls are encoded as a one-element batch.

### `keypo-signer create` syntax
Uses `--label` flag (not positional): `keypo-signer create --label <name> --policy <p>`

## keypo-signer JSON Format Reference

The Rust crate's `KeypoSigner` module shells out to `keypo-signer` and parses JSON output. See `keypo-signer-cli/JSON-FORMAT.md` for the verified field mapping.

Key points:
- Public keys: uncompressed hex with `0x04` prefix (130 hex chars)
- Signatures: `r` and `s` as `0x`-prefixed 32-byte big-endian hex, low-S normalized
- Policies: `open` / `passcode` / `biometric`
- All commands support `--format json`

## Build Commands

```bash
# Swift (keypo-signer-cli)
cd keypo-signer-cli && swift build
cd keypo-signer-cli && swift test

# Rust (keypo-wallet)
cd keypo-wallet && cargo check
cd keypo-wallet && cargo test
cd keypo-wallet && cargo build

# Foundry (keypo-account) — requires Foundry installation
cd keypo-account && forge build
cd keypo-account && forge test
```

## Environment

- `.env` at repo root contains secrets (never committed)
- `.env.example` documents required variables
- `keypo-account/.env` is a symlink to `../.env` (gitignored)
- Foundry auto-loads `.env` from its working directory

## Repository History

The standalone repos `keypo-us/keypo-signer-cli` and `keypo-us/homebrew-tap` were migrated into this monorepo via `git subtree` during Phase 0. All future development happens here. The standalone repos are deprecated.
