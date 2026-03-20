---
title: Development Environment Setup
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# Development Environment Setup

## Prerequisites

- **macOS 14+ (Sonoma)** on Apple Silicon (arm64). The Secure Enclave is required for keypo-signer.
- **Xcode** or Xcode Command Line Tools (for Swift + CryptoKit).

## Toolchain

### Rust (keypo-wallet)

Rust 1.91+ is required (alloy 1.7 dependency).

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup update
```

Verify: `rustc --version` should show 1.91.0 or later.

### Foundry (keypo-account)

Foundry 1.5.1 is used for the Solidity project.

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

**PATH note**: Foundry installs to `~/.foundry/bin/`. If `forge` is not found after install:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
```

Add this to your shell profile (`~/.zshrc`).

### Swift (keypo-signer)

Swift is included with Xcode. No additional installation needed. Verify: `swift --version`.

## Environment Variables

Copy `.env.example` to `.env` at the repo root:

```bash
cp .env.example .env
```

Fill in the following variables:

| Variable | Purpose | Required for |
|---|---|---|
| `PIMLICO_API_KEY` | Pimlico bundler + paymaster API key | Integration tests, send/batch |
| `BASE_SEPOLIA_RPC_URL` | Base Sepolia RPC endpoint (Pimlico bundler URL) | Integration tests, send/batch |
| `BASESCAN_API_KEY` | Basescan API key for contract verification | Deployment only |
| `DEPLOYER_PRIVATE_KEY` | Funded account for `forge script` deployments | Deployment only |
| `TEST_FUNDER_PRIVATE_KEY` | Pre-funded account for automated integration tests | Integration tests |
| `PAYMASTER_URL` | ERC-7677 paymaster endpoint | send/batch with paymaster |
| `PIMLICO_SPONSORSHIP_POLICY_ID` | Optional paymaster sponsorship policy | send/batch with paymaster |

The `.env` file is gitignored. `keypo-account/.env` is a symlink to `../.env` so Foundry auto-loads it.

## CLI Configuration

After building the Rust CLI, initialize the config file:

```bash
cd keypo-wallet && cargo build
./target/debug/keypo-wallet init
```

This creates `~/.keypo/config.toml` with default settings. Configuration resolution order: CLI flag > env var > config file > error.

## Running Tests

```bash
# Rust unit + bin tests (no secrets needed)
cd keypo-wallet && cargo test

# Rust integration tests (requires .env + Base Sepolia access)
cd keypo-wallet && cargo test -- --ignored --test-threads=1

# Swift tests (macOS only, some require Secure Enclave)
cd keypo-signer && swift test

# Foundry tests
cd keypo-account && forge test -vvv
```

**Integration test notes:**
- `--test-threads=1` is mandatory -- the shared funder wallet causes "replacement transaction underpriced" errors if tests run in parallel.
- `.env` must be populated with valid secrets and the funder account must have Base Sepolia ETH.
