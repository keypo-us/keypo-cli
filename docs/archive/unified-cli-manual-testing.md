# Unified CLI Manual Testing Checklist

Tests for the Phases A–D unified CLI implementation. Run from the repo root.

## Prerequisites

```bash
cd keypo-wallet && cargo build
# Ensure keypo-signer is installed
keypo-signer --version
```

---

## 1. `init` Command

### 1.1 Non-interactive mode
```bash
# Remove existing config if present
rm -f ~/.keypo/config.toml

cargo run -- init --rpc https://sepolia.base.org --bundler https://api.pimlico.io/v2/84532/rpc?apikey=test
```
- [ ] Prints "Config saved to ~/.keypo/config.toml"
- [ ] File exists and contains `[network]` section with both URLs

### 1.2 Interactive mode
```bash
rm -f ~/.keypo/config.toml
cargo run -- init
```
- [ ] Prompts for RPC URL (shows default `https://sepolia.base.org`)
- [ ] Pressing Enter uses the default
- [ ] Prompts for Bundler URL (required — empty input errors)
- [ ] Prompts for Paymaster URL (optional — empty input skips)
- [ ] Prints success message with next-step hint

### 1.3 Overwrite prompt
```bash
# With config already existing from 1.1 or 1.2:
cargo run -- init
```
- [ ] Asks "Config already exists… Overwrite? [y/N]"
- [ ] Typing `n` + Enter aborts without changing the file
- [ ] Typing `y` + Enter proceeds with prompts

---

## 2. `config` Commands

### 2.1 `config show`
```bash
cargo run -- config show
```
- [ ] Shows `[network]` section with values from config file
- [ ] API keys in URLs are redacted (e.g. `apikey=***`)

### 2.2 `config show --reveal`
```bash
cargo run -- config show --reveal
```
- [ ] Shows full URLs including API keys

### 2.3 `config set`
```bash
cargo run -- config set network.rpc_url https://sepolia.base.org
```
- [ ] Prints `network.rpc_url = https://sepolia.base.org`
- [ ] `config show` reflects the new value

### 2.4 `config set` — invalid key
```bash
cargo run -- config set network.foo bar
```
- [ ] Errors with "unknown config key"

### 2.5 `config set` — invalid URL
```bash
cargo run -- config set network.rpc_url not-a-url
```
- [ ] Errors with "invalid URL"

### 2.6 `config edit`
```bash
EDITOR=nano cargo run -- config edit
```
- [ ] Opens config in the editor
- [ ] After saving and exiting, prints "Config saved." if valid
- [ ] If you intentionally break the TOML, prints a warning about errors

### 2.7 `config show` with no config file
```bash
rm -f ~/.keypo/config.toml
cargo run -- config show
```
- [ ] Prints "No config file found" with hint to run `init`

---

## 3. Config Validation on Every Command

### 3.1 Malformed config blocks all commands
```bash
echo "broken [[[" > ~/.keypo/config.toml
cargo run -- info --key test
```
- [ ] Errors with "config file malformed: invalid TOML"
- [ ] Hint mentions `config edit`

### 3.2 Invalid URL in config blocks all commands
```bash
cat > ~/.keypo/config.toml << 'EOF'
[network]
rpc_url = "not-a-url"
EOF
cargo run -- info --key test
```
- [ ] Errors with "invalid URL"

Clean up after these tests:
```bash
rm -f ~/.keypo/config.toml
```

---

## 4. Config Resolution (4-tier precedence)

Set up a valid config first:
```bash
cargo run -- init --rpc https://sepolia.base.org --bundler https://bundler.example.com
```

### 4.1 CLI flag wins over config
```bash
cargo run -- setup --key test --rpc https://override.example.com
# (Will fail for other reasons, but check verbose output)
cargo run -- --verbose setup --key test --rpc https://override.example.com 2>&1 | head -5
```
- [ ] Debug log shows "KEYPO_RPC_URL resolved from CLI flag"

### 4.2 Env var wins over config
```bash
KEYPO_RPC_URL=https://env.example.com cargo run -- --verbose setup --key test 2>&1 | head -5
```
- [ ] Debug log shows "KEYPO_RPC_URL resolved from env var"

### 4.3 Config fallback
```bash
cargo run -- --verbose setup --key test 2>&1 | head -5
```
- [ ] Debug log shows "KEYPO_RPC_URL resolved from config file"

### 4.4 Missing required value
```bash
rm -f ~/.keypo/config.toml
cargo run -- setup --key test
```
- [ ] Errors with "missing required config: rpc_url"
- [ ] Hint mentions `init` or flag

---

## 5. Signer Passthrough Commands

These require `keypo-signer` to be installed.

### 5.1 `create`
```bash
cargo run -- create --label unified-test --policy open
```
- [ ] Output matches `keypo-signer create --label unified-test --policy open`

### 5.2 `list`
```bash
cargo run -- list
cargo run -- list --format json
```
- [ ] Output matches `keypo-signer list` / `keypo-signer list --format json`

### 5.3 `key-info`
```bash
cargo run -- key-info unified-test
cargo run -- key-info unified-test --format json
```
- [ ] Output matches `keypo-signer info unified-test`

### 5.4 `sign`
```bash
DIGEST="0x$(openssl rand -hex 32)"
cargo run -- sign "$DIGEST" --key unified-test
cargo run -- sign "$DIGEST" --key unified-test --format json
```
- [ ] Output matches `keypo-signer sign $DIGEST --key unified-test`

### 5.5 `verify`
```bash
# Use r/s from the sign output above
cargo run -- verify "$DIGEST" --key unified-test --r 0x... --s 0x...
```
- [ ] Output matches `keypo-signer verify`

### 5.6 `delete`
```bash
cargo run -- delete --label unified-test --confirm
```
- [ ] Key is deleted (confirm with `cargo run -- list`)

### 5.7 Signer not found
```bash
# Temporarily test with bad binary name
PATH=/nonexistent cargo run -- list 2>&1
```
- [ ] Error mentions "signer not found"
- [ ] Hint mentions `brew install`

---

## 6. `--no-paymaster` Flag

### 6.1 Send with --no-paymaster
```bash
# Set up config with paymaster
cargo run -- config set network.paymaster_url https://pm.example.com

# This will fail (no account), but verify the flag is accepted
cargo run -- send --key test --to 0x0000000000000000000000000000000000000001 --no-paymaster 2>&1
```
- [ ] Command does not error on the `--no-paymaster` flag itself
- [ ] Error is about missing account, not about paymaster

### 6.2 Batch with --no-paymaster
```bash
echo '[{"to":"0x0000000000000000000000000000000000000001","value":"0x0","data":"0x"}]' > /tmp/test-calls.json
cargo run -- batch --key test --calls /tmp/test-calls.json --no-paymaster 2>&1
```
- [ ] Command does not error on the `--no-paymaster` flag itself

---

## 7. `wallet-list` and `wallet-info`

These require an existing account in `~/.keypo/accounts.json`.

### 7.1 `wallet-list` — no accounts
```bash
# Back up and clear accounts
cp ~/.keypo/accounts.json ~/.keypo/accounts.json.bak 2>/dev/null
echo '{"accounts":[]}' > ~/.keypo/accounts.json
cargo run -- wallet-list
```
- [ ] Prints "No wallets found. Run 'keypo-wallet setup' to create one."

Restore:
```bash
mv ~/.keypo/accounts.json.bak ~/.keypo/accounts.json 2>/dev/null
```

### 7.2 `wallet-list` — with accounts
```bash
cargo run -- wallet-list
```
- [ ] Shows table with Label, Address (truncated), Chains, ETH Balance columns
- [ ] Addresses are truncated (e.g. `0xAbCd...1234`)

### 7.3 `wallet-list --no-truncate`
```bash
cargo run -- wallet-list --no-truncate
```
- [ ] Full 42-char addresses shown

### 7.4 `wallet-list --no-balance`
```bash
cargo run -- wallet-list --no-balance
```
- [ ] Balance column shows `(no RPC)` instead of querying

### 7.5 `wallet-list --format json`
```bash
cargo run -- wallet-list --format json
```
- [ ] Valid JSON with `wallets` array

### 7.6 `wallet-list --format csv`
```bash
cargo run -- wallet-list --format csv
```
- [ ] CSV with header row `label,address,chains,eth_balance,eth_balance_raw`

### 7.7 `wallet-info`
```bash
cargo run -- wallet-info --key <your-key-label>
```
- [ ] Shows Wallet, Address, Policy, Status, Public Key (x/y), Chain Deployments
- [ ] Per-chain ETH balance shown

### 7.8 `wallet-info --format json`
```bash
cargo run -- wallet-info --key <your-key-label> --format json
```
- [ ] Valid JSON with `label`, `address`, `policy`, `status`, `public_key`, `chains`

### 7.9 `wallet-info` — missing key
```bash
cargo run -- wallet-info --key nonexistent
```
- [ ] Error: "no account found for key 'nonexistent'"

---

## 8. Existing Commands Still Work

Verify no regressions in the original commands.

### 8.1 `setup` (with config)
```bash
cargo run -- init --rpc https://sepolia.base.org --bundler https://api.pimlico.io/v2/84532/rpc?apikey=$PIMLICO_API_KEY
cargo run -- setup --key <label>
```
- [ ] Setup works without explicit `--rpc` (uses config)

### 8.2 `info`
```bash
cargo run -- info --key <label>
```
- [ ] Output unchanged from before

### 8.3 `balance`
```bash
cargo run -- balance --key <label>
```
- [ ] Output unchanged from before

### 8.4 `--verbose`
```bash
cargo run -- --verbose balance --key <label>
```
- [ ] Debug logs appear on stderr

### 8.5 `--version`
```bash
cargo run -- --version
```
- [ ] Prints version

### 8.6 `--help`
```bash
cargo run -- --help
```
- [ ] Lists all commands including new ones (init, config, create, list, key-info, sign, verify, delete, rotate, wallet-list, wallet-info)

---

## 9. Edge Cases

### 9.1 Unknown config key warning
```bash
cat > ~/.keypo/config.toml << 'EOF'
[network]
rpc_url = "https://sepolia.base.org"
unknown_key = "value"
EOF
cargo run -- config show 2>&1
```
- [ ] Warning on stderr: "unknown config key 'network.unknown_key'"
- [ ] Command still succeeds (warnings are non-fatal)

### 9.2 Config with paymaster_policy_id
```bash
cargo run -- config set network.paymaster_policy_id sp_test_policy
cargo run -- config show
```
- [ ] Shows `paymaster_policy_id: sp_test_policy`

### 9.3 Env var override shown in `config show`
```bash
KEYPO_RPC_URL=https://env-override.example.com cargo run -- config show
```
- [ ] Shows `rpc_url: https://env-override.example.com (env: KEYPO_RPC_URL)`
