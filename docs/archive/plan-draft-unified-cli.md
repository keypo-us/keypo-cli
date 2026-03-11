# Unified CLI Implementation Plan

**Spec:** `keypo-wallet-unified-cli-spec.md`
**Date:** 2026-03-04

---

## Summary

This plan implements the unified CLI spec in 5 phases, ordered by dependency. Each phase is independently testable and produces a working intermediate state. Total estimated new/modified files: ~8 Rust source files, 1 CI workflow, 1 Homebrew formula.

---

## Phase A: Config Module + `toml` Dependency

**Goal:** Add `~/.keypo/config.toml` support — parse, validate, resolve values with the 4-tier precedence (CLI flag > env var > config file > error).

### A.1 Add dependencies

Add to `keypo-wallet/Cargo.toml`:
```toml
toml = "0.8"
```

Note: `url = "2"` is already in `Cargo.toml` and is used for URL validation in config.

### A.2 New module: `src/config.rs`

Create `keypo-wallet/src/config.rs` with:

```rust
// Core types
pub struct Config {
    pub rpc_url: Option<String>,
    pub bundler_url: Option<String>,
    pub paymaster_url: Option<String>,
    pub paymaster_policy_id: Option<String>,
}

// TOML schema (serde)
#[derive(Deserialize, Serialize)]
struct ConfigFile {
    network: Option<NetworkConfig>,
}

#[derive(Deserialize, Serialize)]
struct NetworkConfig {
    rpc_url: Option<String>,
    bundler_url: Option<String>,
    paymaster_url: Option<String>,
    paymaster_policy_id: Option<String>,
}
```

**Key functions:**
- `config_path() -> PathBuf` — returns `~/.keypo/config.toml`
- `load_config() -> Result<Option<Config>>` — loads and validates config file; returns `None` if file doesn't exist, `Err` on malformed TOML or invalid URLs
- `validate_config(raw: &str) -> Result<Config>` — TOML syntax check, unknown key warnings (via `toml::Value` comparison), URL format validation for `*_url` fields
- `resolve_value(cli: Option<&str>, env_var: &str, config: Option<&str>) -> Option<String>` — implements the 4-tier precedence
- `resolve_rpc(cli: Option<&str>, config: &Option<Config>) -> Result<String>` — resolves `rpc_url` with error if missing
- `resolve_bundler(cli: Option<&str>, config: &Option<Config>) -> Result<String>` — resolves `bundler_url` with error if missing
- `resolve_paymaster(cli: Option<&str>, no_paymaster: bool, config: &Option<Config>) -> Option<String>` — resolves `paymaster_url`, returns `None` if `--no-paymaster`
- `resolve_paymaster_policy(cli: Option<&str>, config: &Option<Config>) -> Option<String>` — resolves `paymaster_policy_id`
- `save_config(config: &Config) -> Result<()>` — atomic write (tmp + rename) to `~/.keypo/config.toml`
- `set_config_value(key: &str, value: &str) -> Result<()>` — loads existing config, updates one key, saves. Validates key name against known schema, validates URL format for URL keys.
- `redact_url(url: &str) -> String` — replaces `apikey=...` and similar query params with `***`
- `format_config_show(config: &Option<Config>, reveal: bool) -> String` — formats config + env override display

**Validation details:**
- Unknown key detection: parse TOML to `toml::Value`, walk keys, compare against known set `{network.rpc_url, network.bundler_url, network.paymaster_url, network.paymaster_policy_id}`. Print warnings to stderr for unknowns.
- URL validation: parse with `url::Url` (already a dependency), check scheme is `http` or `https`.
- Config **validation** runs on **every invocation** (per spec Section 3.4), if the file exists. This is a cheap, side-effect-free check: TOML syntax, unknown key warnings, URL format. A malformed config is a hard error even on signer passthrough commands — this catches broken config early.
- Config **value resolution** (requiring specific fields like `rpc_url`, `bundler_url`) only happens in network-requiring commands (setup, send, batch, balance, wallet-list, wallet-info). Signer passthrough commands validate the config but never require any values from it.
- If `~/.keypo/config.toml` does not exist, validation is skipped silently on all commands.

**Environment variables:**
- `KEYPO_RPC_URL`
- `KEYPO_BUNDLER_URL`
- `KEYPO_PAYMASTER_URL`
- `KEYPO_PAYMASTER_POLICY_ID`

### A.3 Register module in `lib.rs`

Add `pub mod config;` to `keypo-wallet/src/lib.rs`.

### A.4 Tests (~20)

All in `config.rs`:
- `load_config_missing_file_returns_none`
- `load_config_empty_file_returns_defaults`
- `load_config_full_file_parses`
- `load_config_malformed_toml_errors`
- `load_config_invalid_url_errors`
- `load_config_unknown_keys_warns` (capture stderr or use a warning collector)
- `resolve_value_cli_wins`
- `resolve_value_env_wins_over_config`
- `resolve_value_config_fallback`
- `resolve_value_all_none`
- `resolve_rpc_required_errors_when_missing`
- `resolve_bundler_required_errors_when_missing`
- `resolve_paymaster_no_paymaster_flag`
- `resolve_paymaster_from_config`
- `set_config_value_creates_file`
- `set_config_value_updates_existing`
- `set_config_value_rejects_unknown_key`
- `set_config_value_rejects_invalid_url`
- `redact_url_apikey`
- `redact_url_no_key_unchanged`
- `format_config_show_redacted`
- `format_config_show_reveal`

---

## Phase B: CLI Structure (`init`, `config`, Signer Passthrough) + Config Wiring

**Goal:** Add all new command variants to the clap `Commands` enum, implement `init`, `config`, and the 7 signer passthrough commands, and wire config resolution into existing commands. `wallet-list` and `wallet-info` variants are added to the enum here but their handlers are stubbed — full implementation is in Phase C.

### B.1 Expand `Commands` enum in `src/bin/main.rs`

Add new variants:

```rust
enum Commands {
    // --- NEW ---
    Init { ... },
    Config { #[command(subcommand)] action: ConfigAction },
    Create { label: String, policy: Option<String> },
    List { format: Option<String> },
    KeyInfo { label: String, format: Option<String> },
    Sign { digest: String, key: String, format: Option<String> },
    Verify { ... },
    Delete { label: String, confirm: bool },
    Rotate { label: String, ... },
    WalletList { rpc: Option<String>, format: Option<String>, no_truncate: bool, no_balance: bool },
    WalletInfo { key: String, rpc: Option<String>, format: Option<String> },

    // --- EXISTING (modified) ---
    Setup { ... + --rpc becomes optional },
    Send { ... + no_paymaster: bool },
    Batch { ... + no_paymaster: bool },
    Info { ... },
    Balance { ... },
}

enum ConfigAction {
    Set { key: String, value: String },
    Show { reveal: bool },
    Edit,
}
```

### B.2 `init` handler

New function `run_init()`:
1. Check if `~/.keypo/config.toml` exists. If yes, prompt "Config already exists. Overwrite? [y/N]".
2. Read stdin for RPC URL (default: `https://sepolia.base.org`), bundler URL (required), paymaster URL (optional).
3. Call `config::save_config()`.
4. Print success message with next-step hint.

Non-interactive mode: if `--rpc` and `--bundler` are provided as flags, skip prompts. (Resolves Open Item #1.)

```rust
Init {
    #[arg(long)]
    rpc: Option<String>,
    #[arg(long)]
    bundler: Option<String>,
    #[arg(long)]
    paymaster: Option<String>,
}
```

**Testability:** The interactive prompt logic is extracted into a library function in `config.rs`:
```rust
pub fn run_init_interactive(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    config_path: &Path,
    overwrite: bool,
) -> Result<Config>
```
This takes `impl BufRead` for input and `impl Write` for output, enabling unit tests to provide mock stdin without relying solely on the non-interactive flag path. The CLI handler in `main.rs` calls this with `stdin().lock()` and `stdout()`.

### B.3 `config` handlers

- `config set <key> <value>` — calls `config::set_config_value()`. Validates key and value before writing. Echoes the written value with redaction (resolves Open Item #2 — show redacted).
- `config show [--reveal]` — calls `config::format_config_show()`, prints to stdout.
- `config edit` — reads `$EDITOR` (fallback `vi`), spawns it with `~/.keypo/config.toml` path. Creates file with template if it doesn't exist. After the editor exits, validates the TOML and prints a warning to stderr if the edited file is malformed, but does not revert the file. The user can run `config edit` again to fix it. This matches the `git commit` / `$EDITOR` convention.

### B.4 Signer passthrough commands

Each signer command delegates to `KeypoSigner` subprocess. The pattern is:

```rust
fn run_create(label: &str, policy: &str) -> Result<()> {
    let signer = KeypoSigner::new();
    // For create: call keypo-signer create --label <label> --policy <policy>
    // Print output directly (passthrough)
}
```

For `create`, `list`, `key-info`, `sign`, `delete`, `rotate`, `verify`: shell out to `keypo-signer` with matching args. The Rust binary acts as a thin proxy. Output is passed through to stdout unchanged.

**Implementation approach:** Add a new method to `KeypoSigner` in `signer.rs`:
```rust
/// Runs a keypo-signer command with inherited I/O (stdout/stderr go directly to terminal).
/// Args are forwarded verbatim — no `--format json` injection.
/// Returns Ok(()) on exit code 0, Err on non-zero or spawn failure.
pub fn run_raw(&self, args: &[&str]) -> Result<()> {
    let status = std::process::Command::new(&self.binary)
        .args(args)
        .status()  // inherits stdin/stdout/stderr
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                Error::SignerNotFound(self.binary.clone())
            } else {
                Error::SignerCommand(format!("failed to run {}: {}", self.binary, e))
            }
        })?;
    if !status.success() {
        // stderr already printed to terminal by the child process
        std::process::exit(status.code().unwrap_or(1));
    }
    Ok(())
}
```
Key differences from existing `run_command()`: uses `.status()` instead of `.output()` so I/O is inherited (not captured), does not append `--format json`, and on non-zero exit propagates the child's exit code directly (since stderr was already shown to the user).

**Decision:** Use `run_raw()` for maximum compatibility. The unified CLI acts as a transparent proxy for signer commands. Users get exactly the same output as calling `keypo-signer` directly.

**`--format` forwarding:** The `--format` flag on passthrough commands (`list --format json`, `key-info --format raw`, `sign --format raw`, etc.) is forwarded verbatim to `keypo-signer` as an argument. The Rust binary does **not** interpret or validate the `--format` value — `keypo-signer` owns format handling for its commands. This preserves compatibility with all `keypo-signer` format modes (`json`, `pretty`, `raw`).

### B.5 `wallet-list` and `wallet-info` stubs

The `WalletList` and `WalletInfo` command variants are added to the `Commands` enum in B.1, but their match arms call `todo!("implemented in Phase C")` or return a clear "not yet implemented" error. This keeps Phase B focused on the config wiring and signer passthrough. Full handlers are wired in Phase C.

### B.6 Wire config resolution into existing commands

Modify `main()` and command handlers:
1. **Validate config on every invocation** — call `config::load_and_validate()` early in `main()`, before command dispatch. This returns `Option<Config>` (None if file missing, Err on malformed). Validation runs for all commands per spec Section 3.4.
2. **Resolve values only in network commands** — `run_setup`, `run_send`, `run_batch`, `run_balance`, `run_wallet_list`, `run_wallet_info` call `config::resolve_rpc()`, `config::resolve_bundler()`, etc. Signer passthrough, `init`, `config`, and `info` receive the validated config but never resolve network values from it.
3. Add `--no-paymaster` flag to `Send` and `Batch` commands. `Setup` does NOT get `--no-paymaster` — the setup flow uses a direct EIP-7702 type-4 transaction, not a UserOp, so it never uses a paymaster regardless of config. Only Send/Batch (which go through the ERC-4337 bundler) need the opt-out flag.

**Key change in `run_setup`:**
```rust
// Before:
let rpc_url = rpc.ok_or("--rpc is required for setup")?;
// After:
let rpc_url = config::resolve_rpc(rpc.as_deref(), &config)?;
```

**Key change in `resolve_account_and_chain`:** After applying CLI overrides, also apply config fallbacks for bundler/paymaster/rpc if the stored deployment values are `None`.

### B.7 `--version` update

Modify `--version` to also print `keypo-signer` version by running `keypo-signer --version` and including its output. Handle the case where `keypo-signer` is not installed (print warning, not error).

### B.8 Tests (~15)

In `src/bin/main.rs` tests (arg parsing):
- `init_args_parse`
- `init_args_non_interactive`
- `config_set_args_parse`
- `config_show_args_parse`
- `config_edit_args_parse`
- `create_args_parse`
- `list_args_parse`
- `key_info_args_parse`
- `sign_args_parse`
- `delete_args_parse`
- `wallet_list_args_parse`
- `wallet_list_no_balance_flag`
- `wallet_info_args_parse`
- `send_no_paymaster_flag`
- `batch_no_paymaster_flag`

---

## Phase C: `wallet-list` and `wallet-info` — Handlers + Query Logic

**Goal:** Implement the full handlers and query/formatting logic for the two new wallet commands. Replace the Phase B stubs with working implementations.

### C.1 Wire handlers in `src/bin/main.rs`

Replace the Phase B stubs with full handler functions:

**`run_wallet_list()`:**
1. Load config (for RPC resolution).
2. Open `StateStore`.
3. If no accounts, print hint: "No wallets found. Run 'keypo-wallet setup' to create one."
4. For each account, optionally fetch ETH balance via RPC (skip if `--no-balance`).
5. Format as table/json/csv using formatters from `query.rs`.

Uses `query::query_native_balance()` for live balances. Address truncation controlled by `--no-truncate` flag (uses `short_address()` by default). RPC is optional — if not configured and `--no-balance` is not set, shows `(no RPC)` in the balance column.

**`run_wallet_info()`:**
1. Load config (for RPC resolution).
2. Open `StateStore`, find account by key label.
3. Fetch ETH balance per chain deployment.
4. Format detailed output including P-256 public key coordinates.

### C.2 New functions in `src/query.rs`

```rust
// wallet-list formatting
pub fn format_wallet_list_table(accounts: &[WalletListEntry], truncate: bool) -> String
pub fn format_wallet_list_json(accounts: &[WalletListEntry]) -> String
pub fn format_wallet_list_csv(accounts: &[WalletListEntry]) -> String

// wallet-info formatting
pub fn format_wallet_info(account: &AccountRecord, balances: &[(u64, U256)]) -> String
pub fn format_wallet_info_json(account: &AccountRecord, balances: &[(u64, U256)]) -> String
```

### C.3 Type changes in `src/types.rs`

**New type:**
```rust
pub struct WalletListEntry {
    pub label: String,
    pub address: Address,
    pub chains: Vec<String>,   // chain display names
    pub eth_balance: Option<U256>,  // None if --no-balance
}
```

**Add `tx_hash` to `ChainDeployment`:**
```rust
pub struct ChainDeployment {
    // ... existing fields ...
    #[serde(default)]
    pub tx_hash: Option<String>,  // setup tx hash, None for pre-existing records
}
```
Uses `#[serde(default)]` so existing `accounts.json` files deserialize without error (old records get `None`). The `setup()` flow in `account.rs` is updated to populate this field when creating new deployments.

**`wallet-info` status derivation:** The spec shows `Status: active`. This is derived, not stored — if a `ChainDeployment` record exists, the status is `active`. No new field needed. Future states (e.g., `revoked` after key rotation) would add a stored field later.

### C.4 Tests (~10)

- `format_wallet_list_table_basic`
- `format_wallet_list_table_no_truncate`
- `format_wallet_list_table_no_balance`
- `format_wallet_list_table_empty`
- `format_wallet_list_json_structure`
- `format_wallet_list_csv_structure`
- `format_wallet_info_basic`
- `format_wallet_info_json_structure`
- `format_wallet_info_with_balances`
- `format_wallet_info_multiple_chains`

---

## Phase D: Error Module Updates + Integration Polish

**Goal:** Update error types, suggestions, and ensure the full command flow works end-to-end.

### D.1 New error variants in `src/error.rs`

```rust
#[error("config file malformed: {0}")]
ConfigParse(String),

#[error("missing required config: {0}")]
ConfigMissing(String),
```

Two specific variants instead of a generic `Config(String)` — each has its own suggestion text and makes match arms unambiguous.

### D.2 Update `suggestion()` in `src/error.rs`

Add suggestions for new error variants:
- `ConfigParse` -> "Run 'keypo-wallet config edit' to fix the config file."
- `ConfigMissing` -> "Run 'keypo-wallet init' to create a config file, or pass the value as a flag."

### D.3 Update `--verbose` logging

Add `tracing::debug!` calls in config resolution to show which tier each value came from:
```
DEBUG keypo_wallet::config: rpc_url resolved from config file: https://sepolia.base.org
DEBUG keypo_wallet::config: bundler_url resolved from env var KEYPO_BUNDLER_URL
```

Redact API keys in debug output.

### D.4 Tests (~5)

- `config_missing_suggestion`
- `config_parse_error_suggestion`
- `verbose_config_resolution` (test that debug logs fire)
- `init_interactive_prompts` (via `run_init_interactive()` with mock `BufRead` input)
- `init_interactive_overwrite_declined` (mock "n" input, verify no file written)

---

## Phase E: Homebrew Formula + Release Workflow

**Goal:** Create the unified Homebrew formula and CI workflow to build both binaries and publish a release.

### E.1 New Homebrew formula: `homebrew/Formula/keypo-wallet.rb`

Based on the spec's formula template. ARM-only guard. Installs both `keypo-wallet` and `keypo-signer` binaries.

### E.2 New CI workflow: `.github/workflows/release-wallet.yml`

Triggers on `wallet-v*` tag push. Steps:

1. **Build Swift binary** (`keypo-signer`):
   - `cd keypo-signer && swift build -c release`
   - Code-sign with Developer ID (reuse existing secrets)
   - Notarize with `notarytool`

2. **Build Rust binary** (`keypo-wallet`):
   - `cd keypo-wallet && cargo build --release`
   - Code-sign with Developer ID

3. **Package tarball**:
   - `tar czf keypo-wallet-aarch64-apple-darwin.tar.gz keypo-wallet keypo-signer`

4. **Create GitHub release**:
   - Upload tarball
   - Generate release notes from commits

5. **Update Homebrew formula**:
   - Compute SHA256 of tarball
   - `brew bump-formula-pr` or direct PR to `keypo-us/homebrew-tap`

**Runner:** `macos-15` (Apple Silicon, required for Swift SE build and Rust arm64 target)

### E.3 Version synchronization

The canonical version source is `keypo-wallet/Cargo.toml` (`version = "X.Y.Z"`). The release workflow reads it via:
```bash
VERSION=$(grep '^version' keypo-wallet/Cargo.toml | head -1 | sed 's/.*"\(.*\)"/\1/')
```

Swift's `Package.swift` does not have a standard version field. The `keypo-signer` binary reports its version via `--version` output, which is set as a string constant in `Sources/keypo-signer/main.swift`. The release workflow:
1. Reads the Rust version from `Cargo.toml`.
2. Reads the Swift version from `keypo-signer --version` output (built in the same CI job).
3. Validates both match the git tag (`wallet-vX.Y.Z` -> `X.Y.Z`).
4. Fails the release if versions diverge.

To keep versions in sync during development, add a CI check in `.github/workflows/rust.yml` that compares the two version strings and fails if they differ.

### E.4 Tests

- Formula `test do` block (Homebrew-level test)
- CI workflow tested via dry-run on a non-tag push (optional)

---

## File Change Summary

| File | Action | Phase |
|---|---|---|
| `keypo-wallet/Cargo.toml` | Add `toml = "0.8"` | A |
| `keypo-wallet/src/lib.rs` | Add `pub mod config;` | A |
| `keypo-wallet/src/config.rs` | **New** — config loading, validation, resolution | A |
| `keypo-wallet/src/bin/main.rs` | Expand `Commands` enum, add handlers, wire config | B, C |
| `keypo-wallet/src/query.rs` | Add `wallet-list`/`wallet-info` formatters | C |
| `keypo-wallet/src/types.rs` | Add `WalletListEntry`, add `tx_hash` to `ChainDeployment` | C |
| `keypo-wallet/src/account.rs` | Populate `tx_hash` in new `ChainDeployment` records | C |
| `keypo-wallet/src/error.rs` | Add `Config*` variants, update suggestions | D |
| `keypo-wallet/src/signer.rs` | Add `passthrough()` method to `KeypoSigner` | B |
| `homebrew/Formula/keypo-wallet.rb` | **New** — Homebrew formula | E |
| `.github/workflows/release-wallet.yml` | **New** — unified release CI | E |

---

## Dependency Graph

```
Phase A (config module)
  └─> Phase B (CLI structure + config wiring)
        ├─> Phase C (wallet-list/wallet-info handlers + query logic)
        ├─> Phase D (error updates + polish)
        └─> Phase E (Homebrew + release CI)
```

Phases C, D, and E can all run in parallel after B. Phase E touches only CI/Homebrew files with no Rust source dependencies on C or D.

---

## Test Count Estimate

| Phase | New Tests | Running Total |
|---|---|---|
| Existing | — | 136 |
| A | ~20 | ~156 |
| B | ~15 | ~171 |
| C | ~10 | ~181 |
| D | ~5 | ~186 |
| **Total** | **~50** | **~186** |

---

## Risk Notes

1. **`toml` crate version:** Using `toml = "0.8"` which is the current stable. Verify no conflicts with existing deps.

2. **Interactive stdin in `init`:** The prompt logic is extracted into `run_init_interactive(reader: &mut impl BufRead, ...)` so both the interactive and non-interactive paths are unit-testable with mock input. Manual testing is still recommended for the actual terminal UX (prompt formatting, default display).

3. **Signer passthrough output format:** When proxying `keypo-signer` output, the unified CLI must not add any prefix/suffix to stdout. Only stderr messages (errors, hints) come from the Rust binary.

4. **Config file permissions:** The `~/.keypo/` directory already has 0o700 permissions (set by `StateStore`). The config file should be created with standard permissions (not 0o600 — it contains no secrets, only URLs which may contain API keys in query params). The redaction in `config show` is the protection layer for API keys.

5. **Backward compatibility of `--rpc` required:** Currently `run_setup` does `rpc.ok_or("--rpc is required")`. After the change, users without a config file who omit `--rpc` will get a different error message ("missing required config: rpc_url" with a suggestion to run `init`). This is strictly better UX but is a behavior change.

6. **`--no-paymaster` default:** When `paymaster_url` is set in config, all `send`/`batch` commands will use it by default. Users must pass `--no-paymaster` to opt out. This is the spec behavior but could surprise users upgrading from the explicit-flag model. The `init` command's optional paymaster prompt mitigates this.

---

## Open Items Resolution

| # | Item | Resolution |
|---|---|---|
| 1 | `init` non-interactive mode | **Yes.** `init --rpc <url> --bundler <url> [--paymaster <url>]` skips prompts. Included in Phase B. |
| 2 | `config set` redaction | **Redacted echo.** `config set` echoes the written value with API key redaction. Matches `config show` behavior. |
| 3 | `rotate` cross-tool flow | **Deferred.** `rotate` is a passthrough to `keypo-signer rotate` for now. On-chain key re-registration requires a separate spec once multi-key support lands. |
