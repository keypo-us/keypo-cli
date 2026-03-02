# keypo-wallet — P-256 ERC-4337 Smart Account Client

**Version:** 0.3.0-draft
**Date:** 2026-03-01
**Author:** Dave / Keypo, Inc.

---

## 1. Overview

keypo-wallet is a Rust crate and CLI for creating and operating EIP-7702 smart accounts controlled by P-256 keys from Apple's Secure Enclave via `keypo-signer`. All post-setup transactions are submitted through ERC-4337 bundlers.

The crate is **implementation-agnostic** — it is not tied to a specific smart account contract. Different on-chain implementations can be plugged in via a trait, as long as they satisfy a minimal interface: accept P-256 public keys, validate P-256 signatures on UserOperations (raw P-256 or WebAuthn-wrapped), and support ERC-7821 execution.

This project lives in the `keypo-wallet/` directory of the `keypo-wallet` monorepo.

### 1.1 Design Principles

- **P-256 as sole operational key.** After setup, the ephemeral secp256k1 bootstrap key is securely erased. The Secure Enclave P-256 key is the only authority.
- **P-256 signatures with optional WebAuthn.** The default path sends raw P-256 signatures (`r || s`, 64 bytes). The trait also supports WebAuthn-wrapped signatures for browser/passkey flows. The on-chain contract routes based on signature length.
- **Implementation-agnostic.** The crate defines an `AccountImplementation` trait. Different smart account contracts plug in by implementing this trait. Swapping implementations does not require changes to signing, bundler, or transaction logic.
- **Chain-agnostic.** Works on any EVM chain with EIP-7702. No hardcoded chain IDs or contract addresses. Accounts can be deployed on multiple chains, tracked in a single record.
- **Bundler-agnostic (ERC-7769).** The BundlerClient targets the ERC-7769 standard JSON-RPC API. Pimlico-specific extensions are optional enhancements, not core dependencies.
- **Paymaster-agnostic (ERC-7677).** A single ERC-7677 implementation works across Pimlico, Coinbase, Alchemy, and any compliant provider. No `PaymasterProvider` trait needed.
- **Bundler-only submission.** All post-setup transactions go through ERC-4337 bundlers. This enables gas sponsorship via paymasters.
- **Subprocess signing.** The crate calls `keypo-signer` as a subprocess. No FFI, no framework dependencies.
- **Configurable key policy.** During setup, users choose the Secure Enclave key protection level: none, passcode, or biometric (Touch ID). This maps to keypo-signer-cli's `--policy` flag.
- **Testnet-first.** Initial development and testing targets Base Sepolia.

### 1.2 Relationship to keypo-account

The `keypo-account` Foundry project (in the same monorepo) deploys the default smart account contract — an OpenZeppelin-based P-256 account with dual-path signature validation (raw P-256 + WebAuthn). That project:

- Outputs a deployment record (`deployments/<chain>.json`) with the implementation address per chain
- Exports the contract ABI for calldata encoding
- Defines the interface specification that any compatible implementation must satisfy

This crate consumes those outputs but does not depend on the Solidity source. Alternative implementations can be used by providing a different `AccountImplementation` trait implementation.

### 1.3 Relationship to keypo-signer-cli

The `keypo-signer-cli` Swift CLI (in the same monorepo, migrated from [github.com/keypo-us/keypo-signer-cli](https://github.com/keypo-us/keypo-signer-cli)) provides Secure Enclave P-256 key management and signing. The canonical specification of its commands, output format, and key policies is in its [SPEC.md](https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md).

Key policies supported by keypo-signer-cli:
- **none** — No biometric or passcode required. Key is accessible without user interaction.
- **passcode** — Device passcode required before each signing operation.
- **biometric** — Touch ID (biometric) required before each signing operation.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     keypo-wallet CLI                     │
│         (clap argument parsing, output formatting)       │
└────────────────────────────┬─────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────┐
│                    keypo-wallet crate                     │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │           AccountImplementation trait              │    │
│  │  (pluggable: KeypoAccount, custom)                │    │
│  │                                                    │    │
│  │  - encode_initialize(qx, qy) -> Bytes              │    │
│  │  - encode_execute(calls) -> Bytes                  │    │
│  │  - encode_signature(r, s) -> Bytes                 │    │
│  │  - implementation_address(chain_id) -> Address     │    │
│  └──────────────────┬───────────────────────────┘    │
│                         │                                │
│  ┌──────────┐  ┌────────▼────────┐  ┌───────────────┐   │
│  │ AccountMgr│  │  TxBuilder      │  │ BundlerClient │   │
│  │           │  │                 │  │ (ERC-7769)    │   │
│  │ - setup() │  │ - build_uo()   │  │ - send_uo()   │   │
│  │ - state   │  │ - estimate()   │  │ - estimate()  │   │
│  │           │  │ - user_op_hash │  │ - receipt()   │   │
│  └──────┬───┘  └────────┬────────┘  └───────┬───────┘   │
│         │               │                   │           │
│  ┌──────▼───────────────▼───────────────────▼─────────┐  │
│  │                   alloy-rs layer                    │  │
│  │  Provider, ABI encoding, EIP-7702 auth, RPC, types │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │    KeypoSigner     │  │  StateStore  │  │ Paymaster│ │
│  │  (subprocess)      │  │  (~/.keypo/) │  │ (ERC-7677)│ │
│  └────────┬───────────┘  └──────────────┘  └──────────┘ │
└───────────┼──────────────────────────────────────────────┘
            │ subprocess call
┌───────────▼──────────────────────────────────────────────┐
│                    keypo-signer CLI                       │
│            (Secure Enclave P-256 signing)                 │
│   github.com/keypo-us/keypo-signer-cli — see SPEC.md    │
└──────────────────────────────────────────────────────────┘
```

---

## 3. The `AccountImplementation` Trait

This is the abstraction that decouples the Rust crate from any specific smart account contract.

**Interface specification** (comments describe required behavior; implementations must satisfy these contracts):

```rust
/// Trait defining how to interact with a specific smart account implementation.
///
/// Different on-chain contracts (KeypoAccount, custom) may encode initialization,
/// execution, and signatures differently. Implementing this trait allows
/// keypo-wallet to work with any of them.
///
/// All implementations must accept P-256 signatures. The default path is raw
/// P-256 (r || s, 64 bytes). Implementations may also support WebAuthn-wrapped
/// signatures via encode_webauthn_signature().
pub trait AccountImplementation: Send + Sync {
    /// Human-readable name for logging and state storage.
    fn name(&self) -> &str;

    /// The address of the deployed implementation contract on a given chain.
    /// Returns None if not deployed on this chain.
    fn implementation_address(&self, chain_id: u64) -> Option<Address>;

    /// Encode the initialization calldata.
    ///
    /// Called once during account setup. The returned bytes are sent as calldata
    /// to the EOA (which has just been delegated to the implementation) to register
    /// the P-256 public key.
    ///
    /// Test: Roundtrip — encode then ABI-decode should recover (qx, qy).
    fn encode_initialize(&self, qx: B256, qy: B256) -> Bytes;

    /// Encode one or more calls as execution calldata.
    ///
    /// Uses ERC-7821 batch mode (0x01) for all calls, including single calls
    /// (encoded as a 1-element batch). Mode 0x00 is not used.
    ///
    /// Test: Encode a single call, verify it produces a 1-element batch with mode 0x01.
    /// Test: Encode multiple calls, verify batch encoding.
    /// Test: Roundtrip — encode then ABI-decode should recover original calls.
    fn encode_execute(&self, calls: &[Call]) -> Bytes;

    /// Encode a raw P-256 signature into the format the contract expects.
    ///
    /// Default path: abi.encodePacked(r, s) — 64 bytes total.
    /// Pure P-256 — no WebAuthn wrapper.
    ///
    /// Test: Verify output is exactly 64 bytes (r || s).
    fn encode_signature(&self, r: B256, s: B256) -> Bytes;

    /// Encode a WebAuthn-wrapped signature for contracts that support it.
    ///
    /// Returns None if this implementation doesn't support WebAuthn.
    /// The default implementation returns None.
    ///
    /// Implementations that support WebAuthn should encode the authenticator data,
    /// client data JSON, and P-256 signature into the format their contract expects.
    ///
    /// Test: If supported, verify output is >64 bytes and contract accepts it.
    fn encode_webauthn_signature(
        &self,
        authenticator_data: &[u8],
        client_data_json: &str,
        r: B256,
        s: B256,
    ) -> Option<Bytes> {
        None // Default: WebAuthn not supported
    }

    /// Return a dummy signature for gas estimation.
    ///
    /// Bundlers require a validly-formatted (but not cryptographically valid)
    /// signature to estimate gas. This should be the same length and format
    /// as a real signature.
    ///
    /// Test: Verify length matches encode_signature output.
    fn dummy_signature(&self) -> Bytes;

    /// The ERC-4337 EntryPoint address this implementation targets.
    /// Default: EntryPoint v0.7 (0x0000000071727De22E5E9d8BAf0edAc6f37da032)
    fn entry_point(&self) -> Address;
}
```

### 3.1 Default Implementation: `KeypoAccountImpl`

Implements the trait for the `KeypoAccount` contract from the `keypo-account` Foundry project.

**Interface and behavior** (not exhaustive implementation — describes what each method must do):

```rust
/// Default implementation for the KeypoAccount contract.
///
/// Construction:
/// - from_deployments_dir(path): Load deployment addresses from the monorepo's
///   deployments/ directory (reads deployments/<chain>.json files).
/// - new(chain_id, address): Create with a single known deployment.
///
/// Behavior:
/// - name() returns "KeypoAccount"
/// - implementation_address() looks up the chain_id in the deployments map
/// - encode_initialize() produces: selector("initialize(bytes32,bytes32)") + qx + qy
///   Total: 4 + 32 + 32 = 68 bytes
/// - encode_execute() always uses ERC-7821 batch mode 0x01, even for single calls.
///   Single calls are encoded as a 1-element batch. Mode 0x00 is never used.
/// - encode_signature() produces: r || s (64 bytes, packed)
/// - encode_webauthn_signature() encodes the WebAuthn assertion fields per OZ's
///   expected format. Returns Some(encoded) since KeypoAccount supports both paths.
/// - dummy_signature() returns 64 bytes of 0x01 (same format as a real raw P-256 sig)
/// - entry_point() returns the v0.7 EntryPoint address
///
/// Tests:
/// - encode_initialize roundtrip: encode, ABI-decode, verify (qx, qy) match
/// - encode_execute single call: verify mode=0x01, 1-element batch encoding
/// - encode_execute batch: verify mode=0x01, N-element batch encoding
/// - encode_signature: verify 64-byte output, r || s ordering
/// - encode_webauthn_signature: verify >64 bytes, correct encoding
/// - dummy_signature: verify 64 bytes
/// - from_deployments_dir: verify loading from JSON, missing chain returns None
```

**Note:** The separate `encode_execute` (single) and `encode_execute_batch` methods from v0.1.0 have been merged into a single `encode_execute(&[Call])` that always uses ERC-7821 batch mode `0x01`. Mode `0x00` is invalid for ERC-7821.

---

## 4. Core Modules

### 4.1 Dependencies

```toml
[dependencies]
alloy = { version = "0.12", features = [
    "provider-http",
    "signer-local",      # ephemeral secp256k1 during setup
    "eip7702",           # type-4 transaction construction
    "sol-types",         # ABI encoding
    "rpc-types",
    "contract",
] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
clap = { version = "4", features = ["derive"] }
zeroize = "1"
hex = "0.4"
thiserror = "2"
dirs = "5"
tracing = "0.1"
reqwest = { version = "0.12", features = ["json"] }
chrono = { version = "0.4", features = ["serde"] }
```

### 4.2 Module Structure

```
keypo-wallet/
├── Cargo.toml
├── src/
│   ├── lib.rs                  # Public crate API
│   ├── traits.rs               # AccountImplementation trait
│   ├── impls/
│   │   ├── mod.rs
│   │   └── keypo_account.rs    # Default KeypoAccount implementation
│   ├── signer.rs               # KeypoSigner subprocess wrapper
│   ├── account.rs              # Account setup (EIP-7702 delegation)
│   ├── bundler.rs              # ERC-7769 bundler JSON-RPC client
│   ├── paymaster.rs            # ERC-7677 paymaster client
│   ├── transaction.rs          # UserOperation construction and signing
│   ├── state.rs                # Local state persistence
│   ├── balance.rs              # Multi-chain, multi-token balance queries
│   ├── types.rs                # Shared types (Call, P256PublicKey, etc.)
│   └── error.rs                # Error types
├── src/bin/
│   └── main.rs                 # CLI entry point
├── abi/                        # Contract ABIs (from keypo-account build)
│   └── KeypoAccount.json
├── query/                      # Example balance query files
│   └── all-tokens.json
└── tests/
    ├── integration_setup.rs    # End-to-end setup on Base Sepolia
    └── integration_send.rs     # End-to-end transaction on Base Sepolia
```

### 4.3 Core Types

**Interface specification** (describes the data model; implementations use serde derives and alloy primitives):

```rust
/// A P-256 public key as two 32-byte coordinates.
/// Serialized as hex strings in JSON.
struct P256PublicKey { qx: B256, qy: B256 }

/// A P-256 signature as two 32-byte scalars, low-S normalized.
struct P256Signature { r: B256, s: B256 }

/// A single call within a batch execution.
struct Call { to: Address, value: U256, data: Bytes }

/// A record of a chain where the smart account has been deployed + initialized.
/// The smart account (EOA) address is the same on all chains (it's the user's EOA),
/// but each chain has its own implementation address, bundler URL, etc.
struct ChainDeployment {
    chain_id: u64,
    implementation: Address,
    implementation_name: String,
    entry_point: Address,
    bundler_url: String,
    paymaster_url: Option<String>,
    rpc_url: String,
    deployed_at: String,           // ISO 8601 timestamp
}

/// Persisted state for a smart account across all chains it's deployed on.
///
/// A single AccountRecord represents one P-256 key (one EOA) that may be
/// deployed as a smart account on multiple chains. The address is derived
/// from the ephemeral secp256k1 key during setup and is the same across chains.
///
/// Test: Verify that adding a chain deployment doesn't affect other chains.
/// Test: Verify lookup by (key_label, chain_id) returns correct ChainDeployment.
/// Test: Verify lookup by key_label returns all ChainDeployments.
struct AccountRecord {
    address: Address,              // The EOA address (same on all chains)
    key_label: String,             // keypo-signer key label
    key_policy: String,            // "none", "passcode", or "biometric"
    public_key: P256PublicKey,
    chains: Vec<ChainDeployment>,  // All chains where this account is deployed
    created_at: String,            // When the first deployment was created
}

/// Connection configuration for interacting with a specific chain.
/// Multiple ChainConfigs can be used to deploy the same account on multiple chains.
///
/// Test: Verify ChainConfig can be constructed for any chain ID.
/// Test: Verify multiple ChainConfigs can coexist for different chains.
struct ChainConfig {
    chain_id: u64,
    rpc_url: String,
    bundler_url: String,
    paymaster_url: Option<String>,
}
```

### 4.4 KeypoSigner — Subprocess Wrapper

**Interface specification:**

```rust
/// Wraps the keypo-signer CLI binary as a subprocess.
/// Parses JSON output per the keypo-signer-cli SPEC.md.
/// See: https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md
///
/// Construction:
/// - new(): Uses "keypo-signer" from PATH
/// - with_binary(path): Uses a custom binary path
///
/// Methods:
///
/// get_public_key(label) -> Result<P256PublicKey>
///   Calls: keypo-signer info <label> --format json
///   Parses: "publicKey" field — 0x04 || qx (32 bytes) || qy (32 bytes)
///   Validates: 65-byte uncompressed P-256 key starting with 0x04
///   Test: Mock subprocess returning valid JSON, verify parsed (qx, qy)
///   Test: Mock subprocess returning invalid key format, verify error
///   Test: Mock subprocess failing (key not found), verify error
///
/// create_key(label, policy) -> Result<P256PublicKey>
///   Calls: keypo-signer create <label> --policy <policy> --format json
///   Policy: "none", "passcode", or "biometric"
///   Returns the new key's public key
///   Test: Mock subprocess returning valid creation response
///   Test: Mock subprocess with duplicate label, verify error
///
/// sign(digest, label) -> Result<P256Signature>
///   Calls: keypo-signer sign <hex-digest> --key <label> --format json
///   Parses: "r" and "s" fields — hex-encoded 32-byte big-endian
///   Signatures are low-S normalized by keypo-signer
///   Test: Mock subprocess returning valid signature JSON
///   Test: Verify (r, s) are correctly parsed as B256
///   Test: Mock subprocess failure (Touch ID cancelled), verify error
///
/// list_keys() -> Result<Vec<KeyInfo>>
///   Calls: keypo-signer list --format json
///   Returns all keys with labels and policies
///   Test: Mock subprocess with multiple keys
///
/// Error types:
/// - SignerNotFound: binary not on PATH
/// - SignerCommand: subprocess returned non-zero
/// - SignerOutput: JSON parsing failure or unexpected format
```

### 4.5 Account Setup

**Interface specification:**

```rust
/// Set up a new smart account on a target chain.
///
/// This is the most security-critical function. It generates an ephemeral
/// secp256k1 key, uses it once, and destroys it.
///
/// Parameters:
/// - provider: alloy HTTP provider for the target chain
/// - chain: ChainConfig with RPC, bundler, paymaster URLs
/// - implementation: AccountImplementation trait object
/// - signer_cli: KeypoSigner subprocess wrapper
/// - key_label: keypo-signer key label
/// - key_policy: "none", "passcode", or "biometric"
/// - state: mutable StateStore for persistence
///
/// Steps:
/// 1. Get P-256 public key via keypo-signer info (or create if new)
/// 2. Resolve and verify implementation contract exists on-chain
/// 3. Generate ephemeral secp256k1 keypair (memory only)
/// 4. Display ephemeral EOA address, wait for funding (polling loop)
/// 5. Build EIP-7702 authorization (chain_id, implementation address, nonce)
/// 6. Sign authorization with ephemeral key
/// 7. Encode initialization calldata via AccountImplementation::encode_initialize.
///    **The P-256 public key (passkey) coordinates (qx, qy) are passed directly
///    in the calldata** — `initialize(bytes32 qx, bytes32 qy)` is called on the
///    delegated EOA, and the key material is ABI-encoded into the transaction's
///    calldata field (4-byte selector + 32 bytes qx + 32 bytes qy = 68 bytes).
///    This is the mechanism by which the passkey is registered on-chain: the
///    initialization calldata carries the public key, and the contract stores it
///    in the EOA's storage via `_setSigner(qx, qy)`.
/// 8. Send type-4 tx with authorization list + init calldata
/// 9. Verify delegation (EOA code starts with 0xef0100)
/// 10. Zeroize and drop ephemeral key — it must never be persisted
/// 11. Persist AccountRecord to state store (add ChainDeployment to record)
///
/// Security — Ephemeral Key Generation:
/// Uses alloy's PrivateKeySigner::random(), which internally uses k256's
/// SigningKey::random() backed by OsRng (the getrandom crate). On macOS this
/// calls SecRandomCopyBytes; on Linux, getrandom(2). This is the Rust ecosystem's
/// standard for cryptographic key generation and is considered best practice.
/// The key exists only in memory and is zeroized on drop via the zeroize crate.
///
/// Tests:
/// - Unit: verify correct TransactionRequest structure (authorization list, calldata)
/// - Unit: verify delegation check logic (0xef0100 prefix)
/// - Unit: verify error paths (implementation not deployed, funding timeout, tx failure)
/// - Integration: MockSigner-based full setup against fork or testnet
/// - Integration: second setup for same (key, chain) adds to existing record or fails
///
/// Returns: AccountRecord with the new ChainDeployment added
```

### 4.6 Transaction Flow (UserOperation)

**Interface specification:**

```rust
/// Execute one or more calls via the ERC-4337 bundler.
///
/// Parameters:
/// - account: AccountRecord (must have a ChainDeployment for the target chain)
/// - chain_id: which chain to execute on
/// - calls: Vec<Call> — the operations to execute
/// - implementation: AccountImplementation trait object
/// - signer_cli: KeypoSigner (or MockSigner for tests)
/// - bundler: BundlerClient
/// - provider: alloy provider for on-chain queries
///
/// Steps:
/// 1. Encode calldata via AccountImplementation::encode_execute — always batch mode 0x01
/// 2. Build UserOp skeleton with dummy signature for estimation
/// 3. If paymaster configured: call pm_getPaymasterStubData (ERC-7677)
/// 4. Gas estimation via eth_estimateUserOperationGas (ERC-7769)
/// 5. Apply gas estimates to UserOp
/// 6. If paymaster configured: call pm_getPaymasterData (ERC-7677)
/// 7. Compute userOpHash = keccak256(abi.encode(keccak256(pack(userOp)), entryPoint, chainId))
/// 8. Sign userOpHash with Secure Enclave via keypo-signer
/// 9. Encode signature via AccountImplementation::encode_signature — pure P-256
/// 10. Submit via eth_sendUserOperation (ERC-7769)
/// 11. Poll for receipt via eth_getUserOperationReceipt
///
/// Tests:
/// - Unit: compute_user_op_hash against known vectors
/// - Unit: PackedUserOperation packed→unpacked serialization roundtrip
/// - Unit: gas field packing (account_gas_limits, gas_fees as packed bytes32)
/// - Unit: paymaster stub→real data flow
/// - Integration: MockSigner-signed full submission against testnet bundler
///
/// Returns: transaction hash of the confirmed on-chain transaction
```

### 4.7 Bundler Client (ERC-7769)

The BundlerClient targets the **ERC-7769 standard JSON-RPC API**, making it bundler-agnostic. Raw JSON-RPC, no SDK.

**Interface specification:**

```rust
/// ERC-7769 bundler JSON-RPC client.
///
/// Construction: new(url) — takes the bundler endpoint URL
///
/// Methods (all raw JSON-RPC, no SDK):
///
/// send_user_operation(user_op, entry_point) -> Result<B256>
///   JSON-RPC: eth_sendUserOperation
///   Sends a signed PackedUserOperation to the bundler.
///   Returns the UserOperation hash.
///   Test: verify JSON-RPC request serialization matches ERC-7769 spec
///
/// estimate_user_op_gas(user_op) -> Result<GasEstimate>
///   JSON-RPC: eth_estimateUserOperationGas
///   Returns gas estimates: preVerificationGas, verificationGasLimit, callGasLimit
///   Test: verify request/response serialization
///
/// get_user_op_receipt(uo_hash) -> Result<Option<UserOpReceipt>>
///   JSON-RPC: eth_getUserOperationReceipt
///   Returns receipt if available, None if pending
///   Test: verify both found and not-found responses parse correctly
///
/// get_user_op_by_hash(uo_hash) -> Result<Option<UserOperationInfo>>
///   JSON-RPC: eth_getUserOperationByHash
///   Test: verify serialization
///
/// wait_for_receipt(uo_hash) -> Result<UserOpReceipt>
///   Polls get_user_op_receipt with exponential backoff until receipt or timeout
///   Test: mock sequential poll responses (None, None, Some(receipt))
///
/// supported_entry_points() -> Result<Vec<Address>>
///   JSON-RPC: eth_supportedEntryPoints
///   Test: verify response parsing
///
/// GasEstimate fields: pre_verification_gas, verification_gas_limit, call_gas_limit,
///   max_fee_per_gas (optional), max_priority_fee_per_gas (optional)
///
/// UserOpReceipt fields: success (bool), transaction_hash (B256), reason (Option<String>)
///
/// Note: Pimlico-specific extensions like pimlico_getUserOperationGasPrice can be
/// added as optional methods but are not part of the core ERC-7769 interface.
```

### 4.8 Paymaster Client (ERC-7677)

The paymaster interface uses the **ERC-7677 standard** (`pm_getPaymasterStubData` + `pm_getPaymasterData`). A single implementation works across all ERC-7677 compliant providers.

**Interface specification:**

```rust
/// ERC-7677 paymaster client.
///
/// get_stub_data(user_op, account, paymaster_url) -> Result<Bytes>
///   JSON-RPC: pm_getPaymasterStubData
///   Params: [userOp (unpacked), entryPoint, chainId, context]
///   Context: opaque JSON value, forwarded as-is (empty object by default)
///   Returns: paymasterAndData bytes for gas estimation
///   Test: verify request serialization matches ERC-7677
///   Test: verify response parsing extracts paymasterAndData
///
/// get_paymaster_data(user_op, account, paymaster_url) -> Result<Bytes>
///   JSON-RPC: pm_getPaymasterData
///   Same params as get_stub_data
///   Returns: real paymasterAndData bytes for submission
///   Test: verify request/response serialization
///
/// Key design decision: No PaymasterProvider trait. The ERC-7677 standard is
/// sufficient — the opaque context value handles provider-specific differences
/// without abstraction overhead.
```

### 4.9 State Store

Persistent local state at `~/.keypo/accounts.json`. Multi-chain aware — each account tracks all chains it's deployed on.

**Interface specification:**

```rust
/// Local state persistence for account records.
///
/// Storage: ~/.keypo/accounts.json
///
/// Data model: A list of AccountRecords, each containing:
/// - address, key_label, key_policy, public_key
/// - chains: Vec<ChainDeployment> — all chains where the account is deployed
///
/// Methods:
///
/// open() -> Result<StateStore>
///   Opens or creates the state file.
///   Test: verify file creation on first open
///   Test: verify existing file is loaded correctly
///
/// find_account(key_label, chain_id) -> Option<(&AccountRecord, &ChainDeployment)>
///   Finds an account by key label and returns the specific chain deployment.
///   Test: verify lookup with existing and non-existing (key, chain) pairs
///
/// find_accounts_for_key(key_label) -> Option<&AccountRecord>
///   Returns the full account record with all chain deployments.
///   Test: verify returns all chains for a given key
///
/// add_chain_deployment(key_label, deployment: ChainDeployment) -> Result<()>
///   Adds a new chain deployment to an existing account, or creates a new
///   AccountRecord if this is the first deployment for this key.
///   Test: verify adding first chain creates new record
///   Test: verify adding second chain appends to existing record
///   Test: verify duplicate (key, chain) is rejected
///
/// list_accounts() -> &[AccountRecord]
///   Returns all accounts.
///
/// Example state file structure:
/// {
///   "accounts": [{
///     "address": "0x9876...5432",
///     "key_label": "testnet-key",
///     "key_policy": "biometric",
///     "public_key": { "qx": "0xabcd...", "qy": "0x5678..." },
///     "chains": [
///       {
///         "chain_id": 84532,
///         "implementation": "0xaaaa...bbbb",
///         "implementation_name": "KeypoAccount",
///         "entry_point": "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
///         "bundler_url": "https://api.pimlico.io/v2/84532/rpc?apikey=...",
///         "paymaster_url": null,
///         "rpc_url": "https://sepolia.base.org",
///         "deployed_at": "2026-03-01T12:00:00Z"
///       },
///       {
///         "chain_id": 11155111,
///         "implementation": "0xaaaa...bbbb",
///         "implementation_name": "KeypoAccount",
///         "entry_point": "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
///         "bundler_url": "https://api.pimlico.io/v2/11155111/rpc?apikey=...",
///         "paymaster_url": null,
///         "rpc_url": "https://ethereum-sepolia-rpc.publicnode.com",
///         "deployed_at": "2026-03-05T15:30:00Z"
///       }
///     ],
///     "created_at": "2026-03-01T12:00:00Z"
///   }]
/// }
```

---

## 5. CLI Interface

### 5.1 Commands

```
keypo-wallet setup
    --key <LABEL>                 # keypo-signer key label (required)
    --key-policy <POLICY>         # Key protection: none | passcode | biometric (default: biometric)
    --rpc <URL>                   # RPC endpoint (required)
    --bundler <URL>               # Bundler endpoint (required)
    --chain-id <ID>               # Chain ID (auto-detected from RPC if omitted)
    --paymaster <URL>             # ERC-7677 paymaster URL (optional)
    --implementation <ADDR>       # Contract address (required for now; later: auto-resolve)
    --impl-name <n>            # Trait implementation name (default: "KeypoAccount")

keypo-wallet send
    --key <LABEL>                 # keypo-signer key label (required)
    --to <ADDR>                   # Recipient (required)
    --value <AMOUNT>              # ETH amount (default: 0)
    --data <HEX>                  # Calldata (optional)
    --chain-id <ID>               # Chain (inferred from state if unambiguous)

keypo-wallet batch
    --key <LABEL>                 # (required)
    --calls <FILE>                # JSON: [{to, value, data}, ...] (required)
    --chain-id <ID>

keypo-wallet info
    --key <LABEL>                 # Show accounts for this key (all chains if no --chain-id)
    --chain-id <ID>

keypo-wallet balance
    --key <LABEL>                 # (required)
    --chain-id <ID>               # Filter to specific chain (optional; default: all chains)
    --token <SYMBOL_OR_ADDR>      # Filter to specific token (optional; default: all tokens)
    --query <FILE>                # Structured query file for advanced filtering (optional)
```

### 5.2 Example Session (Base Sepolia)

```bash
# 1. Set up smart account on Base Sepolia with Touch ID protection
$ keypo-wallet setup \
    --key testnet-key \
    --key-policy biometric \
    --rpc https://sepolia.base.org \
    --bundler https://api.pimlico.io/v2/84532/rpc?apikey=... \
    --implementation 0x<keypo-account-address>

Creating key 'testnet-key' with biometric policy...
P-256 public key: qx=0xabcd..., qy=0x5678...
Implementation: KeypoAccount at 0x...
Ephemeral EOA: 0x9876...5432

Fund this address with Base Sepolia ETH:
  https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet

Waiting... funded (0.01 ETH)
Sending EIP-7702 delegation + initialization...
Confirmed: 0x3333...4444
Delegation verified. P-256 key registered.

Smart account ready:
  Address:  0x9876...5432
  Chain:    Base Sepolia (84532)
  Key:      testnet-key (biometric)
  Impl:     KeypoAccount @ 0x...

Ephemeral key erased.

# 2. Send a transaction
$ keypo-wallet send --key testnet-key --to 0xRecipient... --value 0.001
Building UserOperation...
[Touch ID prompt]
Submitted. UO hash: 0x5555...6666
Confirmed: 0x7777...8888

# 3. Check balance — all tokens, all chains
$ keypo-wallet balance --key testnet-key
testnet-key (0x9876...5432):
  Base Sepolia (84532):
    ETH:  0.008900
    USDC: 100.000000

# 4. Check info — shows all chain deployments
$ keypo-wallet info --key testnet-key
testnet-key (biometric):
  Address: 0x9876...5432
  Chains:
    Base Sepolia (84532):
      Impl:     KeypoAccount @ 0x...
      Deployed: 2026-03-01T12:00:00Z
```

### 5.3 Balance Query File Format

The `--query` flag accepts a JSON file that defines a structured query for filtering balance results. This provides a GraphQL-style interface for drilling into specific tokens, chains, and thresholds.

```json
{
  "chains": [84532, 11155111],
  "tokens": {
    "include": ["ETH", "USDC", "0x1234..."],
    "exclude": [],
    "min_balance": "0.001"
  },
  "format": "table",
  "sort_by": "value_usd"
}
```

**Field descriptions:**
- `chains` — Array of chain IDs to query. Empty or omitted = all chains the account is deployed on.
- `tokens.include` — Token symbols or contract addresses to include. Empty = all tokens.
- `tokens.exclude` — Token symbols or addresses to exclude.
- `tokens.min_balance` — Minimum balance threshold (in token units). Tokens below this are hidden.
- `format` — Output format: `"table"` (default), `"json"`, `"csv"`.
- `sort_by` — Sort order: `"value_usd"`, `"balance"`, `"token"`, `"chain"`.

---

## 6. Security

### 6.1 Key Lifecycle

| Key | Created | Used | Destroyed | Storage |
|-----|---------|------|-----------|---------|
| P-256 | `keypo-signer create` | Every tx | Never | Secure Enclave hardware |
| secp256k1 | `keypo-wallet setup` | Once | Immediately after setup confirms | Memory only, zeroized on drop |

### 6.2 Key Policy

Users choose the Secure Enclave key protection level during `keypo-wallet setup` via `--key-policy`:

| Policy | Flag | Behavior |
|--------|------|----------|
| None | `--key-policy none` | No authentication required for signing. Fastest, least secure. |
| Passcode | `--key-policy passcode` | Device passcode required before each sign operation. |
| Biometric | `--key-policy biometric` | Touch ID required before each sign operation. Default and recommended. |

The key policy is stored in the `AccountRecord` and cannot be changed after key creation.

### 6.3 Process Boundary

Only digests (32 bytes) and signatures (64 bytes) cross the subprocess boundary. No private key material enters the Rust process except the ephemeral secp256k1 key during setup.

### 6.4 Ephemeral Key Security

The ephemeral secp256k1 key used during setup is generated using `PrivateKeySigner::random()` from alloy's `signer-local` crate. This uses:
- `k256::SigningKey::random()` with `OsRng` as the entropy source
- `OsRng` is backed by the `getrandom` crate, which calls the OS CSPRNG: `SecRandomCopyBytes` on macOS, `getrandom(2)` on Linux
- The key implements `Zeroize` and is securely erased on drop
- The key exists only in process memory — never written to disk

This is the Rust ecosystem's standard approach for cryptographic key generation.

### 6.5 Local State

`~/.keypo/accounts.json` contains addresses, URLs, key labels, and key policies — no secrets. Read access reveals which addresses are controlled but cannot enable signing without Secure Enclave access.

---

## 7. Testing

**Assume all code is wrong. Tests prove it right.** All automated tests run first. Manual/human testing happens only after automated tests pass.

### 7.1 Unit Tests

- KeypoSigner parsing with mocked subprocess output (test against JSON format from [SPEC.md](https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md))
- AccountImplementation encode/decode roundtrips — **especially ERC-7821 mode `0x01` encoding for single and batch calls**
- StateStore CRUD — including multi-chain deployment tracking
- BundlerClient JSON-RPC serialization (ERC-7769 request/response formats)
- Paymaster client ERC-7677 serialization (stub data and real data requests)
- `compute_user_op_hash` against known vectors
- PackedUserOperation packed→unpacked serialization roundtrip
- Balance query parsing and filtering

### 7.2 Integration Tests (Base Sepolia) — Automated

| Test | Description |
|------|-------------|
| `test_setup_full` | Ephemeral EOA → fund → delegate → initialize → verify (MockSigner) |
| `test_send_eth` | ETH transfer via bundler (MockSigner, using mock-signer test account) |
| `test_send_erc20` | ERC-20 transfer (MockSigner, using mock-signer test account) |
| `test_batch` | Multiple calls in one UserOp (MockSigner) |
| `test_paymaster` | Gas-sponsored tx via ERC-7677 (MockSigner) |
| `test_duplicate_setup` | Second setup for same (key, chain) fails |
| `test_multi_chain` | Same key deployed on two chains, state tracks both |

### 7.3 Manual Tests (Human Testing — Last)

Run only after all automated tests pass:

| Test | Description |
|------|-------------|
| `manual_setup` | Full setup with real Secure Enclave key + Touch ID |
| `manual_send` | Real P-256-signed ETH transfer on testnet |
| `manual_batch` | Real P-256-signed batch on testnet |
| `manual_paymaster` | Gas-sponsored tx with real signing |
| `manual_balance` | Balance query across chains and tokens |

### 7.4 Mock Signer for CI

For environments without Secure Enclave, a `MockSigner` uses a software P-256 key (via the `p256` crate) with the same interface as `KeypoSigner`. A test account initialized with the MockSigner's public key enables true end-to-end on-chain validation in CI.

### 7.5 WebAuthn End-to-End Testing (Frontend + Playwright)

For tests that exercise the WebAuthn signature path (the `encode_webauthn_signature` trait method and the contract's `>64 byte` validation path), a basic test frontend at `localhost:3000` provides the WebAuthn challenge/response ceremony. Playwright MCP server automates the browser end-to-end — no human interaction required.

**How it works:**
- Playwright creates a virtual WebAuthn authenticator (via Chrome DevTools Protocol's `WebAuthn.addVirtualAuthenticator`) with a known P-256 keypair matching the MockSigner's key.
- The frontend triggers `navigator.credentials.get()` with the `userOpHash` as the challenge.
- The assertion response provides `authenticatorData`, `clientDataJSON`, `r`, `s` — all fields needed for the WebAuthn-wrapped signature encoding.
- The Rust test harness extracts these fields, encodes the signature via `AccountImplementation::encode_webauthn_signature()`, and submits the UserOp to the bundler.

**This enables fully automated WebAuthn path testing in CI** without hardware authenticators, browser prompts, or human interaction. See keypo-account spec §4.5 for the test frontend setup and Playwright configuration.

---

## 8. Open Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | `keypo-signer` JSON output fields | **VERIFY IN PHASE 0** | Verify against [SPEC.md](https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md). Confirm: exact field names (`publicKey`, `r`, `s`) in `--format json` output. Test all three key policies. |
| 2 | alloy EIP-7702 API | **CONFIRMED** | `Authorization` struct + `sign_authorization` + `with_authorization_list` all present. Verify `sign_authorization` on `Signer` trait vs two-step fallback. |
| 3 | Paymaster API | **RESOLVED** | Use ERC-7677 standard (`pm_getPaymasterStubData` + `pm_getPaymasterData`). Single implementation, no trait needed. See §4.8. |
| 4 | PackedUserOperation format | **CONFIRMED** | Matches v0.7. BundlerClient needs packed→unpacked serialization for RPC. |
| 5 | Gas fee sourcing | **DESIGN** | How to set maxFeePerGas on UserOp — bundler suggestion vs provider query. Pimlico offers `pimlico_getUserOperationGasPrice` as optional extension. |
| 6 | ERC-4337 nonce scheme | **DESIGN** | 2D nonce (192-bit key + 64-bit seq). How OZ Account manages this. |
| 7 | CI test infrastructure | **PLAN** | Base Sepolia faucet automation or pre-funded accounts. Secrets configured in Phase 0. Mock-signer test account for on-chain validation. |
| 8 | ERC-7821 mode encoding | **BUG — FIXED** | Mode `0x00` is invalid. Single calls must use batch mode `0x01` with a 1-element array. `encode_execute` updated. See §3 and §3.1. |
| 9 | WebAuthn signature encoding | **DESIGN** | The trait supports WebAuthn via `encode_webauthn_signature()`. The exact encoding format depends on OZ's WebAuthn library. Document after OZ integration in Phase 1. |
| 10 | Balance token discovery | **DESIGN** | How to discover ERC-20 tokens on each chain. Options: token list registry, indexer API (Alchemy, Covalent), or manual configuration. |
