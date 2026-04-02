# CLAUDE.md -- keypo-cli monorepo

Hardware-bound key management and encrypted secret storage using Secure Enclave P-256 keys. keypo-signer (Swift) is the core product — create keys, sign digests, encrypt secrets, back up to iCloud. keypo-wallet (Rust) is an optional extension that adds ERC-4337 smart account operations. Solidity smart account contract. Apple Silicon only.

## Repo Structure

| Directory | Description |
|---|---|
| `keypo-signer/` | Swift CLI -- Secure Enclave P-256 key management, encrypted vault, iCloud backup (core product) |
| `keypo-openclaw/` | Rust CLI -- hardware-secured secrets for OpenClaw via SecretRef exec provider |
| `keypo-wallet/` | Rust crate + CLI -- ERC-4337 smart account setup, signing, bundler, queries (optional extension) |
| `keypo-account/` | Foundry -- Solidity smart account (ERC-4337 v0.7, P-256, ERC-7821) |
| `demo/hermes-checkout/` | Hermes agent demo -- comparison shopping, taste profiles, Telegram |
| `homebrew/` | Homebrew tap formula |
| `deployments/` | Per-chain deployment records (JSON) |
| `tests/` | Integration tests + WebAuthn test frontend |
| `skills/` | Claude Code agent skills (npm: keypo-skills) |
| `.github/workflows/` | CI: rust.yml, swift.yml, foundry.yml, release.yml, docs.yml |

## Build / Test / Lint

```bash
# Swift (keypo-signer — core product)
cd keypo-signer && swift build && swift test

# Rust (keypo-openclaw — OpenClaw integration)
cd keypo-openclaw && cargo check && cargo test && cargo clippy --all-targets -- -D warnings

# Rust (keypo-wallet — optional extension)
cd keypo-wallet && cargo check && cargo test && cargo clippy --all-targets -- -D warnings

# Foundry (keypo-account — smart contract)
cd keypo-account && forge build && forge test -vvv

# Integration tests (requires .env secrets + Base Sepolia access)
cd keypo-wallet && cargo test -- --ignored --test-threads=1
```

## Documentation Map

| Doc | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System diagrams: setup flow, tx sending, paymaster |
| [docs/keypo-pay-architecture.md](docs/keypo-pay-architecture.md) | keypo-pay Tempo wallet: system diagrams, tx flow, MPP |
| [docs/conventions.md](docs/conventions.md) | Coding standards, naming, API rules for all 3 languages |
| [docs/setup.md](docs/setup.md) | Dev environment, toolchain versions, .env setup |
| [docs/deployment.md](docs/deployment.md) | Contract deployment, secrets inventory, CI/CD |
| [docs/quality.md](docs/quality.md) | Test counts, coverage, known gaps |
| [docs/manual-testing.md](docs/manual-testing.md) | End-to-end manual testing checklist |
| [docs/decisions/](docs/decisions/) | Architecture Decision Records (ADRs) |
| [docs/archive/](docs/archive/) | Historical specs, roadmaps, plans |
| [docs/documentation-spec.md](docs/documentation-spec.md) | Documentation harness spec for AI agent navigation |
| [keypo-signer/CLAUDE.md](keypo-signer/CLAUDE.md) | Swift project: architecture, conventions, gotchas |
| [keypo-signer/JSON-FORMAT.md](keypo-signer/JSON-FORMAT.md) | Verified JSON output schema for all signer commands |
| [keypo-openclaw/README.md](keypo-openclaw/README.md) | OpenClaw integration: commands, provider config, vault policies |
| [docs/specs/vault-sessions-spec.md](docs/specs/vault-sessions-spec.md) | Vault sessions: scoped, time-limited secret access for agent workflows |

## Active Conventions

- **alloy 1.7**: Use `ProviderBuilder::new().connect_http(url)`. The `eip7702` feature flag does NOT exist -- EIP-7702 types are in the default `eips` feature. Do not add it.
- **ERC-7821**: Always mode byte `0x01` (batch). Single calls are a one-element batch.
- **P-256 signing**: MUST use `PrehashSigner::sign_prehash()` in Rust / `SHA256Digest` cast in Swift. See [ADR-002](docs/decisions/002-p256-prehash-signing.md). Double-hashing breaks on-chain verification.
- **Policy names**: `open` / `passcode` / `biometric`. Never `none`.
- **keypo-signer create**: Uses `--label <name>` flag, not positional argument.
- **Low-S normalization**: Mandatory on all P-256 signatures (both Rust MockSigner and Swift SecureEnclaveManager).
- **WebAuthn encoding**: Use `sig.abi_encode_params()` (flat tuple), NOT `abi.encode(struct)`.

## Current Constraints

- All phases (0-6, A-D) are complete. The codebase is stable.
- Do not refactor the EIP-7702 setup flow or paymaster gas field handling without reading the relevant ADRs.
- Integration tests MUST use `--test-threads=1` to avoid funder wallet nonce conflicts.
- `dirs = "6"` (not 5). `alloy = "1.7"` (not 0.12).

## Environment

- `.env` at repo root: secrets for Foundry and integration tests (never committed). See `.env.example`.
- `keypo-account/.env`: symlink to `../.env` (gitignored). Foundry auto-loads it.
- CLI config: `~/.keypo/config.toml` (created by `keypo-wallet init`). Resolution: CLI flag > env var > config file > error.
