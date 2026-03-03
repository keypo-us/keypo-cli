# keypo-wallet

ERC-4337 smart wallet with P-256 (Secure Enclave) signing, EIP-7702 delegation, and ERC-7821 batch execution.

## Monorepo Structure

| Directory | Description |
|---|---|
| `keypo-account/` | Foundry project — Solidity smart account contract (ERC-4337 v0.7) |
| `keypo-wallet/` | Rust crate + CLI — account setup, signing, bundler interaction |
| `keypo-signer-cli/` | Swift CLI — Secure Enclave P-256 key management (macOS) |
| `homebrew/` | Homebrew tap formula for keypo-signer |
| `deployments/` | Per-chain deployment records (JSON) |

## Prerequisites

- **macOS with Apple Silicon** — required for Secure Enclave signing via `keypo-signer`
- **Rust 1.91+** — required by alloy 1.7 ([install](https://rustup.rs/))
- **keypo-signer** — install via Homebrew:
  ```bash
  brew install keypo-us/tap/keypo-signer
  ```

## Getting Started

### 1. Install keypo-wallet

```bash
# Clone the repo
git clone https://github.com/keypo-us/keypo-wallet.git
cd keypo-wallet

# Build and install the CLI
cd keypo-wallet && cargo install --path .
```

This installs `keypo-wallet` to `~/.cargo/bin/`. Make sure `~/.cargo/bin` is on your PATH (rustup sets this up automatically).

Alternatively, run without installing via `cargo run --`:

```bash
cd keypo-wallet && cargo run -- setup --key my-key --rpc https://sepolia.base.org
```

### 2. Create a Secure Enclave signing key

```bash
# Create a key with biometric protection (Touch ID required to sign)
keypo-signer create --label my-key --policy biometric

# Or create a key with no auth gate (useful for testing)
keypo-signer create --label my-key --policy open
```

Verify the key was created:

```bash
keypo-signer list
```

### 3. Set up a smart account

This creates an EIP-7702 delegation from an EOA to the KeypoAccount contract and registers your P-256 public key as the account owner.

```bash
keypo-wallet setup --key my-key --rpc https://sepolia.base.org
```

The `setup` command will:
1. Look up your key's P-256 public key via `keypo-signer`
2. Generate an ephemeral secp256k1 key (the EOA)
3. Sign an EIP-7702 authorization delegating the EOA to the KeypoAccount contract
4. Send a transaction that delegates + calls `initialize(qx, qy)` to register your key
5. Save the account record to `~/.keypo/accounts.json`

**Funding:** The setup transaction requires a small amount of ETH for gas. If `TEST_FUNDER_PRIVATE_KEY` is set in your environment, the account is auto-funded. Otherwise, the CLI will print the new account address and wait for you to send ETH to it manually (e.g. from a faucet or another wallet).

### 4. Send a transaction

Transactions are submitted as ERC-4337 UserOperations via a bundler. You need a bundler URL (e.g. from [Pimlico](https://pimlico.io/)):

```bash
keypo-wallet send \
  --key my-key \
  --to 0xRecipientAddress \
  --value 1000000000000000 \
  --bundler "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_API_KEY" \
  --rpc https://sepolia.base.org
```

With a paymaster (gas sponsored — no ETH needed in the account):

```bash
keypo-wallet send \
  --key my-key \
  --to 0xRecipientAddress \
  --value 0 \
  --data 0xCalldata \
  --bundler "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_API_KEY" \
  --paymaster "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_API_KEY" \
  --rpc https://sepolia.base.org
```

### 5. Send a batch of calls

Create a JSON file with the calls:

```json
[
  {"to": "0xAddr1", "value": "0x0", "data": "0x"},
  {"to": "0xAddr2", "value": "0x38d7ea4c68000", "data": "0x1234"}
]
```

```bash
keypo-wallet batch --key my-key --calls calls.json \
  --bundler "https://..." --rpc https://sepolia.base.org
```

### 6. Check your account

```bash
# View account info (reads local state, no RPC needed)
keypo-wallet info --key my-key

# Check ETH balance
keypo-wallet balance --key my-key --rpc https://sepolia.base.org

# Check an ERC-20 token balance
keypo-wallet balance --key my-key --token 0xTokenContractAddress \
  --rpc https://sepolia.base.org
```

## CLI Commands

| Command | Description |
|---|---|
| `setup` | Set up a smart account — EIP-7702 delegation + P-256 key registration |
| `send` | Send a single transaction via the ERC-4337 bundler |
| `batch` | Send multiple calls atomically via ERC-7821 batch mode |
| `info` | Show account info from local state (no RPC) |
| `balance` | Query native ETH and ERC-20 token balances |

Use `--help` on any command for detailed usage, e.g. `keypo-wallet setup --help`.

Global flags:
- `--verbose` — enable debug logging (scoped to `keypo_wallet`)

## Development

```bash
# Rust (keypo-wallet)
cd keypo-wallet && cargo check
cd keypo-wallet && cargo test
cd keypo-wallet && cargo build

# Swift (keypo-signer-cli) — macOS only
cd keypo-signer-cli && swift build
cd keypo-signer-cli && swift test

# Foundry (keypo-account) — requires Foundry
cd keypo-account && forge build
cd keypo-account && forge test -vvv
```

### Linting

```bash
cd keypo-wallet && cargo fmt --check
cd keypo-wallet && cargo clippy --all-targets -- -D warnings
```

## Integration Tests

Integration tests require secrets in `.env` at the repo root and access to Base Sepolia. They are marked `#[ignore]` in CI and run locally:

```bash
cd keypo-wallet && cargo test -- --ignored --test-threads=1
```

The `--test-threads=1` flag prevents funder wallet nonce conflicts.

## Deployments

| Chain | Contract | Address |
|---|---|---|
| Base Sepolia (84532) | KeypoAccount | [`0x6d1566f9aAcf9c06969D7BF846FA090703A38E43`](https://sepolia.basescan.org/address/0x6d1566f9aacf9c06969d7bf846fa090703a38e43) |

The address is deterministic (CREATE2) and identical across all chains.

## Balance Query Files

The `balance` command accepts `--query <file.json>` for structured queries:

```json
{
  "chains": [84532],
  "tokens": {
    "include": ["ETH", "0xUSDC_ADDRESS"],
    "min_balance": "0.001"
  },
  "format": "table",
  "sort_by": "balance"
}
```

| Field | Description |
|---|---|
| `chains` | Array of chain IDs to query |
| `tokens.include` | Token list — `"ETH"` for native, contract addresses for ERC-20 |
| `tokens.min_balance` | Hide balances below this threshold |
| `format` | Output format: `table`, `json`, `csv` |
| `sort_by` | Sort order: `balance`, `chain`, `token` |

## Environment

Create a `.env` file at the repo root (gitignored — never commit it):

```bash
cp .env.example .env
# Then fill in your values
```

| Variable | Used by | Description |
|---|---|---|
| `PIMLICO_API_KEY` | CLI (via `--bundler` URL) | Pimlico bundler API key — used to construct the bundler URL passed to `--bundler` |
| `BASE_SEPOLIA_RPC_URL` | CLI (`--rpc`, `--bundler`) | Base Sepolia RPC/bundler endpoint |
| `PAYMASTER_URL` | CLI (`--paymaster`) | ERC-7677 paymaster endpoint for gas sponsorship |
| `PIMLICO_SPONSORSHIP_POLICY_ID` | CLI (`--paymaster-policy`) | Optional paymaster sponsorship policy ID |
| `TEST_FUNDER_PRIVATE_KEY` | CLI (`setup`) | If set, `setup` auto-funds the new account from this key instead of waiting for manual funding |
| `DEPLOYER_PRIVATE_KEY` | Foundry scripts | Private key for contract deployments (not used by the CLI) |
| `BASESCAN_API_KEY` | Foundry verify | Basescan API key for contract verification (not used by the CLI) |

The CLI reads URLs and keys from **command-line flags** (`--rpc`, `--bundler`, `--paymaster`, `--paymaster-policy`), not directly from `.env`. The `.env` file is a convenient place to store these values — you can source it or reference the variables in your shell:

```bash
# Source .env and use variables in CLI flags
source .env
keypo-wallet send --key my-key --to 0x... --value 0 \
  --bundler "$BASE_SEPOLIA_RPC_URL" \
  --paymaster "$PAYMASTER_URL" \
  --rpc https://sepolia.base.org
```

The one exception is `TEST_FUNDER_PRIVATE_KEY` — the `setup` command reads this directly from the environment. If set, it auto-funds the new account; otherwise, `setup` waits for you to manually send ETH to the account address.

Foundry (`keypo-account/`) auto-loads `.env` from its working directory via a symlink (`keypo-account/.env` → `../.env`).
