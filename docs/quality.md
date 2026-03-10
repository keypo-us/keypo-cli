---
title: Test Coverage and Quality
owner: @davidblumenfeld
last_verified: 2026-03-05
status: current
---

# Test Coverage and Quality

## Test Counts

| Component | Tests | Command |
|---|---|---|
| keypo-wallet (Rust lib) | 160 | `cargo test --lib` |
| keypo-wallet (Rust bin) | 26 | `cargo test --bin keypo-wallet` |
| keypo-wallet (scaffolding) | 3 | `cargo test --test '*'` |
| keypo-wallet (integration) | 10 (ignored in CI) | `cargo test -- --ignored --test-threads=1` |
| keypo-account (Foundry) | 30 | `forge test` |
| keypo-signer-cli (Swift) | 94 | `swift test` |
| **Total (non-ignored)** | **189 Rust + 30 Foundry + 94 Swift = 313** | |

## Integration Test Requirements

- `.env` must be populated with valid secrets (see [setup.md](setup.md))
- Base Sepolia ETH must be available in the funder account
- `--test-threads=1` is mandatory to avoid funder wallet nonce conflicts
- Integration tests are `#[ignore]` in CI (no secrets available)
- Locally, integration tests can run directly (not ignored)

## Test Categories

### Rust Unit Tests (lib)
- Error types, suggestions, formatting
- ABI encoding/decoding (WebAuthn, ERC-7821, UserOp hash)
- P-256 signature verification (MockSigner, low-S normalization)
- Config resolution (4-tier precedence)
- Query formatting (table, JSON, CSV)
- Paymaster stub/data application
- Gas field packing
- UserOp hash computation (verified against 3 on-chain vectors)

### Rust Binary Tests (bin)
- CLI argument parsing for all subcommands
- Error display and suggestion formatting
- Signer passthrough command routing
- Config subcommand handling

### Foundry Tests
- P-256 signature validation (raw and WebAuthn)
- ERC-4337 v0.7 validateUserOp
- ERC-7821 execute (single and batch)
- Access control and initialization
- Edge cases (bad signatures, unauthorized callers)

### Integration Tests (ignored in CI)
- Full setup flow: key creation -> EIP-7702 delegation -> P-256 init
- Send: UserOp construction -> signing -> bundler submission -> receipt
- Balance queries against live RPC
- Paymaster-sponsored transactions

### Swift Tests (keypo-signer-cli)

| Test Suite | Tests | Description |
|---|---|---|
| SignatureFormatterTests | 21 | DER parsing, low-S normalization, r/s extraction |
| VaultManagerTests | 22 | ECIES encrypt/decrypt, HMAC integrity, key lifecycle |
| VaultStoreTests | 14 | Vault file I/O, secret lookup, file locking, atomic writes |
| VaultIntegrationTests | 22 | End-to-end vault workflows (init → set → get → update → delete → destroy) |
| EnvFileParserTests | 15 | .env parsing: quotes, comments, export prefix, BOM, dedup |
| **Total** | **94** | |

## Known Gaps

- No code coverage measurement configured (consider `cargo-tarpaulin` or `cargo-llvm-cov`)
- ~~Swift test count not tracked automatically~~ (now tracked: 94 tests)
- No fuzz testing for ABI encoding/decoding
- WebAuthn frontend tests are manual only (`tests/webauthn-frontend/`)
