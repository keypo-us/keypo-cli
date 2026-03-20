---
title: Manual Testing Checklist
owner: "@davidblumenfeld"
last_verified: 2026-03-19
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
cargo run -- wallet-list --no-balance
cargo run -- wallet-list --format json
cargo run -- wallet-list --format csv
```

- [ ] No accounts: prints "No wallets found" with hint
- [ ] Table shows Label, Address, Chains, ETH Balance
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

## 7. Vault Commands

Requires `keypo-signer` with vault support. All vault commands are subcommands of `keypo-signer vault`.

### 7.1 Init + Set + Get

```bash
keypo-signer vault init
echo -n "test-secret-value" | keypo-signer vault set MY_SECRET --vault open
keypo-signer vault get MY_SECRET
keypo-signer vault get MY_SECRET --format json
```

- [ ] `vault init` creates keys for all three policies (open, passcode, biometric)
- [ ] `vault set` stores secret without error
- [ ] `vault get` prints the decrypted value to stdout
- [ ] `vault get --format json` returns `name`, `vault`, `value` fields

### 7.2 Update

```bash
echo -n "updated-value" | keypo-signer vault update MY_SECRET
keypo-signer vault get MY_SECRET
```

- [ ] `vault update` succeeds
- [ ] `vault get` returns the updated value

### 7.3 List

```bash
keypo-signer vault list
keypo-signer vault list --format json
```

- [ ] Lists all vaults with secret names (no values shown)
- [ ] JSON output includes `vaults` array with `policy`, `secrets`, `secretCount`

### 7.4 Exec

```bash
keypo-signer vault exec -- env | grep MY_SECRET
keypo-signer vault exec -- sh -c 'echo $MY_SECRET'
```

- [ ] Secret is available as environment variable in subprocess
- [ ] Exit code matches child process exit code

### 7.5 Import

Create a test `.env` file:
```bash
echo 'IMPORT_KEY_1=value1
IMPORT_KEY_2=value2' > /tmp/test-vault-import.env
keypo-signer vault import --file /tmp/test-vault-import.env --vault open
keypo-signer vault import --file /tmp/test-vault-import.env --vault open --format json
```

- [ ] First import succeeds, imports both keys
- [ ] Second import skips both (already exist)
- [ ] JSON output shows `imported` and `skipped` arrays with counts

### 7.6 Delete

```bash
keypo-signer vault delete MY_SECRET --confirm
keypo-signer vault get MY_SECRET
```

- [ ] Delete succeeds
- [ ] Subsequent get returns exit code 2 (not found)

### 7.7 Destroy

```bash
keypo-signer vault destroy --confirm
keypo-signer vault list
```

- [ ] Destroy succeeds, reports vaults destroyed and secrets deleted
- [ ] Subsequent list returns exit code 1 (not initialized)

### 7.8 Biometric + Passcode Policies

```bash
keypo-signer vault init
echo -n "bio-secret" | keypo-signer vault set BIO_KEY --vault biometric
keypo-signer vault get BIO_KEY
echo -n "pass-secret" | keypo-signer vault set PASS_KEY --vault passcode
keypo-signer vault get PASS_KEY
```

- [ ] Touch ID prompt appears for biometric vault set/get
- [ ] Passcode prompt appears for passcode vault set/get
- [ ] Cancelling auth returns appropriate exit code (see exit code table)

### 7.9 Backup & Restore

#### 7.9.1 Backup + Restore (clean slate)

```bash
keypo-signer vault init
echo -n "val1" | keypo-signer vault set SECRET_A --vault open
echo -n "val2" | keypo-signer vault set SECRET_B --vault passcode
keypo-signer vault backup
keypo-signer vault destroy --confirm
keypo-signer vault restore
keypo-signer vault get SECRET_A
keypo-signer vault get SECRET_B
```

- [ ] Backup succeeds, shows passphrase (record it)
- [ ] Restore prompts for passphrase
- [ ] Both secrets are restored with correct values

#### 7.9.2 Restore with existing vault — diff display

```bash
keypo-signer vault init
echo -n "local-only" | keypo-signer vault set LOCAL_SECRET --vault open
echo -n "shared" | keypo-signer vault set SHARED_SECRET --vault open
keypo-signer vault backup
keypo-signer vault delete SHARED_SECRET --confirm
echo -n "new-local" | keypo-signer vault set NEW_LOCAL --vault open
keypo-signer vault restore
```

- [ ] Diff shows LOCAL_SECRET and NEW_LOCAL as "local only"
- [ ] Diff shows SHARED_SECRET as "backup only" (was deleted locally after backup)
- [ ] Four options displayed: cancel / replace / merge / back up first

#### 7.9.3 Cancel (choice 1)

- [ ] Select cancel at the restore prompt
- [ ] Vault unchanged — `vault list` shows same secrets as before restore

#### 7.9.4 Replace (choice 2)

- [ ] Select replace at the restore prompt
- [ ] Old vault destroyed, all backup secrets restored
- [ ] `vault list` shows only the secrets from the backup

#### 7.9.5 Merge (choice 3)

- [ ] Select merge at the restore prompt
- [ ] Backup-only secrets added to local vault
- [ ] Local-only secrets preserved
- [ ] HMAC integrity valid (`vault get` works on all secrets)

#### 7.9.6 Back up first (choice 4)

- [ ] Select "back up first" at the restore prompt
- [ ] Prints guidance to run `vault backup` first, then exits
- [ ] Vault unchanged

#### 7.9.7 Merge with passcode/biometric secrets

```bash
keypo-signer vault init
echo -n "bio" | keypo-signer vault set BIO_SECRET --vault biometric
keypo-signer vault backup
keypo-signer vault destroy --confirm
keypo-signer vault init
echo -n "local" | keypo-signer vault set LOCAL_NEW --vault open
keypo-signer vault restore
# Select merge
```

- [ ] Auth prompt appears for biometric vault during merge
- [ ] Merge succeeds, both BIO_SECRET and LOCAL_NEW accessible

#### 7.9.8 Merge with auth cancellation

- [ ] Cancel Touch ID / passcode prompt during merge
- [ ] Vault unchanged, error message displayed

#### 7.9.9 Backup info

```bash
keypo-signer vault backup info
keypo-signer vault backup info --format json
```

- [ ] Shows backup exists, creation date, device name, secret count
- [ ] Shows count of local secrets not backed up
- [ ] JSON output includes all `VaultBackupInfoOutput` fields

#### 7.9.10 Restore --previous

```bash
keypo-signer vault backup   # first backup
# Add more secrets, then:
keypo-signer vault backup   # second backup (rotates first to "previous")
keypo-signer vault destroy --confirm
keypo-signer vault restore --previous
```

- [ ] Restores from the first (previous) backup, not the latest

#### 7.9.11 Wrong passphrase

```bash
keypo-signer vault restore
# Enter incorrect passphrase
```

- [ ] Decryption fails with helpful error message
- [ ] Vault unchanged

---

## 8. Vault Error Flows

### 8.1 Pre-Init Errors

```bash
keypo-signer vault destroy --confirm 2>/dev/null  # ensure clean state
keypo-signer vault set FAIL --vault open <<< "value"
keypo-signer vault get FAIL
keypo-signer vault list
```

- [ ] `vault set` exits 1 (not initialized)
- [ ] `vault get` exits 1 (not initialized)
- [ ] `vault list` exits 1 (not initialized)

### 8.2 Duplicate Secret

```bash
keypo-signer vault init
echo -n "val" | keypo-signer vault set DUPE --vault open
echo -n "val2" | keypo-signer vault set DUPE --vault open
```

- [ ] Second set exits 3 (already exists)
- [ ] Error message names the duplicate secret

### 8.3 Not Found

```bash
keypo-signer vault get NONEXISTENT
keypo-signer vault update NONEXISTENT <<< "val"
keypo-signer vault delete NONEXISTENT --confirm
```

- [ ] All exit code 2 (not found)

### 8.4 Invalid Secret Names

```bash
echo -n "val" | keypo-signer vault set "123bad" --vault open
echo -n "val" | keypo-signer vault set "" --vault open
echo -n "val" | keypo-signer vault set "has spaces" --vault open
```

- [ ] All exit code 2 (invalid name)
- [ ] Error message explains valid name format

### 8.5 Empty Value

```bash
echo -n "" | keypo-signer vault set EMPTY --vault open
```

- [ ] Exits 5 (empty value)

### 8.6 Missing --confirm

```bash
keypo-signer vault delete MY_SECRET
keypo-signer vault destroy
```

- [ ] `vault delete` exits 3 (--confirm missing)
- [ ] `vault destroy` exits 2 (--confirm missing)

### 8.7 Authentication Cancellation

```bash
# Test with biometric vault — cancel Touch ID when prompted
echo -n "val" | keypo-signer vault set CANCEL_TEST --vault biometric
# Cancel Touch ID prompt
```

- [ ] Exits with auth cancelled exit code (4 for most commands, 7 for set, 128 for exec)

---

## Cleanup

```bash
rm -f ~/.keypo/config.toml
# Optionally delete test keys:
keypo-signer delete --label test-manual --confirm
keypo-signer delete --label unified-test --confirm
# Clean up vault state:
keypo-signer vault destroy --confirm
```
