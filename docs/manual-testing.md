---
title: Manual Testing Checklist
owner: @davidblumenfeld
last_verified: 2026-03-05
status: current
---

# Manual Testing Checklist

End-to-end tests for the keypo-wallet unified CLI. Requires macOS with Secure Enclave and Base Sepolia ETH.

## Prerequisites

- macOS with Touch ID / Secure Enclave (Apple Silicon)
- `keypo-signer` installed (`brew install keypo-us/tap/keypo-signer`) and on PATH
- `keypo-wallet` built (`cd keypo-wallet && cargo build`)
- `.env` populated with `PIMLICO_API_KEY`, `BASE_SEPOLIA_RPC_URL`, `PAYMASTER_URL`
- Base Sepolia ETH available (faucet or existing funded account)

---

## 1. Core Wallet Commands

### 1.1 Full Setup + Send

```bash
keypo-signer create --label test-manual --policy biometric
cargo run -- setup --key test-manual --rpc https://sepolia.base.org
cargo run -- info --key test-manual
cargo run -- send --key test-manual \
  --to <ACCOUNT_ADDRESS> --value 0 \
  --bundler $BASE_SEPOLIA_RPC_URL --paymaster $PAYMASTER_URL
```

- [ ] Setup completes with address, tx hash, chain ID
- [ ] Info shows correct address and chain deployment
- [ ] Send returns UserOp hash, tx hash, success=true

### 1.2 Paymaster-Sponsored Transaction

```bash
cargo run -- send --key test-manual \
  --to 0x0000000000000000000000000000000000000001 --value 0 \
  --bundler $BASE_SEPOLIA_RPC_URL --paymaster $PAYMASTER_URL \
  --paymaster-policy $PIMLICO_SPONSORSHIP_POLICY_ID
```

- [ ] Transaction succeeds without account holding ETH for gas
- [ ] Block explorer shows paymaster paid gas

### 1.3 Batch Transaction

Create `test-batch.json`:
```json
[
  {"to": "0x0000000000000000000000000000000000000001", "value": "0x0", "data": "0x"},
  {"to": "0x0000000000000000000000000000000000000002", "value": "0x0", "data": "0x"}
]
```

```bash
cargo run -- batch --key test-manual \
  --calls test-batch.json \
  --bundler $BASE_SEPOLIA_RPC_URL --paymaster $PAYMASTER_URL

# Or via stdin:
cat test-batch.json | cargo run -- batch --key test-manual \
  --calls - \
  --bundler $BASE_SEPOLIA_RPC_URL --paymaster $PAYMASTER_URL
```

- [ ] Batch transaction succeeds
- [ ] Both calls executed in a single on-chain transaction

### 1.4 Balance Queries

```bash
cargo run -- balance --key test-manual
cargo run -- balance --key test-manual --format json
cargo run -- balance --key test-manual --format csv
cargo run -- balance --key test-manual --rpc https://sepolia.base.org
```

- [ ] Table output shows aligned columns with chain, token, balance
- [ ] JSON output is valid JSON with account address and balances array
- [ ] CSV output has proper header row and quoted fields

### 1.5 Error Scenarios

```bash
cargo run -- info --key nonexistent-key
cargo run -- send --key test-manual --to not-an-address --bundler $BASE_SEPOLIA_RPC_URL
cargo run -- --verbose balance --key test-manual --rpc https://sepolia.base.org
```

- [ ] Missing key: error with hint to run `setup`
- [ ] Bad address: error with "invalid --to address"
- [ ] Missing signer binary: error with Homebrew install hint
- [ ] `--verbose` shows debug output scoped to `keypo_wallet`
- [ ] Error messages include actionable hints where applicable

---

## 2. Config Commands

### 2.1 `init` -- Non-interactive

```bash
rm -f ~/.keypo/config.toml
cargo run -- init --rpc https://sepolia.base.org --bundler https://api.pimlico.io/v2/84532/rpc?apikey=test
```

- [ ] Prints "Config saved to ~/.keypo/config.toml"
- [ ] File contains `[network]` section with both URLs

### 2.2 `init` -- Interactive

```bash
rm -f ~/.keypo/config.toml
cargo run -- init
```

- [ ] Prompts for RPC URL (shows default)
- [ ] Enter accepts default
- [ ] Prompts for Bundler URL (required)
- [ ] Prompts for Paymaster URL (optional, empty skips)

### 2.3 `init` -- Overwrite prompt

```bash
cargo run -- init
```

- [ ] Asks "Config already exists... Overwrite? [y/N]"
- [ ] `n` aborts, `y` proceeds

### 2.4 `config show` / `config show --reveal`

```bash
cargo run -- config show
cargo run -- config show --reveal
```

- [ ] API keys redacted by default
- [ ] `--reveal` shows full URLs

### 2.5 `config set`

```bash
cargo run -- config set network.rpc_url https://sepolia.base.org
cargo run -- config set network.foo bar
cargo run -- config set network.rpc_url not-a-url
```

- [ ] Valid key+value: prints updated value, `config show` reflects it
- [ ] Unknown key: errors with "unknown config key"
- [ ] Invalid URL: errors with "invalid URL"

### 2.6 `config edit`

```bash
EDITOR=nano cargo run -- config edit
```

- [ ] Opens config in editor
- [ ] Valid TOML on save: prints "Config saved."
- [ ] Broken TOML on save: prints warning

### 2.7 `config show` -- No config file

```bash
rm -f ~/.keypo/config.toml
cargo run -- config show
```

- [ ] Prints "No config file found" with hint to run `init`

---

## 3. Signer Passthrough Commands

Requires `keypo-signer` installed.

```bash
cargo run -- create --label unified-test --policy open
cargo run -- list
cargo run -- list --format json
cargo run -- key-info unified-test
cargo run -- key-info unified-test --format json
DIGEST="0x$(openssl rand -hex 32)"
cargo run -- sign "$DIGEST" --key unified-test
cargo run -- sign "$DIGEST" --key unified-test --format json
cargo run -- verify "$DIGEST" --key unified-test --r 0x... --s 0x...
cargo run -- delete --label unified-test --confirm
```

- [ ] `create` output matches `keypo-signer create`
- [ ] `list` / `list --format json` output matches `keypo-signer list`
- [ ] `key-info` output matches `keypo-signer info`
- [ ] `sign` / `sign --format json` output matches `keypo-signer sign`
- [ ] `verify` output matches `keypo-signer verify`
- [ ] `delete` removes the key (confirm with `list`)

### 3.1 Signer Not Found

```bash
PATH=/nonexistent cargo run -- list 2>&1
```

- [ ] Error mentions "signer not found"
- [ ] Hint mentions `brew install`

---

## 4. Query Commands

### 4.1 `wallet-list`

```bash
# No accounts
echo '{"accounts":[]}' > ~/.keypo/accounts.json
cargo run -- wallet-list
# Restore accounts, then:
cargo run -- wallet-list
cargo run -- wallet-list --no-truncate
cargo run -- wallet-list --no-balance
cargo run -- wallet-list --format json
cargo run -- wallet-list --format csv
```

- [ ] No accounts: prints "No wallets found" with hint
- [ ] Table shows Label, Address (truncated), Chains, ETH Balance
- [ ] `--no-truncate`: full 42-char addresses
- [ ] `--no-balance`: balance column shows `(no RPC)`
- [ ] `--format json`: valid JSON with `wallets` array
- [ ] `--format csv`: header row `label,address,chains,eth_balance,eth_balance_raw`

### 4.2 `wallet-info`

```bash
cargo run -- wallet-info --key <label>
cargo run -- wallet-info --key <label> --format json
cargo run -- wallet-info --key nonexistent
```

- [ ] Shows Wallet, Address, Policy, Status, Public Key (x/y), Chain Deployments
- [ ] Per-chain ETH balance shown
- [ ] `--format json`: valid JSON with `label`, `address`, `policy`, `status`, `public_key`, `chains`
- [ ] Missing key: error "no account found for key 'nonexistent'"

---

## 5. Config Resolution (4-tier precedence)

```bash
cargo run -- init --rpc https://sepolia.base.org --bundler https://bundler.example.com
```

### 5.1 CLI flag wins over config

```bash
cargo run -- --verbose setup --key test --rpc https://override.example.com 2>&1 | head -5
```

- [ ] Debug log shows "resolved from CLI flag"

### 5.2 Env var wins over config

```bash
KEYPO_RPC_URL=https://env.example.com cargo run -- --verbose setup --key test 2>&1 | head -5
```

- [ ] Debug log shows "resolved from env var"

### 5.3 Config fallback

```bash
cargo run -- --verbose setup --key test 2>&1 | head -5
```

- [ ] Debug log shows "resolved from config file"

### 5.4 Missing required value

```bash
rm -f ~/.keypo/config.toml
cargo run -- setup --key test
```

- [ ] Error: "missing required config: rpc_url"
- [ ] Hint mentions `init` or flag

### 5.5 Malformed config

```bash
echo "broken [[[" > ~/.keypo/config.toml
cargo run -- info --key test
```

- [ ] Error: "config file malformed: invalid TOML"
- [ ] Hint mentions `config edit`

### 5.6 Invalid URL in config

```bash
printf '[network]\nrpc_url = "not-a-url"\n' > ~/.keypo/config.toml
cargo run -- info --key test
```

- [ ] Error: "invalid URL"

### 5.7 Env var override in `config show`

```bash
KEYPO_RPC_URL=https://env-override.example.com cargo run -- config show
```

- [ ] Shows `rpc_url: https://env-override.example.com (env: KEYPO_RPC_URL)`

---

## 6. Edge Cases

### 6.1 `--no-paymaster` flag

```bash
cargo run -- config set network.paymaster_url https://pm.example.com
cargo run -- send --key test --to 0x0000000000000000000000000000000000000001 --no-paymaster 2>&1
cargo run -- batch --key test --calls /tmp/test-calls.json --no-paymaster 2>&1
```

- [ ] Flag accepted without error
- [ ] Errors are about missing account, not paymaster

### 6.2 Unknown config key warning

```bash
cat > ~/.keypo/config.toml << 'EOF'
[network]
rpc_url = "https://sepolia.base.org"
unknown_key = "value"
EOF
cargo run -- config show 2>&1
```

- [ ] Warning on stderr: "unknown config key 'network.unknown_key'"
- [ ] Command still succeeds (non-fatal)

### 6.3 Backward compatibility

```bash
cargo run -- setup --key <label>
cargo run -- info --key <label>
cargo run -- balance --key <label>
cargo run -- --verbose balance --key <label>
cargo run -- --version
cargo run -- --help
```

- [ ] `setup` works without explicit `--rpc` (uses config)
- [ ] `info` output unchanged
- [ ] `balance` output unchanged
- [ ] `--verbose` shows debug logs on stderr
- [ ] `--version` prints version
- [ ] `--help` lists all commands including new ones

---

## Cleanup

```bash
rm -f ~/.keypo/config.toml
# Optionally delete test keys:
keypo-signer delete --label test-manual --confirm
keypo-signer delete --label unified-test --confirm
```
