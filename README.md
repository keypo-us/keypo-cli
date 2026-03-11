# keypo-cli

Hardware-bound key management and encrypted secret storage for AI agents. Powered by Mac Secure Enclave passkeys — no cloud, no custody, no extraction.

## Two CLI Tools

This monorepo contains two CLI tools:

| CLI | Description |
|---|---|
| **`keypo-signer`** | Secure Enclave P-256 key management + encrypted vault. The foundation layer — create keys, sign digests, store and inject secrets. |
| **`keypo-wallet`** | A programmable hardware wallet built on `keypo-signer`. Your agent can do anything on-chain but it can't see the private key. |

`keypo-wallet` includes `keypo-signer` — one install gets both binaries.

## Install

```bash
# Both tools (recommended)
brew install keypo-us/tap/keypo-wallet

# Signer only
brew install keypo-us/tap/keypo-signer
```

Run `keypo-wallet --help` or `keypo-signer --help` after installing to see available commands.

## Monorepo Structure

| Directory | Description |
|---|---|
| `keypo-account/` | Foundry project — Solidity smart account contract (ERC-4337 v0.7) |
| `keypo-wallet/` | Rust crate + CLI — account setup, signing, bundler interaction |
| `keypo-signer/` | Swift CLI — Secure Enclave P-256 key management and encrypted secret storage (macOS) |
| `homebrew/` | Homebrew tap formulas |
| `deployments/` | Per-chain deployment records (JSON) |
| `skills/` | Claude Code agent skills (npm: `keypo-skills`) |
| `docs/` | Architecture, conventions, ADRs, setup, deployment — see [CLAUDE.md](CLAUDE.md) for full index |

## Prerequisites

- **macOS with Apple Silicon** — required for Secure Enclave signing
- **Rust 1.91+** — only needed if building from source ([install](https://rustup.rs/))

## Getting Started: keypo-signer

### Create a signing key

```bash
keypo-signer create --label my-key --policy open
```

Policy options: `open` (no auth), `passcode` (device passcode), `biometric` (Touch ID).

### Sign a digest

```bash
keypo-signer sign --label my-key --digest 0x<32-byte-hex>
```

### Encrypted vault

Store secrets encrypted by Secure Enclave keys. Secrets never exist on disk in plaintext.

```bash
# Initialize vault encryption keys
keypo-signer vault init --label my-vault

# Store and retrieve secrets
keypo-signer vault set --label my-vault --name API_KEY --value sk-...
keypo-signer vault get --label my-vault --name API_KEY

# Run a command with secrets injected as environment variables
keypo-signer vault exec --label my-vault -- env
# or
keypo-signer vault exec --label my-vault -- sh -c 'echo $API_KEY'

# Import from .env file
keypo-signer vault import --label my-vault --file .env
```

The `vault exec` workflow is designed for AI agents — inject secrets into tool processes without exposing them in config files or shell history.

## Getting Started: keypo-wallet

`keypo-wallet` turns a Mac into a programmable hardware wallet. It builds on `keypo-signer` for key management and adds smart account delegation, bundler submission, and gas sponsorship.

### 0. Prerequisites

- An RPC provider URL (e.g., `https://sepolia.base.org`)
- A bundler API key/URL (Pimlico, CDP, Alchemy — any ERC-4337 bundler)
- A paymaster API key/URL (optional — for gas sponsorship)
- A small amount of testnet ETH (~$1) for initial setup gas

### 1. Install

```bash
# Via Homebrew (installs both keypo-wallet and keypo-signer)
brew install keypo-us/tap/keypo-wallet

# Upgrading from keypo-signer? Uninstall it first — keypo-wallet bundles both binaries.
# brew uninstall keypo-signer

# Or build from source
git clone https://github.com/keypo-us/keypo-cli.git
cd keypo-cli/keypo-wallet && cargo install --path .
# (keypo-signer must be installed separately: brew install keypo-us/tap/keypo-signer)
```

### 2. Configure endpoints

```bash
keypo-wallet init
# Prompts for RPC URL, bundler URL, and optional paymaster URL.
# Saves to ~/.keypo/config.toml.
```

### 3. Set up a smart account

```bash
keypo-wallet setup --key my-key --key-policy open
```

Signs an EIP-7702 delegation to the KeypoAccount contract and registers your P-256 public key as the owner. The account record is saved to `~/.keypo/accounts.json`.

**Key policies:** `open` (no auth — best for AI agents), `passcode` (device passcode), `biometric` (Touch ID).

**Funding:** Setup requires a small amount of ETH for gas. The CLI prints the address and waits for you to send ETH.

### 4. Check wallet configuration

```bash
keypo-wallet wallet-info --key my-key   # Full info with live on-chain balance
keypo-wallet info --key my-key           # Local state only (no RPC call)
keypo-wallet balance --key my-key        # ETH balance
keypo-wallet balance --key my-key --token 0xTokenAddress  # ERC-20 balance
```

### 5. Send a transaction

```bash
# Send 0.001 ETH (value is in wei)
keypo-wallet send --key my-key --to 0xRecipientAddress --value 1000000000000000
```

If `paymaster_url` is configured, transactions are gas-sponsored automatically. Add `--no-paymaster` to pay gas from the wallet's ETH balance.

## CLI Commands

### keypo-signer

| Command | Description |
|---|---|
| `create` | Create a new P-256 signing key in the Secure Enclave |
| `list` | List all signing keys |
| `key-info` | Show details for a specific key |
| `sign` | Sign a 32-byte hex digest |
| `verify` | Verify a P-256 signature |
| `delete` | Delete a signing key |
| `rotate` | Rotate a signing key |
| `vault init` | Create vault encryption keys backed by Secure Enclave |
| `vault set` / `get` / `update` / `delete` | Store, retrieve, update, and delete encrypted secrets |
| `vault list` | List all vaults and secret names |
| `vault exec` | Run a command with secrets injected as environment variables |
| `vault import` | Import secrets from a `.env` file |
| `vault destroy` | Delete all vaults, keys, and secrets |

### keypo-wallet

| Command | Description |
|---|---|
| **Config** | |
| `init` | Initialize `~/.keypo/config.toml` with RPC/bundler/paymaster URLs |
| `config set` | Set a config value (e.g. `config set network.rpc_url https://...`) |
| `config show` | Print current config |
| `config edit` | Open config file in `$EDITOR` |
| **Key management** (delegates to `keypo-signer`) | |
| `create` / `list` / `key-info` / `sign` / `verify` / `delete` / `rotate` | Same as `keypo-signer` commands above |
| **Wallet operations** | |
| `setup` | Set up a smart account — EIP-7702 delegation + P-256 key registration |
| `send` | Send a single transaction via the ERC-4337 bundler |
| `batch` | Send multiple calls atomically via ERC-7821 batch mode |
| `wallet-list` | List all wallet accounts with optional live balances |
| `wallet-info` | Show account details + on-chain status |
| `info` | Show account info from local state (no RPC) |
| `balance` | Query native ETH and ERC-20 token balances |
| **Vault** (delegates to `keypo-signer vault`) | |
| `vault init` / `set` / `get` / `update` / `delete` / `list` / `exec` / `import` / `destroy` | Same as `keypo-signer vault` commands above |

Use `--help` on any command for detailed usage, e.g. `keypo-wallet setup --help`.

Global flags:
- `--verbose` — enable debug logging (scoped to `keypo_wallet`)

## Development

```bash
# Rust (keypo-wallet)
cd keypo-wallet && cargo check
cd keypo-wallet && cargo test
cd keypo-wallet && cargo build

# Swift (keypo-signer) — macOS only
cd keypo-signer && swift build
cd keypo-signer && swift test

# Foundry (keypo-account) — requires Foundry
cd keypo-account && forge build
cd keypo-account && forge test -vvv
```

### Linting

```bash
cd keypo-wallet && cargo fmt --check
cd keypo-wallet && cargo clippy --all-targets -- -D warnings
```

## Documentation

See [CLAUDE.md](CLAUDE.md) for the documentation index and coding conventions.

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

## Skills

This repo includes [Claude Code skills](https://github.com/vercel-labs/skills) that teach AI agents how to use keypo-cli. Install all skills with:

```bash
npx skills add keypo-us/keypo-cli --full-depth
```

| Skill | Description |
|---|---|
| `keypo-wallet` | Core wallet operations — setup, send, batch, balance queries |
| `portfolio-tracker` | Discover all ERC-20 token balances via Alchemy Portfolio API |
| `contract-learner` | Generate a SKILL.md for any verified smart contract |
| `weth-base-sepolia` | Example generated skill — interact with WETH on Base Sepolia |

Generated contract skills live in `skills/contracts/`. Use the `contract-learner` skill to create new ones from any verified contract address.

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

### Config file (preferred)

The CLI reads endpoints from `~/.keypo/config.toml`, created by `keypo-wallet init`:

```toml
[network]
rpc_url = "https://sepolia.base.org"
bundler_url = "https://api.pimlico.io/v2/84532/rpc?apikey=..."
paymaster_url = "https://api.pimlico.io/v2/84532/rpc?apikey=..."
paymaster_policy_id = "sp_clever_unus"
```

### Resolution precedence

1. **CLI flag** (`--rpc`, `--bundler`, `--paymaster`, `--paymaster-policy`)
2. **Environment variable** (`KEYPO_RPC_URL`, `KEYPO_BUNDLER_URL`, `KEYPO_PAYMASTER_URL`, `KEYPO_PAYMASTER_POLICY_ID`)
3. **Config file** (`~/.keypo/config.toml`)
4. **Error** (if none of the above provide a value)

### Environment variables

| Variable | Description |
|---|---|
| `KEYPO_RPC_URL` | Standard RPC endpoint |
| `KEYPO_BUNDLER_URL` | ERC-4337 bundler endpoint |
| `KEYPO_PAYMASTER_URL` | ERC-7677 paymaster endpoint |
| `KEYPO_PAYMASTER_POLICY_ID` | Paymaster sponsorship policy ID |
| `TEST_FUNDER_PRIVATE_KEY` | If set, `setup` auto-funds the new account (read directly from env) |

### `.env` file (Foundry / integration tests)

The `.env` file at the repo root is used by Foundry and integration tests, not by the CLI directly. Variables like `PIMLICO_API_KEY`, `BASE_SEPOLIA_RPC_URL`, `DEPLOYER_PRIVATE_KEY`, and `BASESCAN_API_KEY` live there. Foundry auto-loads `.env` via a symlink (`keypo-account/.env` -> `../.env`).
