# CLAUDE.md -- keypo-wallet monorepo

A CLI that turns a Mac into a programmable hardware wallet using Secure Enclave P-256 keys, EIP-7702 smart account delegation, and ERC-4337 bundler submission. Three languages: Rust (CLI + crate), Swift (signer), Solidity (smart account). macOS Apple Silicon only.

## Repo Structure

| Directory | Description |
|---|---|
| `keypo-account/` | Foundry -- Solidity smart account (ERC-4337 v0.7, P-256, ERC-7821) |
| `keypo-wallet/` | Rust crate + CLI -- setup, signing, bundler, queries |
| `keypo-signer-cli/` | Swift CLI -- Secure Enclave P-256 key management |
| `homebrew/` | Homebrew tap formula |
| `deployments/` | Per-chain deployment records (JSON) |
| `tests/` | Integration tests + WebAuthn test frontend |
| `skills/` | Claude Code agent skills (npm: keypo-skills) |
| `.github/workflows/` | CI: rust.yml, swift.yml, foundry.yml, release.yml |

## Build / Test / Lint

```bash
# Rust
cd keypo-wallet && cargo check && cargo test && cargo clippy --all-targets -- -D warnings

# Swift (macOS only)
cd keypo-signer-cli && swift build && swift test

# Foundry
cd keypo-account && forge build && forge test -vvv

# Integration tests (requires .env secrets + Base Sepolia access)
cd keypo-wallet && cargo test -- --ignored --test-threads=1
```

## Documentation Map

| Doc | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System diagrams: setup flow, tx sending, paymaster |
| [docs/conventions.md](docs/conventions.md) | Coding standards, naming, API rules for all 3 languages |
| [docs/setup.md](docs/setup.md) | Dev environment, toolchain versions, .env setup |
| [docs/deployment.md](docs/deployment.md) | Contract deployment, secrets inventory, CI/CD |
| [docs/quality.md](docs/quality.md) | Test counts, coverage, known gaps |
| [docs/manual-testing.md](docs/manual-testing.md) | End-to-end manual testing checklist |
| [docs/decisions/](docs/decisions/) | Architecture Decision Records (ADRs) |
| [docs/archive/](docs/archive/) | Historical specs, roadmaps, plans |
| [docs/documentation-spec.md](docs/documentation-spec.md) | Documentation harness spec for AI agent navigation |
| [keypo-signer-cli/CLAUDE.md](keypo-signer-cli/CLAUDE.md) | Swift project: architecture, conventions, gotchas |
| [keypo-signer-cli/JSON-FORMAT.md](keypo-signer-cli/JSON-FORMAT.md) | Verified JSON output schema for all signer commands |

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
