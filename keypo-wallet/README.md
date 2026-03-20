---
title: keypo-wallet (Rust Crate + CLI)
owner: "@davidblumenfeld"
last_verified: 2026-03-20
status: current
---

# keypo-wallet

Optional extension for keypo-signer that adds on-chain smart account capabilities. Turns a Mac into a programmable hardware wallet — your agent can do anything on-chain but can't see the private key. Built on EIP-7702 delegation, ERC-4337 bundler submission, and ERC-7677 gas sponsorship. Shells out to `keypo-signer` for all Secure Enclave operations.

## Install

```bash
# Via Homebrew (installs both keypo-wallet and keypo-signer)
brew install keypo-us/tap/keypo-wallet

# Or build from source
git clone https://github.com/keypo-us/keypo-cli.git
cd keypo-cli/keypo-wallet && cargo install --path .
```

## Quick Start

```bash
# Initialize config with RPC + bundler endpoints
keypo-wallet init

# Create a Secure Enclave signing key
keypo-wallet create --label my-key --policy open

# Set up a smart account (EIP-7702 delegation + P-256 key registration)
keypo-wallet setup --key my-key

# Send a transaction (value in wei)
keypo-wallet send --key my-key --to 0xRecipient --value 1000000000000000

# Check balance
keypo-wallet balance --key my-key
```

## Commands

### Wallet Operations

| Command | Description |
|---|---|
| `setup` | Set up a smart account — EIP-7702 delegation + P-256 key registration |
| `send` | Send a single transaction via the ERC-4337 bundler |
| `batch` | Send multiple calls atomically via ERC-7821 batch mode |
| `wallet-list` | List all wallet accounts with optional live balances |
| `wallet-info` | Show account details + on-chain status |
| `info` | Show account info from local state (no RPC call) |
| `balance` | Query native ETH and ERC-20 token balances |

### Configuration

| Command | Description |
|---|---|
| `init` | Initialize `~/.keypo/config.toml` with RPC/bundler/paymaster URLs |
| `config set` | Set a config value (e.g. `config set network.rpc_url https://...`) |
| `config show` | Print current config (API keys redacted unless `--reveal`) |
| `config edit` | Open config file in `$EDITOR` |

### Key Management (delegates to keypo-signer)

| Command | Description |
|---|---|
| `create` | Create a new P-256 signing key in the Secure Enclave |
| `list` | List all signing keys |
| `key-info` | Show details for a specific key |
| `sign` | Sign a 32-byte hex digest |
| `verify` | Verify a P-256 signature |
| `delete` | Delete a signing key |
| `rotate` | Rotate a signing key |

### Vault (delegates to keypo-signer vault)

All `keypo-signer vault` commands are available through `keypo-wallet vault` — init, set, get, update, delete, list, exec, import, destroy, backup, restore.

## Batch Mode

Send multiple calls in a single atomic UserOperation using ERC-7821:

```bash
# From a file
keypo-wallet batch --key my-key --calls calls.json

# From stdin
echo '[{"to":"0x...","value":"0x0","data":"0x..."}]' | keypo-wallet batch --key my-key --calls -
```

Each call object has `to` (address), `value` (hex wei), and `data` (hex calldata).

## Gas Sponsorship

If a paymaster URL is configured, transactions are gas-sponsored automatically:

```bash
# Configure paymaster
keypo-wallet config set network.paymaster_url "https://api.pimlico.io/v2/84532/rpc?apikey=..."
keypo-wallet config set network.paymaster_policy_id "sp_clever_unus"

# Send with sponsorship (automatic)
keypo-wallet send --key my-key --to 0x... --value 1000000000000000

# Opt out for a single transaction
keypo-wallet send --key my-key --to 0x... --value 1000000000000000 --no-paymaster
```

Implements ERC-7677 (`pm_getPaymasterStubData` / `pm_getPaymasterData`).

## Balance Queries

```bash
# Native ETH
keypo-wallet balance --key my-key

# Specific ERC-20 token
keypo-wallet balance --key my-key --token 0xUSDC_ADDRESS

# Structured query from file
keypo-wallet balance --key my-key --query query.json
```

Query files support chain filtering, token lists, minimum balance thresholds, output format (table/json/csv), and sort order. See the [root README](../README.md#balance-query-files) for the full schema.

## Configuration

**Config file:** `~/.keypo/config.toml` (created by `keypo-wallet init`)

```toml
[network]
rpc_url = "https://sepolia.base.org"
bundler_url = "https://api.pimlico.io/v2/84532/rpc?apikey=..."
paymaster_url = "https://api.pimlico.io/v2/84532/rpc?apikey=..."
paymaster_policy_id = "sp_clever_unus"
```

**Resolution precedence:** CLI flag > environment variable > config file > error.

| Environment Variable | Description |
|---|---|
| `KEYPO_RPC_URL` | Standard RPC endpoint |
| `KEYPO_BUNDLER_URL` | ERC-4337 bundler endpoint |
| `KEYPO_PAYMASTER_URL` | ERC-7677 paymaster endpoint |
| `KEYPO_PAYMASTER_POLICY_ID` | Paymaster sponsorship policy ID |
| `TEST_FUNDER_PRIVATE_KEY` | Auto-fund new accounts during setup (test only) |

## State Files

| File | Purpose |
|---|---|
| `~/.keypo/config.toml` | RPC, bundler, paymaster endpoints |
| `~/.keypo/accounts.json` | Smart account records (address, key label, chain deployments) |
| `~/.keypo/keys.json` | Signing key metadata (managed by keypo-signer) |
| `~/.keypo/vault.json` | Encrypted vault secrets (managed by keypo-signer) |

## Key Modules

| Module | Purpose |
|---|---|
| `account.rs` | EIP-7702 setup flow — delegation, key registration, funding |
| `transaction.rs` | UserOp construction + ERC-7821 batch execution |
| `bundler.rs` | ERC-7769 bundler client (estimate gas, send UserOp, get receipt) |
| `signer.rs` | P-256 signer trait + keypo-signer subprocess integration |
| `config.rs` | 4-tier config resolution (CLI flag > env > file > error) |
| `query.rs` | Balance queries, multi-format output (table/json/csv) |
| `paymaster.rs` | ERC-7677 paymaster client (stub data + signed data) |
| `state.rs` | Account state persistence (`~/.keypo/accounts.json`) |

## Build and Test

```bash
cargo check
cargo test
cargo clippy --all-targets -- -D warnings

# Integration tests (requires .env + Base Sepolia)
cargo test -- --ignored --test-threads=1
```

## Global Flags

- `--verbose` — enable debug logging (scoped to `keypo_wallet`)
- `--help` on any command for detailed usage

## How It Works

1. **Setup:** Creates a Secure Enclave P-256 key (via keypo-signer), generates an ephemeral secp256k1 EOA, signs an EIP-7702 delegation to the KeypoAccount contract, and registers the P-256 public key as owner. The ephemeral key is discarded after setup.

2. **Sending:** Builds an ERC-4337 UserOperation, signs the UserOp hash with the P-256 key (via keypo-signer → Secure Enclave), and submits to the bundler. The bundler packages it into a regular transaction, and the EntryPoint verifies the P-256 signature on-chain.

3. **Security:** The private key never leaves the Secure Enclave hardware. keypo-wallet only works with public keys, hashes, and signatures. All signing happens through keypo-signer as a subprocess.

See [architecture overview](../docs/architecture.md) for detailed flow diagrams.

## References

- [Root README](../README.md) — full system overview and getting started
- [Architecture overview](../docs/architecture.md) — setup, send, and paymaster flow diagrams
- [Coding conventions](../docs/conventions.md) — alloy API rules, signing rules, gotchas
- [Root CLAUDE.md](../CLAUDE.md) — repo map and conventions summary
- [Full specification](../docs/archive/specs/keypo-wallet-spec.md)
