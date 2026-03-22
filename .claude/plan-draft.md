# keypo-pay Implementation Plan

## Open Questions Resolution

### Q3: MPP Implementation Strategy
**Decision: Implement charge flow natively in Rust. Defer session support.**

Rationale: The charge flow is straightforward HTTP (parse 402 WWW-Authenticate header, construct credential with tx hash, retry with Authorization header). This requires no external SDK dependency. Session support involves escrow contracts, off-chain voucher signing, and channel lifecycle management — this is substantial complexity better deferred until a reference implementation exists on Tempo. The MPP module should be designed with a trait boundary so session support can be added later without refactoring the charge flow.

### Q4: Fee Sponsorship
**Decision: Defer fee sponsorship. Use faucet tokens for testnet gas.**

Rationale: Tempo testnet provides a faucet (`tempo_fundAddress` RPC) that gives 1M of each stablecoin. For testnet, gas fees are negligible. The transaction struct already has `fee_token`, `fee_payer_signature`, and `valid_before/valid_after` fields as optional — implementing fee sponsorship later means populating these fields without changing the core transaction construction path. Leave the fields as `None` for now, add a `--fee-sponsor` CLI flag in a future phase.

### Q5: Testnet vs Mainnet
**Decision: Build for testnet first. Defer `network` profile field.**

The `wallet.toml` stores `chain_id` and `rpc_url`. Users can switch networks by modifying these values or using CLI flag overrides. Phase 1 hardcodes testnet defaults (chain ID, RPC URL, token addresses) without a `network` field. A `network` field (values: `testnet` or `mainnet`) is an optional future extension — it is not part of the spec's config schema and is not required for Phase 1. Mainnet token addresses and profiles can be added when mainnet support is needed.

### Q6: Session Key Rotation
**Decision: Defer automated rotation. Provide manual revoke + re-authorize workflow.**

Users can manually rotate access keys via `access-key revoke --name old-key` followed by `access-key create --name new-key` + `access-key authorize ...`. Automated rotation adds complexity (scheduling, coordination with agents) that is premature. The access key model already supports multiple independent keys, so users can create a new key before revoking the old one (overlap period).

---

## CLI Command Surface

The spec defines two distinct send commands with different default signing behaviors:

| Command | Default signer | Override | Phase |
|---------|---------------|----------|-------|
| `keypo-pay tx send --to <addr> --token <token> --amount <amt>` | Root key | `--key <name>` for access key | Phase 3 |
| `keypo-pay tx send --to <addr> --token <token> --amount <amt> --key <name>` | Access key (Keychain sig) | — | Phase 4 |
| `keypo-pay send --to <addr> --amount <amt> --key <name>` | Access key | `--use-root-key` to bypass | Phase 5 |
| `keypo-pay send --to <addr> --amount <amt> --use-root-key` | Root key | — | Phase 5 |
| `keypo-pay balance [--token <name_or_addr>]` | — | — | Phase 5 |
| `keypo-pay token add/remove/list` | — | — | Phase 5 |
| `keypo-pay wallet create [--test]` | — | — | Phase 1 |
| `keypo-pay wallet info` | — | — | Phase 1 |
| `keypo-pay access-key create/authorize/revoke/list/info/update-limit/delete` | — | — | Phase 4 |
| `keypo-pay pay <url> --key <name> [--session] [--max-deposit <amt>]` | Access key | — | Phase 6 |

**`tx send` vs `send`:** `tx send` (Feature 2) is the lower-level transaction command that defaults to root key signing. `send` (Feature 4) is the higher-level token transfer command that requires `--key` for access key or `--use-root-key` for root key. Both exist and serve different use cases.

**Global CLI options** (all phases): `--rpc <url>` for RPC endpoint override, following the 4-tier resolution pattern (CLI > env > config > error).

---

## Project Structure

```
keypo-pay/
  Cargo.toml
  src/
    lib.rs                  # Module declarations, re-exports
    bin/
      main.rs               # CLI entry point (clap)
    error.rs                # Error enum with thiserror
    config.rs               # wallet.toml, access-keys.toml, tokens.toml management
    signer.rs               # Re-export + Tempo-specific extensions to P256Signer
    types.rs                # TempoTx, P256Signature, KeyAuthorization, etc.
    address.rs              # P-256 pubkey -> Tempo address derivation
    rlp.rs                  # RLP encoding/decoding for Tempo tx type 0x76
    signature.rs            # P-256 (0x01) and Keychain (0x03) signature formatting
    transaction.rs          # Tx construction, signing hash, submission, receipt polling
    access_key.rs           # KeyAuthorization RLP, precompile calls, on-chain queries
    token.rs                # TIP-20 balanceOf, transfer, token address book
    rpc.rs                  # JSON-RPC helpers (reuse pattern from keypo-wallet)
    mpp.rs                  # MPP charge flow (parse 402, build credential, retry)
  tests/
    common/
      mod.rs                # Shared test helpers (wallet creation, faucet, cleanup)
    wallet_test.rs          # T1: Wallet creation tests
    transaction_test.rs     # T2: Transaction construction and signing
    access_key_test.rs      # T3: Access key management
    token_test.rs           # T4: TIP-20 operations
    mpp_test.rs             # T5: MPP client integration
    config_test.rs          # T6: Configuration
    error_test.rs           # T7: Error handling
```

---

## Code Sharing from keypo-wallet

### Can be copied/adapted (with modifications):
- **`signer.rs`**: The `P256Signer` trait, `KeypoSigner` struct, `MockSigner`, `parse_public_key` — all reusable as-is. Copy and keep the same interface. The only addition: a helper method to derive Tempo address from public key coordinates.
- **`error.rs`**: The pattern (thiserror enum with `suggestion()` method) is the same. Error variants will differ (no bundler/paymaster/AA errors; add Tempo-specific ones).
- **`config.rs`**: The 4-tier resolution pattern (`resolve_value`, `resolve_rpc`), atomic write pattern, and `validate_url` are reusable. The config schema is different (wallet.toml instead of config.toml, plus access-keys.toml and tokens.toml).
- **`rpc.rs`**: The `json_rpc_post` helper is directly reusable for Tempo RPC calls.
- **`types.rs`**: `P256PublicKey`, `P256Signature`, `KeyInfo` are directly reusable. Other types are keypo-wallet-specific.

### Must be new (Tempo-specific):
- **`rlp.rs`**: Tempo transaction RLP encoding. alloy provides `alloy_rlp` for RLP primitives, but the 0x76 transaction envelope is Tempo-specific.
- **`signature.rs`**: P-256 signature formatting (type 0x01, 130 bytes) and Keychain signature (type 0x03, 151 bytes) are Tempo-specific.
- **`transaction.rs`**: Entirely new. No UserOps, no bundler, no EntryPoint. Direct `eth_sendRawTransaction` with type 0x76 envelope.
- **`access_key.rs`**: Entirely new. KeyAuthorization RLP encoding, AccountKeychain precompile ABI encoding and calls.
- **`token.rs`**: TIP-20 is similar to ERC-20 but the token address book concept is new.
- **`mpp.rs`**: Entirely new. HTTP 402 challenge-response protocol.
- **`address.rs`**: New. `keccak256(pubKeyX || pubKeyY)` last 20 bytes.

### Tech debt acknowledgment:
Copying `signer.rs`, `types.rs`, `rpc.rs`, and config patterns from keypo-wallet creates duplication. Extracting a shared `keypo-common` crate is deferred to avoid blocking progress. This is intentional tech debt — both copies are small (~200 lines each for signer/types) and divergence is expected (Tempo-specific extensions). Revisit after keypo-pay reaches feature parity.

---

## Implementation Phases

### Phase 1: Project Skeleton, Config, Address Derivation, and Signer Integration

**Goal:** `cargo build` succeeds, `keypo-pay wallet create --test` creates a wallet with a root key, derives the Tempo address, and stores config. `cargo test` passes with unit tests.

**Files to create:**
- `keypo-pay/Cargo.toml`
- `keypo-pay/src/lib.rs`
- `keypo-pay/src/bin/main.rs` (minimal clap skeleton with `wallet create`, `wallet info`, global `--rpc` flag)
- `keypo-pay/src/error.rs`
- `keypo-pay/src/config.rs`
- `keypo-pay/src/signer.rs` (copy from keypo-wallet, add Tempo address derivation)
- `keypo-pay/src/types.rs` (P256PublicKey, P256Signature, KeyInfo — copied; WalletConfig, AccessKeyEntry, TokenEntry — new)
- `keypo-pay/src/address.rs`

**Key types and functions:**

```rust
// address.rs
pub fn derive_tempo_address(pub_key: &P256PublicKey) -> Address {
    let mut buf = [0u8; 64];
    buf[..32].copy_from_slice(pub_key.qx.as_slice());
    buf[32..].copy_from_slice(pub_key.qy.as_slice());
    let hash = keccak256(&buf);
    Address::from_slice(&hash[12..])
}

// config.rs
pub struct WalletConfig {
    pub chain_id: u64,
    pub rpc_url: String,
    pub root_key_id: String,
    pub address: Address,
    pub default_token: Option<String>,
    pub block_explorer_url: Option<String>,
}

pub struct AccessKeyEntry {
    pub name: String,
    pub key_id: String,
    pub address: Address,
}

pub struct TokenEntry {
    pub name: String,
    pub address: Address,
}

// Functions: load_wallet_config, save_wallet_config, load_access_keys, save_access_keys,
// load_tokens, save_tokens, resolve_rpc, resolve_value (copy pattern from keypo-wallet)
// Config directory: ~/.keypo/tempo/

// bin/main.rs - global CLI options
#[derive(Parser)]
struct Cli {
    #[arg(long, global = true)]
    rpc: Option<String>,

    #[command(subcommand)]
    command: Commands,
}
```

**Dependencies (Cargo.toml):**
```toml
alloy = { version = "1.7", features = ["provider-http", "sol-types", "rpc-types", "contract", "rlp"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
clap = { version = "4", features = ["derive"] }
hex = "0.4"
thiserror = "2"
dirs = "6"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["fmt", "env-filter"] }
url = "2"
reqwest = { version = "0.12", features = ["json"] }
toml = "0.8"
p256 = { version = "0.13", features = ["ecdsa"], optional = true }

[features]
test-utils = ["dep:p256"]

[dev-dependencies]
tempfile = "3"
keypo-pay = { path = ".", features = ["test-utils"] }
```

**Note on RLP:** Use `alloy::rlp` re-exported from alloy 1.7 (via the `"rlp"` feature) instead of adding `alloy-rlp` as a separate dependency. This avoids potential version conflicts and duplicate types.

**Tests:**
- `address.rs`: Unit test address derivation with known vectors
- `config.rs`: TOML round-trip, missing file, idempotency guard, atomic write, 4-tier resolution
- `signer.rs`: MockSigner create/sign (from keypo-wallet tests)
- `bin/main.rs`: Clap argument parsing tests (including `--rpc` global flag)
- Validates T1.1 (address derivation), T1.2 (idempotency), T1.3 (wallet info), T6.1-T6.3

**Acceptance criteria:**
1. `cargo build` succeeds
2. `cargo test` passes (pure unit tests, no network)
3. `keypo-pay wallet create --test` with MockSigner creates `~/.keypo/tempo/wallet.toml` and `tokens.toml`
4. `keypo-pay wallet info` displays address, root key ID, chain ID
5. Second `wallet create` fails with clear error
6. Default testnet tokens pre-populated in `tokens.toml`

---

### Phase 2: RLP Encoding, Transaction Construction, Signature Formatting

**Goal:** Construct, sign, and serialize a Tempo type 0x76 transaction. RLP round-trip tests pass. Signature format tests pass. No network interaction yet.

**Files to create:**
- `keypo-pay/src/rlp.rs`
- `keypo-pay/src/signature.rs`
- `keypo-pay/src/transaction.rs` (construction and signing hash only, not submission)

**Key types and functions:**

```rust
// types.rs (additions)
pub struct TempoTx {
    pub chain_id: u64,
    pub nonce: u64,
    pub nonce_key: u64,
    pub calls: Vec<TempoCall>,
    pub gas_limit: u64,
    pub max_fee_per_gas: u128,
    pub max_priority_fee_per_gas: u128,
    pub fee_token: Option<Address>,
    pub valid_before: Option<u64>,
    pub valid_after: Option<u64>,
    pub key_authorization: Option<Vec<u8>>,  // RLP-encoded signed authorization
    pub fee_payer_signature: Option<Vec<u8>>,
}

pub struct TempoCall {
    pub to: Address,
    pub value: U256,
    pub data: Bytes,
}

// rlp.rs
pub fn rlp_encode_tx(tx: &TempoTx) -> Vec<u8>;
pub fn rlp_decode_tx(data: &[u8]) -> Result<TempoTx>;
pub fn signing_hash(tx: &TempoTx) -> B256;  // keccak256(0x76 || rlp(fields))

// signature.rs
pub fn format_p256_signature(sig: &P256Signature, pub_key: &P256PublicKey, pre_hash: bool) -> Vec<u8>;
    // Returns 130 bytes: 0x01 || r(32) || s(32) || pubX(32) || pubY(32) || pre_hash(1)
pub fn format_keychain_signature(root_address: Address, inner_sig: Vec<u8>) -> Vec<u8>;
    // Returns 151 bytes: 0x03 || root_address(20) || inner_sig(130)
pub fn serialize_signed_tx(tx: &TempoTx, signature: Vec<u8>) -> Vec<u8>;
    // Returns: 0x76 || rlp(fields || signature)
```

**RLP encoding of `calls` field:** Each `TempoCall` is encoded as a list `[to, value, data]`. The `calls` field is encoded as a list of these lists: `[[to1, value1, data1], [to2, value2, data2], ...]`. This follows standard RLP list-of-lists encoding.

**`pre_hash` flag note:** The spec's Feature 2 description (line 81) states "this flag should be `true`", but the Tempo Protocol Reference section (lines 280-286) provides a thorough analysis concluding `pre_hash = false` (0x00). The reference section takes precedence. keypo-signer signs the raw keccak256 digest without additional SHA-256 hashing, so `pre_hash = false` is correct.

**T2.2 scope note:** The Keychain signature format test (T2.2) validates the *format* of the signature offline using MockSigner — it does not submit a transaction on-chain. On-chain validation of Keychain signatures requires the access key to be authorized first, which is covered in Phase 4's integration tests.

**Tests:**
- `rlp.rs`: RLP encode/decode round-trip (T2.3), known vector tests, calls list encoding
- `signature.rs`: P-256 signature format is 130 bytes with correct type byte (T2.1), Keychain format is 151 bytes (T2.2), pre_hash flag is 0x00 (T2.1)
- `transaction.rs`: Signing hash computation with known values

**Acceptance criteria:**
1. RLP encode/decode round-trip preserves all fields including calls list
2. P-256 signature is exactly 130 bytes, starts with 0x01, ends with 0x00 (pre_hash=false)
3. Keychain signature is 151 bytes, starts with 0x03, contains root address
4. Signing hash = `keccak256(0x76 || rlp(fields))`
5. All tests pass with `cargo test`

---

### Phase 3: RPC Integration, Transaction Submission, Receipt Polling

**Goal:** Send a real transaction on Tempo testnet signed by the root key. End-to-end flow from construction to confirmed receipt.

**Files to create/modify:**
- `keypo-pay/src/rpc.rs` (copy `json_rpc_post` from keypo-wallet, add Tempo-specific helpers)
- `keypo-pay/src/transaction.rs` (add async submission and receipt polling)

**Key functions:**

```rust
// rpc.rs
pub async fn json_rpc_post(client: &reqwest::Client, url: &str, method: &str, params: Value) -> Result<Value>;
pub async fn get_nonce(provider: &impl Provider, address: Address) -> Result<u64>;
pub async fn estimate_gas(provider: &impl Provider, tx: &TempoTx, from: Address) -> Result<u64>;
pub async fn get_gas_prices(provider: &impl Provider) -> Result<(u128, u128)>;
pub async fn send_raw_transaction(client: &reqwest::Client, rpc_url: &str, raw: &[u8]) -> Result<B256>;
pub async fn wait_for_receipt(provider: &impl Provider, tx_hash: B256, timeout: Duration) -> Result<TransactionReceipt>;
pub async fn fund_testnet_address(client: &reqwest::Client, rpc_url: &str, address: Address) -> Result<()>;

// transaction.rs (additions)
pub async fn send_tempo_tx(
    wallet: &WalletConfig,
    calls: &[TempoCall],
    signer: &dyn P256Signer,
    signing_key_label: &str,
    root_address: Option<Address>,  // None for root key, Some(addr) for access key
) -> Result<TxResult>;

pub struct TxResult {
    pub tx_hash: B256,
    pub success: bool,
    pub block_number: u64,
}
```

**Tests (integration, `--ignored`):**
- T2.4: Fund wallet, send TIP-20 transfer with root key, verify receipt
- T2.5: Send two sequential transactions, verify nonce increment
- T7.4: Unreachable RPC endpoint returns connectivity error
- T7.5: Zero balance returns insufficient gas error

**Acceptance criteria:**
1. `keypo-pay tx send --to <addr> --token pathusd --amount 0.01` succeeds on testnet
2. Receipt shows status 1 (success)
3. Nonces increment correctly across sequential sends
4. Clear errors for connectivity failures and insufficient gas

---

### Phase 4: Access Key Management (Local + On-Chain)

**Goal:** Create, authorize, revoke, and query access keys. Full on-chain lifecycle.

**Files to create/modify:**
- `keypo-pay/src/access_key.rs`
- `keypo-pay/src/bin/main.rs` (add `access-key` subcommand group)

**Authorization mechanism:** Access key authorization uses the transaction-level `key_authorization` field, as described in the spec's Feature 3 (lines 111-113). The flow is:
1. Build a `KeyAuthorization` struct, RLP-encode it, sign the digest with root key
2. Embed the RLP-encoded signed authorization in the transaction's `key_authorization` field
3. The transaction itself is signed by the access key (the "authorize and use" pattern)

The AccountKeychain precompile's `authorizeKey` function is **not** called directly as a contract call. Instead, the protocol processes the `key_authorization` field embedded in the transaction. The precompile's read functions (`getKey`, `getRemainingLimit`) are used for querying status.

For `revokeKey` and `updateSpendingLimit`, these are called as contract calls to the AccountKeychain precompile, signed by the root key. They are mutations that don't use the `key_authorization` transaction field.

**Key types and functions:**

```rust
// access_key.rs
pub struct KeyAuthorization {
    pub chain_id: u64,
    pub key_type: u8,         // 1 for P-256
    pub key_id: Address,       // Derived from access key's public key
    pub expiry: Option<u64>,
    pub limits: Vec<SpendingLimit>,
}

pub struct SpendingLimit {
    pub token: Address,
    pub amount: U256,
}

pub fn rlp_encode_key_authorization(auth: &KeyAuthorization) -> Vec<u8>;
pub fn authorization_digest(auth: &KeyAuthorization) -> B256;
pub fn rlp_encode_signed_authorization(auth: &KeyAuthorization, sig: Vec<u8>) -> Vec<u8>;

// AccountKeychain precompile ABI (for queries and root-key mutations)
const ACCOUNT_KEYCHAIN: Address = address!("AAAAAAAA00000000000000000000000000000000");

// Use alloy sol! macro for ABI encoding:
sol! {
    interface IAccountKeychain {
        function revokeKey(address keyId) external;
        function updateSpendingLimit(address keyId, address token, uint256 newLimit) external;
        function getKey(address account, address keyId) external view returns (uint8 signatureType, address keyId, uint256 expiry);
        function getRemainingLimit(address account, address keyId, address token) external view returns (uint256);
    }
}

pub async fn query_key_status(...) -> Result<Option<KeyStatus>>;
pub async fn query_remaining_limit(...) -> Result<U256>;
```

**ABI correctness mitigation:** Before implementing mutations, call `getKey` for a known account on testnet and verify the response format. This validates that the precompile uses standard Solidity ABI encoding.

**T3.10 implementation detail:** The self-escalation prevention test constructs a `TempoCall` targeting the AccountKeychain precompile address (`0xAAAAAAAA...`) with `revokeKey` calldata, signs it with the access key (Keychain signature), submits, and verifies the transaction reverts with `UnauthorizedCaller`.

**Tests (integration, `--ignored`):**
- T3.1-T3.12: Full access key lifecycle
- T3.10: Access key self-escalation prevention (critical security test)

**Acceptance criteria:**
1. `access-key create --name agent-1` creates SE key and stores in access-keys.toml
2. `access-key authorize --name agent-1 --token pathusd --limit 0.10` registers on-chain
3. `getKey` and `getRemainingLimit` precompile queries return correct data
4. `access-key revoke --name agent-1` prevents further use
5. `access-key list` shows correct statuses
6. Duplicate name creation fails with clear error

---

### Phase 5: TIP-20 Token Operations

**Goal:** Token transfers with access keys, balance queries, spending limit enforcement, token address book.

**Files to create/modify:**
- `keypo-pay/src/token.rs`
- `keypo-pay/src/bin/main.rs` (add `send`, `balance`, `token` subcommands)

**Token decimals:** Do NOT hardcode 18 decimals. As a first step in Phase 5, query the `decimals()` function on the pathUSD testnet contract (`0x20c0000000000000000000000000000000000000`) to determine the actual decimal count. Store the result and use it for all amount parsing/formatting. TIP-20 stablecoins may use 6 decimals (like USDC) or 18 — this must be verified empirically.

**Key functions:**

```rust
// token.rs
pub fn resolve_token(name_or_address: &str, token_book: &[TokenEntry]) -> Result<Address>;
pub fn encode_transfer(to: Address, amount: U256) -> Bytes;
pub fn encode_balance_of(account: Address) -> Bytes;
pub fn encode_decimals() -> Bytes;
pub async fn query_balance(provider: &impl Provider, token: Address, account: Address) -> Result<U256>;
pub async fn query_decimals(provider: &impl Provider, token: Address) -> Result<u8>;
pub fn parse_token_amount(amount: &str, decimals: u8) -> Result<U256>;
pub fn format_token_amount(amount: U256, decimals: u8) -> String;
```

**Tests (integration, `--ignored`):**
- T4.1-T4.9: Balance queries, transfers within/exceeding limits, depletion, token address book

**Acceptance criteria:**
1. `keypo-pay balance --token pathusd` shows non-zero balance after faucet
2. `keypo-pay send --to <addr> --amount 0.01 --token pathusd --key agent-1` succeeds within limits
3. Transfers exceeding spending limit revert with SpendingLimitExceeded
4. `keypo-pay token add/remove/list` manages the address book
5. Token names resolve to addresses everywhere `--token` is accepted

---

### Phase 6: MPP Charge Flow

**Goal:** Make a paid HTTP request to an MPP-enabled endpoint using the charge intent.

**Files to create/modify:**
- `keypo-pay/src/mpp.rs`
- `keypo-pay/src/bin/main.rs` (add `pay` subcommand)

**Key types and functions:**

```rust
// mpp.rs
pub struct MppChallenge {
    pub method: String,       // "tempo"
    pub intent: String,       // "charge" or "session"
    pub recipient: Address,
    pub amount: U256,
    pub token: Address,
    pub network: String,
}

pub fn parse_www_authenticate(header: &str) -> Result<MppChallenge>;

pub struct MppCredential {
    pub tx_hash: B256,
    pub payer: Address,
}

pub fn format_authorization_header(credential: &MppCredential) -> String;

pub async fn pay_charge(
    url: &str,
    wallet: &WalletConfig,
    access_key: &AccessKeyEntry,
    signer: &dyn P256Signer,
    tokens: &[TokenEntry],
) -> Result<MppResponse>;

pub struct MppResponse {
    pub status: u16,
    pub body: String,
    pub receipt: Option<String>,
}
```

**Tests (integration, `--ignored`):**
- T5.1: End-to-end charge flow against local mppx test server
- T5.2: Insufficient funds error
- T5.3: Insufficient access key limit error
- Unit tests: `parse_www_authenticate` parsing, credential formatting

**Acceptance criteria:**
1. `keypo-pay pay <url> --key agent-1` completes charge flow
2. 402 challenge parsed correctly
3. Transaction submitted on-chain
4. Response body returned to user
5. Payment-Receipt header captured

---

### Phase 7: Polish, Error Handling, Documentation

**Goal:** Comprehensive error messages, CLI help text, CLAUDE.md, test harness improvements.

**Files to create/modify:**
- `keypo-pay/CLAUDE.md` (project-specific conventions)
- All error paths reviewed against T7.1-T7.6
- CLI help text with examples
- `docs/quality.md` (update test counts)

**Acceptance criteria:**
1. Every error scenario in T7 produces a clear, actionable error message
2. `keypo-pay --help` and subcommand `--help` show examples
3. `CLAUDE.md` documents Tempo-specific conventions

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Tempo testnet unavailability** | Blocks integration tests | All unit tests (Phases 1-2) work offline. Integration tests use `--ignored`. Document testnet RPC endpoint and verify connectivity early. |
| **RLP encoding correctness** | Transactions rejected on-chain | Write round-trip tests first. Compare against Tempo SDK reference implementation if available. Start with known-good transaction hex from Tempo docs if provided. |
| **`pre_hash` flag ambiguity** | On-chain signature verification failure | Spec resolves this: `pre_hash = false` (0x00). Validate with an on-chain transaction in Phase 3 before building more features. |
| **AccountKeychain precompile ABI** | Authorization/revocation calls fail | Use alloy `sol!` macro for ABI encoding. Before implementing mutations, call `getKey` for a known account on testnet to verify the precompile uses standard Solidity ABI encoding. If it uses custom encoding, adjust accordingly. |
| **TIP-20 token decimals** | Amounts off by orders of magnitude | Do NOT assume 18 decimals. Query `decimals()` on the pathUSD contract as the first task in Phase 5. Stablecoins often use 6 decimals. |
| **Spending limit units** | Limits set to wrong magnitude | Depends on correct decimals discovery (above). Amount parsing must convert human-readable amounts using the queried decimal count. |
| **Faucet rate limits** | Integration tests fail from rate limiting | Use one wallet per test suite run (not per test), fund once, use separate access keys to isolate tests. Fall back to fresh wallets only when test isolation requires it. |
| **alloy RLP re-export** | Compilation errors or duplicate types | Use `alloy::rlp` via the `"rlp"` feature in the alloy dependency, not a separate `alloy-rlp` crate. |
| **MPP spec instability** | Charge flow may not match server | Implement as thin HTTP layer. Core payment (TIP-20 transfer) is independent. Only `parse_www_authenticate` needs updating if header format changes. |

---

## Test Harness Design

All integration tests share a common setup in `tests/common/mod.rs`:

```rust
pub struct TestWallet {
    pub wallet: WalletConfig,
    pub signer: KeypoSigner,  // real signer with open-policy keys
    pub root_key_label: String,
    pub config_dir: TempDir,
}

impl TestWallet {
    pub async fn new() -> Self {
        // 1. Create temp config dir
        // 2. Create root key with open policy via keypo-signer
        // 3. Derive Tempo address
        // 4. Write wallet.toml and tokens.toml
        // 5. Fund via tempo_fundAddress RPC
    }

    pub async fn create_and_authorize_access_key(
        &mut self, name: &str, token: Address, limit: U256
    ) -> AccessKeyEntry { ... }
}
```

**Test isolation strategy:** Prefer creating one wallet per test module (not per individual test) and funding it once. Individual tests use separate access keys or nonce keys for isolation. Fall back to fresh wallets only when state pollution between tests is unavoidable (e.g., T3.8 revocation test modifies shared state). This avoids potential faucet rate limits.

Integration tests use `#[ignore]` and run with `cargo test -- --ignored --test-threads=1`.

---

## Test Report

All phases contribute to a single cumulative test report at `keypo-pay/TEST-REPORT.md`. Each phase appends its section when its tests pass. The report is the definitive validation artifact.

### Report Structure

```markdown
# keypo-pay Test Report
Generated: YYYY-MM-DD
Tempo Testnet RPC: https://rpc.moderato.tempo.xyz
Block Explorer: [if available]

## Environment
- **Root Key ID:** `<keypo-signer key ID>`
- **Tempo Address:** `0x...`
- **Faucet TX:** [tx hash from tempo_fundAddress call]
- **Chain ID:** ...

## Access Keys
| Name | Key ID | Derived Address | Authorization TX | Status |
|------|--------|----------------|-----------------|--------|
| agent-1 | `...` | `0x...` | `0x<tx_hash>` | authorized |
| agent-2 | `...` | `0x...` | `0x<tx_hash>` | revoked |

---

## Phase 1: Project Skeleton, Config, Address Derivation
| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| T1.1 | Root key generation and address derivation | PASS | Address: `0x...`, verified keccak256 match |
| T1.2 | Idempotency guard | PASS | Second create returned error |
| T1.3 | Wallet info display | PASS | Output verified |
| T6.1 | Config file creation | PASS | wallet.toml, tokens.toml, access-keys.toml exist |
| T6.2 | CLI flag override | PASS | --rpc flag took precedence |
| T6.3 | Environment variable override | PASS | Env > config, CLI > env |

---

## Phase 2: RLP Encoding, Transaction Construction, Signatures
| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| T2.1 | Root key P-256 signature format | PASS | 130 bytes, starts 0x01, ends 0x00 |
| T2.2 | Access key Keychain signature format | PASS | 151 bytes, starts 0x03, root addr verified |
| T2.3 | RLP encoding round-trip | PASS | All fields preserved |

---

## Phase 3: RPC Integration, Transaction Submission
| Test ID | Description | Result | TX Hash / Evidence |
|---------|-------------|--------|-------------------|
| T2.4 | Root key TIP-20 transfer | PASS | `0x<tx_hash>` block #N status=1 |
| T2.5 | Nonce management | PASS | `0x<hash1>` nonce=0, `0x<hash2>` nonce=1 |
| T7.4 | RPC connectivity failure | PASS | Error: "Failed to connect to ..." |
| T7.5 | Insufficient gas | PASS | Error: "Insufficient funds for gas" |

---

## Phase 4: Access Key Management
| Test ID | Description | Result | TX Hash / Evidence |
|---------|-------------|--------|-------------------|
| T3.1 | Create access key locally | PASS | access-keys.toml updated |
| T3.4 | Authorize with spending limit | PASS | `0x<tx_hash>` |
| T3.8 | Revoke access key | PASS | `0x<tx_hash>`, subsequent tx reverted |
| T3.10 | Access key cannot self-escalate | PASS | Reverted: `UnauthorizedCaller` |
| ... | ... | ... | ... |

### Precompile Queries
| Query | Account | Key ID | Token | Result |
|-------|---------|--------|-------|--------|
| getKey | `0x...` | `0x...` | — | signatureType=1, expiry=0 |
| getRemainingLimit | `0x...` | `0x...` | pathUSD | 0.09 |

---

## Phase 5: TIP-20 Token Operations
| Test ID | Description | Result | TX Hash / Evidence |
|---------|-------------|--------|-------------------|
| T4.1 | Balance query | PASS | Balance: 1000000.0 pathUSD |
| T4.3 | Transfer within limits | PASS | `0x<tx_hash>` |
| T4.4 | Transfer exceeds limits | PASS | Reverted: `SpendingLimitExceeded` |
| T4.6 | Spending limit depletion | PASS | 5 txs: ✓✓✗✓✗ (see hashes) |
| ... | ... | ... | ... |

---

## Phase 6: MPP Charge Flow
| Test ID | Description | Result | TX Hash / Evidence |
|---------|-------------|--------|-------------------|
| T5.1 | Charge intent end-to-end | PASS | `0x<tx_hash>`, Receipt header present |
| T5.2 | Insufficient funds | PASS | Error: "Insufficient balance" |
| T5.3 | Insufficient access key limit | PASS | Reverted: `SpendingLimitExceeded` |

---

## Phase 7: Error Handling
| Test ID | Description | Result | Evidence |
|---------|-------------|--------|----------|
| T7.1 | No wallet exists | PASS | Error: "No wallet found. Run `wallet create`" |
| T7.2 | Access key not authorized | PASS | Error: "agent-1 is not authorized on-chain" |
| T7.3 | Expired access key | PASS | TX reverted after expiry |
| T7.6 | Unknown access key name | PASS | Error: "Key 'nonexistent' not found" |

---

## Summary
| Phase | Tests | Passed | Failed | Skipped |
|-------|-------|--------|--------|---------|
| 1 | 6 | 6 | 0 | 0 |
| 2 | 3 | 3 | 0 | 0 |
| 3 | 4 | 4 | 0 | 0 |
| 4 | 12 | 12 | 0 | 0 |
| 5 | 9 | 9 | 0 | 0 |
| 6 | 3 | 3 | 0 | 0 |
| 7 | 6 | 6 | 0 | 0 |
| **Total** | **43** | **43** | **0** | **0** |
```

### Report Requirements

1. **Every on-chain interaction must include its transaction hash** — wallet funding, key authorization, token transfers, revocations, limit updates
2. **Precompile query results must be logged** — `getKey`, `getRemainingLimit` responses for every access key test
3. **Failed/reverted transactions must include the revert reason** — parsed from the receipt or RPC error
4. **The report is generated programmatically** by the test harness, not manually — the `TestWallet` helper captures tx hashes and query results during test execution and appends to the report
5. **Block explorer links** are included if a `block_explorer_url` is configured; otherwise raw tx hashes are sufficient
6. **Wallet addresses and key IDs** are logged at the top so any test result can be independently verified on-chain
7. **The report is cumulative** — each phase appends its section, so the final report contains all phases in one file

### Implementation

Add a `TestReport` struct to `tests/common/mod.rs`:

```rust
pub struct TestReport {
    pub wallet_address: Address,
    pub root_key_id: String,
    pub phases: Vec<PhaseReport>,
}

pub struct PhaseReport {
    pub phase: u8,
    pub title: String,
    pub entries: Vec<TestReportEntry>,
    pub precompile_queries: Vec<PrecompileQuery>,
}

pub struct TestReportEntry {
    pub test_id: String,         // e.g., "T2.4"
    pub description: String,
    pub result: TestResult,       // Pass, Fail, Skip
    pub tx_hashes: Vec<B256>,
    pub evidence: String,         // revert reason, query result, etc.
}

pub struct PrecompileQuery {
    pub function: String,        // e.g., "getKey"
    pub account: Address,
    pub key_id: Address,
    pub token: Option<Address>,
    pub result: String,
}

impl TestReport {
    pub fn append_phase(&mut self, phase: PhaseReport) { ... }
    pub fn write_to_file(&self, path: &Path) -> std::io::Result<()> { ... }
}
```

The test harness populates `TestReport` as tests execute and writes/updates `keypo-pay/TEST-REPORT.md` after each phase completes. The final report is a single file containing all phases.
