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

- **macOS** — required for Secure Enclave signing via `keypo-signer`. Development and unit testing work on Linux using `MockSigner`.
- **Rust 1.91+** — required by alloy 1.7
- **keypo-signer** — install via Homebrew:
  ```bash
  brew install keypo-us/tap/keypo-signer
  ```

## Quickstart

```bash
# 1. Set up a smart account on Base Sepolia
keypo-wallet setup --key my-key --rpc https://sepolia.base.org

# 2. Send a transaction (requires bundler)
keypo-wallet send --key my-key --to 0x... --value 0 --bundler https://...

# 3. Check balances
keypo-wallet balance --key my-key
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
