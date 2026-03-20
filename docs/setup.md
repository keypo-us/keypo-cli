---
title: Development Environment Setup
owner: "@davidblumenfeld"
last_verified: 2026-03-19
status: current
---

# Development Environment Setup

## Prerequisites

- **macOS 14+ (Sonoma)** on Apple Silicon (arm64). The Secure Enclave is required for keypo-signer.
- **Xcode** or Xcode Command Line Tools (for Swift + CryptoKit).

## Toolchain

### Swift (keypo-signer)

Swift is included with Xcode. No additional installation needed. This is the only toolchain required for keypo-signer. Verify: `swift --version`.

### Rust (keypo-wallet)

Rust 1.91+ is required (alloy 1.7 dependency). Only needed if building keypo-wallet.

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup update
```

Verify: `rustc --version` should show 1.91.0 or later.

### Foundry (keypo-account)

Foundry 1.5.1 is used for the Solidity project. Only needed for smart contract development.

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

**PATH note**: Foundry installs to `~/.foundry/bin/`. If `forge` is not found after install:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
```

Add this to your shell profile (`~/.zshrc`).

## Environment Variables

> **Note:** These environment variables are only needed for keypo-wallet, integration tests, and contract deployment. keypo-signer has no external dependencies — it works standalone with just Xcode.

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

## Vault Setup (keypo-signer)

After installing keypo-signer (or keypo-wallet, which bundles it), initialize the vault and verify it works:

```bash
# Create vault encryption keys (one per policy tier)
keypo-signer vault init

# List vaults (should show open, passcode, biometric)
keypo-signer vault list

# Store and retrieve a test secret
echo -n "test" | keypo-signer vault set TEST_KEY --vault open
keypo-signer vault get TEST_KEY
```

**Backup setup (optional):** Vault backup requires iCloud sign-in, iCloud Drive, and iCloud Keychain enabled on the Mac. Run `keypo-signer vault backup` to create the first backup — it will generate a passphrase and synced encryption key automatically.

## CLI Configuration (keypo-wallet)

After building the Rust CLI, initialize the config file:

```bash
cd keypo-wallet && cargo build
./target/debug/keypo-wallet init
```

This creates `~/.keypo/config.toml` with default settings. Configuration resolution order: CLI flag > env var > config file > error.

## Running Tests

```bash
# Swift tests (keypo-signer — some require Secure Enclave)
cd keypo-signer && swift test

# Rust unit + bin tests (keypo-wallet — no secrets needed)
cd keypo-wallet && cargo test

# Rust integration tests (requires .env + Base Sepolia access)
cd keypo-wallet && cargo test -- --ignored --test-threads=1

# Foundry tests (keypo-account)
cd keypo-account && forge test -vvv
```

**Integration test notes:**
- `--test-threads=1` is mandatory -- the shared funder wallet causes "replacement transaction underpriced" errors if tests run in parallel.
- `.env` must be populated with valid secrets and the funder account must have Base Sepolia ETH.
