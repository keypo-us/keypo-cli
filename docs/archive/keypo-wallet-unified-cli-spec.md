# keypo-wallet Unified CLI — Specification

**Version:** 0.1.0-draft  
**Date:** 2026-03-04  
**Author:** Dave / Keypo, Inc.

---

## 1. Overview

This spec describes the unification of `keypo-wallet` and `keypo-signer` into a single installable CLI tool distributed as a Homebrew formula. The goal is a clean, zero-friction path from `brew install` to a signed on-chain transaction — no separate tool installs, no manual env var plumbing, no documentation-hunting for config.

### 1.1 Problem Statement

The current setup requires users to:

1. Install `keypo-signer` separately via a Homebrew tap
2. Build and install `keypo-wallet` from source via `cargo install`
3. Manually construct `--bundler`, `--rpc`, and `--paymaster` flag values on every command
4. Understand the relationship between two tools and their separate namespaces

This is four distinct friction points before the first transaction is possible.

### 1.2 Goals

- **One install.** `brew install keypo-us/tap/keypo-wallet` installs everything.
- **One binary.** All key management and wallet operations are available as `keypo-wallet <command>`.
- **Config-driven network endpoints.** RPC, bundler, and paymaster URLs are set once in `~/.keypo/config.toml` and never need to appear on the command line again.
- **Backward compatibility.** Existing `~/.keypo/accounts.json` state is read as-is. No migration required.

### 1.3 Non-Goals

- Replacing the `keypo-signer` Swift library internals. The Secure Enclave signing logic is unchanged; only the distribution and invocation model changes.
- Changing the smart account contract, bundler integration, or signing protocol.
- GUI or web interface.

---

## 2. Distribution — Homebrew Formula

### 2.1 Formula

The Homebrew formula lives at `keypo-us/homebrew-tap` (same tap as the existing `keypo-signer` formula). The formula name is `keypo-wallet`.

`keypo-wallet` requires Apple Silicon. The formula enforces this at install time — attempting to install on an Intel Mac produces a clear error.

```ruby
# Formula: keypo-us/homebrew-tap/Formula/keypo-wallet.rb

class KeypoWallet < Formula
  desc "ERC-4337 smart wallet CLI with Secure Enclave P-256 signing"
  homepage "https://github.com/keypo-us/keypo-wallet"
  version "X.Y.Z"

  on_arm do
    on_macos do
      url "https://github.com/keypo-us/keypo-wallet/releases/download/vX.Y.Z/keypo-wallet-aarch64-apple-darwin.tar.gz"
      sha256 "..."
    end
  end

  def install
    bin.install "keypo-wallet"
    bin.install "keypo-signer"   # Swift binary, bundled in the tarball
  end

  def caveats
    <<~EOS
      To get started:
        keypo-wallet init
    EOS
  end

  test do
    system "#{bin}/keypo-wallet", "--version"
    system "#{bin}/keypo-signer", "--version"
  end
end
```

### 2.2 Release Artifacts

Each GitHub release produces a single tarball via CI:

| Artifact | Contents |
|---|---|
| `keypo-wallet-aarch64-apple-darwin.tar.gz` | `keypo-wallet` (Rust binary), `keypo-signer` (Swift binary) |

The `keypo-signer` binary is co-installed to the same `bin/` path so the Rust binary can locate it via `PATH` exactly as it does today. The subprocess calling convention is unchanged.

### 2.3 Install Command

```bash
brew tap keypo-us/tap
brew install keypo-us/tap/keypo-wallet
```

Or, once the tap is configured:

```bash
brew install keypo-wallet
```

### 2.4 Relationship to the Standalone `keypo-signer` Formula

The existing `keypo-us/tap/keypo-signer` formula is maintained independently and is not deprecated. It remains the recommended install for users who only need Secure Enclave key management without wallet functionality. The two formulas are versioned and released together but are independent install targets.

---

## 3. Configuration File

### 3.1 Location

```
~/.keypo/config.toml
```

This file lives alongside `~/.keypo/accounts.json` (the existing account state file). The `~/.keypo/` directory is already created by `keypo-wallet setup`, so no new directory is introduced.

### 3.2 Schema

```toml
# ~/.keypo/config.toml

[network]
# RPC endpoint for reading chain state (eth_getBalance, eth_getCode, etc.)
# Required for: setup, send, batch, balance
rpc_url = "https://sepolia.base.org"

# ERC-4337 bundler endpoint
# Required for: send, batch
bundler_url = "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_API_KEY"

# ERC-7677 paymaster endpoint (optional)
# If set, all transactions request gas sponsorship unless --no-paymaster is passed
paymaster_url = "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_API_KEY"

# Paymaster sponsorship policy ID (optional, provider-specific)
paymaster_policy_id = ""
```

All fields are optional. Missing fields cause the CLI to fall back to the corresponding command-line flag, then error with a clear message if neither is provided.

### 3.3 Flag Precedence

From highest to lowest priority:

```
1. CLI flag       (--rpc, --bundler, --paymaster, --paymaster-policy)
2. Environment variable  (KEYPO_RPC_URL, KEYPO_BUNDLER_URL, KEYPO_PAYMASTER_URL, KEYPO_PAYMASTER_POLICY_ID)
3. ~/.keypo/config.toml
4. Error: required value missing
```

This means config values are always overridable per-invocation without touching the config file. The config file is a convenience layer, not a lock-in.

| Env Var | Equivalent config key |
|---|---|
| `KEYPO_RPC_URL` | `network.rpc_url` |
| `KEYPO_BUNDLER_URL` | `network.bundler_url` |
| `KEYPO_PAYMASTER_URL` | `network.paymaster_url` |
| `KEYPO_PAYMASTER_POLICY_ID` | `network.paymaster_policy_id` |

Env vars are particularly useful in CI environments where a config file is not present and secrets are injected via the environment.

### 3.4 Config Validation

On every invocation, the CLI validates `~/.keypo/config.toml` before running the requested command. Validation checks:

- **TOML syntax** — malformed TOML is a hard error with a line number and hint to run `keypo-wallet config edit`.
- **Unknown keys** — any key not in the schema produces a warning (not an error) listing the unknown key and suggesting it may be a typo.
- **URL format** — values for `rpc_url`, `bundler_url`, and `paymaster_url` must be valid `http://` or `https://` URLs. Invalid values are a hard error.

If `~/.keypo/config.toml` does not exist, validation is skipped silently. The CLI proceeds and will error only if a required value is missing for the specific command being run.

### 3.5 `keypo-wallet init`

A new `init` command creates the config file interactively on first run.

```
$ keypo-wallet init

Welcome to keypo-wallet!

This will create ~/.keypo/config.toml with your network settings.
You can edit this file at any time.

RPC URL [https://sepolia.base.org]: 
Bundler URL: https://api.pimlico.io/v2/84532/rpc?apikey=abc123
Paymaster URL (optional, press Enter to skip): 

Config written to ~/.keypo/config.toml
Next: create a signing key with `keypo-wallet create --label my-key`
```

`init` is non-destructive: if `~/.keypo/config.toml` already exists, it prompts before overwriting.

### 3.6 `keypo-wallet config set` and `keypo-wallet config show`

Two subcommands for managing config values without editing the file directly.

**`config set`** — update a single config value:

```
keypo-wallet config set <key> <value>
```

Examples:

```bash
keypo-wallet config set network.rpc_url https://sepolia.base.org
keypo-wallet config set network.bundler_url "https://api.pimlico.io/v2/84532/rpc?apikey=abc123"
keypo-wallet config set network.paymaster_url "https://api.pimlico.io/v2/84532/rpc?apikey=abc123"
keypo-wallet config set network.paymaster_policy_id ""
```

`config set` writes only the specified key — all other config values are preserved. If the config file does not exist, it is created. Invalid keys or malformed URLs are rejected before writing.

**`config show`** — print current resolved config to stdout:

```
$ keypo-wallet config show

~/.keypo/config.toml:
  network.rpc_url           = https://sepolia.base.org
  network.bundler_url       = https://api.pimlico.io/v2/84532/rpc?apikey=***
  network.paymaster_url     = (not set)
  network.paymaster_policy_id = (not set)

Environment overrides (active):
  KEYPO_BUNDLER_URL         = https://api.pimlico.io/v2/84532/rpc?apikey=***
```

API keys in URLs are redacted (replaced with `***`) in `config show` output. The `--reveal` flag disables redaction for debugging.

**`config edit`** — opens `~/.keypo/config.toml` in `$EDITOR` (fallback: `vi`):

```bash
keypo-wallet config edit
```

---

## 4. Unified Command Surface

All commands from both `keypo-wallet` and `keypo-signer` are available under a single flat namespace. The key management commands (`create`, `list`, `key-info`, `sign`, `delete`, `rotate`, `verify`) correspond 1:1 to their `keypo-signer` equivalents and delegate to the `keypo-signer` subprocess.

### 4.1 Global Flags

The following flags are accepted by every command:

| Flag | Description |
|---|---|
| `--verbose` | Enable debug-level logging. Prints RPC requests and responses, subprocess invocations, config resolution (showing which tier each value came from — flag, env var, or config file), and internal state transitions. API keys in URLs are redacted in verbose output. |
| `--help` | Print usage for the command and exit. |
| `--version` | Print the `keypo-wallet` and `keypo-signer` version strings and exit. |

`--verbose` is scoped to `keypo_wallet` log targets by default. To see subprocess output from `keypo-signer` as well, set `RUST_LOG=keypo_wallet=debug` in the environment.

### 4.2 Full Command Table

| Command | Source | Description |
|---|---|---|
| `init` | **new** | Interactive first-run config setup |
| `config set` | **new** | Update a config value |
| `config show` | **new** | Print current resolved config (with env overrides) |
| `config edit` | **new** | Open config file in `$EDITOR` |
| `create` | keypo-signer | Create a Secure Enclave P-256 signing key |
| `list` | keypo-signer | List all managed signing keys |
| `key-info` | keypo-signer | Show info for a specific key |
| `sign` | keypo-signer | Sign a raw digest with a key |
| `verify` | keypo-signer | Verify a P-256 signature |
| `delete` | keypo-signer | Delete a signing key |
| `rotate` | keypo-signer | Rotate a key (create new, re-register on-chain) |
| `setup` | keypo-wallet | EIP-7702 delegation + P-256 key registration |
| `send` | keypo-wallet | Send a single transaction via ERC-4337 bundler |
| `batch` | keypo-wallet | Send multiple calls atomically via ERC-7821 |
| `wallet-list` | **new** | List all managed wallets with balances |
| `wallet-info` | **new** | Show detailed info for a single wallet |
| `info` | keypo-wallet | Show account info from local state (retained for backward compat) |
| `balance` | keypo-wallet | Query ETH and ERC-20 balances |

### 4.3 Command Signatures

Commands that previously required `--rpc`, `--bundler`, or `--paymaster` flags on every invocation now read those values from config. The flags are retained for override purposes.

**Before:**
```bash
keypo-wallet send \
  --key my-key \
  --to 0xRecipient \
  --value 1000000000000000 \
  --bundler "https://api.pimlico.io/v2/84532/rpc?apikey=abc123" \
  --rpc https://sepolia.base.org
```

**After (with config set):**
```bash
keypo-wallet send --key my-key --to 0xRecipient --value 1000000000000000
```

Full flag reference for each command is unchanged from the existing specs except where noted below.

### 4.4 `create` (absorbed from keypo-signer)

```
keypo-wallet create --label <label> [--policy <open|passcode|biometric>]
```

Delegates to `keypo-signer create`. Output is identical to the current `keypo-signer create` output.

`--policy` defaults to `biometric`.

### 4.5 `setup` (updated)

```
keypo-wallet setup --key <label> [--rpc <url>] [--key-policy <policy>]
```

`--rpc` is now optional if `network.rpc_url` is set in config.

The `--key-policy` flag previously triggered both key creation and setup in one step. This remains supported. If the key already exists (from a prior `keypo-wallet create`), `--key-policy` is ignored with a warning.

### 4.6 `send` and `batch` (updated)

`--rpc` and `--bundler` are now optional if set in config. `--paymaster` is optional and defaults to `network.paymaster_url` from config if present.

New flag: `--no-paymaster` — explicitly disables paymaster for a single invocation even if `paymaster_url` is set in config.

---

### 4.7 `wallet-list`

```
keypo-wallet wallet-list [--rpc <url>] [--format <table|json|csv>]
```

Lists all wallets tracked in `~/.keypo/accounts.json`, one row per wallet. Fetches live ETH balances from the configured RPC endpoint.

**Example output (table, default):**

```
LABEL          ADDRESS                                      CHAINS           ETH BALANCE
my-key         0xD88E...eb80                                Base Sepolia     0.0412 ETH
work-key       0xA3F1...cc21                                Base Sepolia     0.0000 ETH
old-key        0x9B44...1f03                                Base Sepolia     0.1500 ETH
```

**Columns:**

| Column | Description |
|---|---|
| `LABEL` | The `keypo-signer` key label associated with this wallet |
| `ADDRESS` | The smart account address (truncated by default, full with `--no-truncate`) |
| `CHAINS` | Chain name(s) the account is deployed on, comma-separated |
| `ETH BALANCE` | Live ETH balance fetched via RPC. Shows `(no RPC)` if `--rpc` is not set and `network.rpc_url` is not configured |

**Flags:**

- `--rpc <url>` — override RPC for balance fetching (optional; falls back to config/env)
- `--format <table|json|csv>` — output format, default `table`
- `--no-truncate` — show full addresses instead of truncated form
- `--no-balance` — skip RPC balance fetching entirely; reads only local state from `~/.keypo/accounts.json`. Fast, works offline. ETH BALANCE column is omitted from output.

If no wallets are found in `~/.keypo/accounts.json`, prints a hint to run `keypo-wallet setup`.

---

### 4.8 `wallet-info`

```
keypo-wallet wallet-info --key <label> [--rpc <url>]
```

Shows full detail for a single wallet identified by key label. Supersedes the existing `info` command with richer output. The existing `info` command is retained for backward compatibility but `wallet-info` is the recommended path going forward.

**Example output:**

```
Wallet: my-key
─────────────────────────────────────────
Address:        0xD88E4Cb1166F9bCD3d73eA3F9C8A5c4B82aeb80
Key label:      my-key
Key policy:     biometric

Deployments:
  Base Sepolia (84532)
    Status:     active
    ETH balance: 0.0412 ETH
    Deployed:   2026-01-15T10:32:00Z
    Tx hash:    0xabc123...

P-256 Public Key:
  qx: 0x1a2b3c...
  qy: 0x4d5e6f...
```

**Flags:**

- `--key <label>` — required; key label identifying the wallet
- `--rpc <url>` — override RPC for balance fetching (optional; falls back to config/env)
- `--format <table|json>` — output format, default human-readable table

Errors with a clear message and hint if the key label is not found in local state.

---

## 5. First-Run Experience

The intended end-to-end flow after `brew install`:

```bash
# 1. Configure network endpoints
keypo-wallet init

# 2. Create a Secure Enclave key
keypo-wallet create --label my-key

# 3. Set up the smart account
keypo-wallet setup --key my-key

# 4. Send a transaction
keypo-wallet send --key my-key --to 0xRecipient --value 1000000000000000
```

Four commands, no flags after `init`, no raw URLs in the terminal.

---

## 6. Backward Compatibility

| Item | Status |
|---|---|
| `~/.keypo/accounts.json` | **Unchanged.** Existing accounts are read as-is. |
| `keypo-signer` subprocess protocol | **Unchanged.** JSON output format and command flags are identical. |
| `keypo-wallet` flag interface | **Additive only.** All existing flags continue to work. Config values are applied only when flags are absent. |
| Standalone `keypo-signer` binary | **Still installed.** Available at `$(brew --prefix)/bin/keypo-signer` for direct use or scripting. |

Users upgrading from the two-tool setup do not need to change anything. The config file is opt-in — if it doesn't exist, the CLI behaves exactly as before, requiring explicit flags on every invocation.

---

## 7. Build and Release

### 7.1 CI Matrix

| Target | Rust binary | Swift binary | Notes |
|---|---|---|---|
| `aarch64-apple-darwin` | ✅ | ✅ | Only supported target |

The Swift binary (`keypo-signer`) is compiled in the same CI job as the Rust binary and bundled into the release tarball. The monorepo already contains both — no external dependency fetch is needed at release time.

### 7.2 Version Coupling

`keypo-wallet` and `keypo-signer` are released together and share a version number. A single git tag (`vX.Y.Z`) triggers the release of both. This eliminates version skew between the two binaries.

### 7.3 Formula Update Process

Homebrew formula updates are handled via a `bump-formula-pr` step in the release workflow:

```yaml
- name: Update Homebrew formula
  run: |
    brew tap keypo-us/tap
    brew bump-formula-pr --version ${{ env.VERSION }} --url ${{ env.TARBALL_URL }} --sha256 ${{ env.SHA256 }} keypo-us/tap/keypo-wallet
```

---

## 8. Open Items

| # | Item | Notes |
|---|---|---|
| 1 | `keypo-wallet init` non-interactive mode | Should `init` also accept `--rpc`, `--bundler`, `--paymaster` flags for scripted/CI setup without prompts? Likely yes. |
| 2 | `config set` URL redaction scope | API keys embedded in bundler/paymaster URLs are redacted in `config show`. Should `config set` also confirm the written value with redaction, or echo the full URL? |
| 3 | `rotate` cross-tool flow | `rotate` touches both the Secure Enclave (new key) and the on-chain account (re-register). Needs its own subsection once implementation begins. |
