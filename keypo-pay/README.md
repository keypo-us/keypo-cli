# keypo-pay

Secure Enclave wallet for the Tempo blockchain. Uses Apple's Secure Enclave P-256 keys as native Tempo account keys, with a root-key-plus-access-keys architecture that lets autonomous agents transact within user-defined limits without repeated biometric prompts.

## What it does

- **Hardware-bound keys**: P-256 signing keys live in the Secure Enclave and never leave the device
- **Root + access key model**: A biometric-gated root key delegates scoped spending authority to open-policy access keys
- **Agent-ready**: Access keys have per-token spending limits and expiry, enforced by the Tempo protocol itself
- **MPP payments**: Built-in client for the Machine Payments Protocol (402 challenge-response flow)
- **Testnet-ready**: Pre-configured for Tempo's moderato testnet with faucet integration

## Getting Started

### Prerequisites

- **macOS with Apple Silicon** (required for Secure Enclave)
- **Rust 1.91+** ([install](https://rustup.rs/))
- **keypo-signer** installed:
  ```bash
  brew install keypo-us/tap/keypo-signer
  ```

### 1. Build and install

```bash
cd keypo-pay
cargo install --path .
```

This puts `keypo-pay` in `~/.cargo/bin/` (should already be in your PATH).

### 2. Create a wallet

```bash
# Production (Touch ID required for root key operations)
keypo-pay wallet create

# Test mode (no biometric prompt, for automated testing)
keypo-pay wallet create --test
```

This generates a P-256 root key in the Secure Enclave, derives your Tempo address, and saves config to `~/.keypo/tempo/`.

### 3. Fund the wallet

The wallet needs tokens to transact. On testnet, use the faucet:

```bash
curl -X POST https://rpc.moderato.tempo.xyz \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tempo_fundAddress","params":["YOUR_ADDRESS"],"id":1}'
```

Replace `YOUR_ADDRESS` with the address from `keypo-pay wallet info`. This gives you 1M of each testnet stablecoin.

### 4. Check your balance

```bash
# All tokens
keypo-pay balance

# Specific token
keypo-pay balance --token pathusd
```

### 5. Create an access key for your agent

```bash
# Create the key locally (open policy, no biometric)
keypo-pay access-key create --name shopping-agent

# Authorize it on-chain with a spending limit
keypo-pay access-key authorize --name shopping-agent --token pathusd --limit 10.00

# Verify it's active
keypo-pay access-key info --name shopping-agent
```

### 6. Send tokens

```bash
# Using an access key (subject to spending limits)
keypo-pay send --to 0xRecipientAddress --amount 0.50 --key shopping-agent

# Using the root key (bypasses limits, requires biometric)
keypo-pay send --to 0xRecipientAddress --amount 100.00 --use-root-key

# Specify a different token (defaults to pathusd)
keypo-pay send --to 0xRecipientAddress --amount 1.00 --token alphausd --key shopping-agent
```

### 7. Pay for MPP-enabled services

```bash
keypo-pay pay https://api.example.com/resource --key shopping-agent
```

This handles the full 402 challenge-response flow: parse the payment challenge, submit a TIP-20 transfer on-chain, and retry the request with proof of payment.

### 8. Manage access keys

```bash
# List all keys with on-chain status
keypo-pay access-key list

# Revoke an access key (root key signs)
keypo-pay access-key revoke --name shopping-agent

# Update a spending limit
keypo-pay access-key update-limit --name shopping-agent --token pathusd --limit 25.00

# Delete local entry (warn if still authorized on-chain)
keypo-pay access-key delete --name shopping-agent
```

### 9. Manage the token address book

```bash
keypo-pay token list
keypo-pay token add --name mytoken --address 0xTokenContractAddress
keypo-pay token remove --name mytoken
```

Token names can be used anywhere a `--token` flag is accepted instead of hex addresses.

## CLI Reference

| Command | Description |
|---|---|
| `wallet create [--test]` | Create a new wallet (root key + config) |
| `wallet info` | Show address, root key, chain ID, access keys |
| `send --to <addr> --amount <n> --key <name>` | Transfer tokens using an access key |
| `send --to <addr> --amount <n> --use-root-key` | Transfer tokens using root key (no limits) |
| `balance [--token <name>]` | Query token balances |
| `tx send --to <addr> --token <t> --amount <n>` | Low-level transaction (defaults to root key) |
| `access-key create --name <n>` | Create a new access key locally |
| `access-key authorize --name <n> --token <t> --limit <l>` | Authorize on-chain with spending limits |
| `access-key list` | List all access keys with status |
| `access-key info --name <n>` | Detailed info with remaining limits |
| `access-key revoke --name <n>` | Revoke on-chain |
| `access-key update-limit --name <n> --token <t> --limit <l>` | Update spending limit |
| `access-key delete --name <n>` | Remove local entry |
| `token add/remove/list` | Manage token address book |
| `pay <url> --key <name>` | MPP charge flow (402 challenge-response) |

Global flags: `--rpc <url>` (override RPC endpoint), `--verbose` (debug logging).

## Resetting the Wallet

To start fresh, use the built-in reset command:

```bash
keypo-pay wallet reset
```

This will:
1. Show you what will be deleted (address, root key, access keys)
2. Warn about any on-chain access keys that will become unrevocable
3. Ask you to type `reset` to confirm
4. Delete all Secure Enclave keys (root + access keys)
5. Delete the config directory (`~/.keypo/tempo/`)

After reset, create a new wallet with `keypo-pay wallet create`.

Note: if you only deleted the config files (e.g., `rm -rf ~/.keypo/tempo`) without resetting, `wallet create` will detect the existing Secure Enclave key and reuse it automatically.

## Configuration

Config lives in `~/.keypo/tempo/`:

| File | Contents |
|---|---|
| `wallet.toml` | Chain ID, RPC URL, root key ID, address |
| `access-keys.toml` | Named access keys with key IDs and addresses |
| `tokens.toml` | Token address book (pre-populated with testnet tokens) |

### Resolution precedence

CLI flag > environment variable (`KEYPO_PAY_RPC_URL`) > config file

## Testnet Info

| | |
|---|---|
| **Chain** | Tempo Moderato Testnet |
| **Chain ID** | 42431 |
| **RPC** | `https://rpc.moderato.tempo.xyz` |
| **Explorer** | `https://explore.moderato.tempo.xyz` |
| **Faucet** | `tempo_fundAddress` JSON-RPC method |
| **Stablecoins** | pathUSD, AlphaUSD, BetaUSD, ThetaUSD (6 decimals) |

## Development

```bash
cd keypo-pay
cargo check            # type-check
cargo test             # run all tests
cargo clippy --all-targets -- -D warnings   # lint
cargo build --release  # optimized build
```
