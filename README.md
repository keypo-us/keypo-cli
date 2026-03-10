# keypo-wallet

A CLI that turns your Mac into a programmable hardware wallet. Key features:

- Create wallets with different signing policies: touchID, passcode or no policy. We use raw passkeys (P-256) with the ability to extend functionality to webauthn.
- All wallet private keys are hardware bound: they never leave your mac's secure enclave. Apple can't even extract them.
- Under the hood: the wallet's use EIP-7702 (smart account) delegation. To start we are using [Open Zeppelin's implementation](https://docs.openzeppelin.com/contracts/5.x/accounts) but this can be extended to any programmable logic you can think of. Please refer to [docs/architecture.md](docs/architecture.md) for more detailed information.
- The product has 0 centralized dependencies. Key management happens locally using your secure enclave, smart contracts manage policies how how your keys can be used and an account abstraction (ERC-4337) bundler submits your transactions on your behalf. The example implementation uses Pimlico bundlers but the CLI is compatible with any popular bundler (Coinbase, Alchemy, etc). 

## Monorepo Structure

| Directory | Description |
|---|---|
| `keypo-account/` | Foundry project — Solidity smart account contract (ERC-4337 v0.7) |
| `keypo-wallet/` | Rust crate + CLI — account setup, signing, bundler interaction |
| `keypo-signer-cli/` | Swift CLI — Secure Enclave P-256 key management and encrypted secret storage (macOS) |
| `homebrew/` | Homebrew tap formula for keypo-signer |
| `deployments/` | Per-chain deployment records (JSON) |
| `skills/` | Claude Code agent skills (npm: `keypo-skills`) |
| `docs/` | Architecture, conventions, ADRs, setup, deployment -- see [CLAUDE.md](CLAUDE.md) for full index |

## Prerequisites

- **macOS with Apple Silicon** — required for Secure Enclave signing via `keypo-signer`
- **Rust 1.91+** — only needed if building from source ([install](https://rustup.rs/))

## Getting Started

### 0. Prerequisites

You'll need the following set up before installing the CLI:

- An RPC provider URL. To start you can use the Base public RPC (https://sepolia.base.org) but there are many RPC providers you can use.
- A bundler API key/URL. Lots of options here, the most popular being CDP, Alchemy and Pimlico. We used Pimlico, but any ERC4337 bundler works.
- A paymaster API key/URL (optional). If you want to sponsor gas you'll need to set this up. Most bundler platforms give you the paymaster with the same URL/API key.
- A small amount of ETH (~$1) in a seperate wallet. This is needed for paying gas to deploy the wallet during the initial setup. Since everything is on testnet for now, just grab some ETH from your favorite faucet. 

### 1. Install

```bash
# Via Homebrew (installs both keypo-wallet and keypo-signer)
brew install keypo-us/tap/keypo-wallet

# Upgrading from keypo-signer? Uninstall it first — keypo-wallet bundles both binaries.
# brew uninstall keypo-signer

# Or build from source
git clone https://github.com/keypo-us/keypo-wallet.git
cd keypo-wallet/keypo-wallet && cargo install --path .
# (keypo-signer must be installed separately: brew install keypo-us/tap/keypo-signer)
```

### 2. Configure endpoints

```bash
keypo-wallet init
# Prompts for RPC URL, bundler URL, and optional paymaster URL (if you want to sponsor the wallet's gas payments).
# Saves to ~/.keypo/config.toml — no need to pass --rpc/--bundler on every command.
```

### 3. Set up a smart account

```bash
keypo-wallet setup --key my-key --key-policy my-policy
```

This signs an EIP-7702 delegation to the KeypoAccount contract and registers your P-256 (passkey) public key as the owner. The account record is saved to `~/.keypo/accounts.json`.

**my-key** is set by the user and is the wallet identifier after setup. 

**my-policy** is the signing policy you are setting for the wallet. Options are:

- open: No restrictions on signing transactions. Best for automated tasks like giving an AI agent access to a wallet.
- passcode: All transaction signing requires entering the passcode associated with the Apple ID registered to the local Mac device. 
- bio: All transaction signing requires touchID. 

**Funding:** Setup requires a small amount of ETH for gas. The CLI prints the address and waits for you to send ETH manually. You should only need to send ~$1 of ETH. 

### 4. Check wallet configuration

```bash
keypo-wallet wallet-info --key my-key
```

Shows wallet address, key policy, P-256 public key, chain deployments and live ETH balance per chain.

Grabbing live ETH balance requires an RPC call, so the command could take a few seconds to complete. If you want faster info without getting live on-chain data, you can run:

```bash
keypo-wallet info --key my-key
```

Gives you everything that wallet-info gives (wallet address, key policy, P-256 public key and chain deployments) except live ETH balance per chain. 

You can also run:
```bash
keypo-wallet balance --key my-key        # ETH balance
keypo-wallet balance --key my-key --token 0xTokenContractAddress  # ERC-20 balance
```

### 5. Send a transaction

```bash
# Send 0.001 ETH (value is in wei)
keypo-wallet send --key my-key --to 0xRecipientAddress --value 1000000000000000
```

If `paymaster_url` is set in your config, transactions are gas-sponsored automatically — the paymaster pays for gas so your wallet doesn't need ETH for fees. To explicitly skip the paymaster and pay gas from your wallet's ETH balance, add `--no-paymaster`.

## CLI Commands

| Command | Description |
|---|---|
| **Config** | |
| `init` | Initialize `~/.keypo/config.toml` with RPC/bundler/paymaster URLs |
| `config set` | Set a config value (e.g. `config set network.rpc_url https://...`) |
| `config show` | Print current config |
| `config edit` | Open config file in `$EDITOR` |
| **Key management** (delegates to [`keypo-signer`](keypo-signer-cli/)) | |
| `create` | Create a new P-256 signing key in the Secure Enclave |
| `list` | List all signing keys |
| `key-info` | Show details for a specific key |
| `sign` | Sign a 32-byte hex digest |
| `verify` | Verify a P-256 signature |
| `delete` | Delete a signing key |
| `rotate` | Rotate a signing key |
| **Wallet operations** | |
| `setup` | Set up a smart account — EIP-7702 delegation + P-256 key registration |
| `send` | Send a single transaction via the ERC-4337 bundler |
| `batch` | Send multiple calls atomically via ERC-7821 batch mode |
| `wallet-list` | List all wallet accounts with optional live balances |
| `wallet-info` | Show account details + on-chain status |
| `info` | Show account info from local state (no RPC) |
| `balance` | Query native ETH and ERC-20 token balances |
| **Secret management** (delegates to [`keypo-signer vault`](keypo-signer-cli/)) | |
| `vault init` | Create vault encryption keys backed by Secure Enclave |
| `vault set` / `get` / `update` / `delete` | Store, retrieve, update, and delete encrypted secrets |
| `vault list` | List all vaults and secret names |
| `vault exec` | Run a command with secrets injected as environment variables |
| `vault import` | Import secrets from a `.env` file |
| `vault destroy` | Delete all vaults, keys, and secrets |

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

This repo includes [Claude Code skills](https://github.com/vercel-labs/skills) that teach AI agents how to use keypo-wallet. Install all skills with:

```bash
npx skills add keypo-us/keypo-wallet --full-depth
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

The CLI resolves each URL/setting with a 4-tier precedence:

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
