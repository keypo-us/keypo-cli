# keypo-account — EIP-7702 P-256 Smart Account Contracts

**Version:** 0.3.0-draft
**Date:** 2026-03-01
**Author:** Dave / Keypo, Inc.

---

## 1. Overview

keypo-account is a Foundry project that implements, tests, and deploys EIP-7702 smart account contracts verified by P-256 (secp256r1) signatures. These contracts allow an Ethereum EOA to delegate its code to a smart account that accepts Secure Enclave signatures as its sole authentication mechanism.

The contract supports **dual-path signature validation**: raw P-256 signatures (64 bytes) for direct Secure Enclave signing, and WebAuthn-wrapped signatures for browser-based and passkey flows. Both paths validate against the same stored P-256 public key.

This project is **deployment infrastructure only** — it does not include client-side tooling, signing, or transaction submission. A separate Rust crate (`keypo-wallet`) handles client interaction and is designed to be implementation-agnostic, meaning this contract can be swapped for alternative P-256 smart account implementations without changes to the client.

This project lives in the `keypo-account/` directory of the `keypo-wallet` monorepo. Deployment records are written to the shared `deployments/` directory at the repo root.

### 1.1 Design Goals

- **Minimal contract surface.** The smart account is a thin composition of audited OpenZeppelin building blocks. Custom logic is limited to the override glue code.
- **One deployment per chain.** EIP-7702 accounts delegate to a shared implementation contract. There is no factory, no proxy, no per-user deployment. Each EOA that delegates gets its own storage.
- **Deterministic addresses.** The implementation contract is deployed via CREATE2 so it lives at the same address on every chain.
- **Dual-path P-256 signatures.** The contract accepts both raw P-256 signatures (`r || s`, 64 bytes) and WebAuthn-wrapped signatures (longer). Signature length determines the routing path. Both validate against the same stored `(qx, qy)` key.
- **Testnet-first.** Initial deployment and testing targets Base Sepolia. Mainnet deployments follow after end-to-end testing with the Rust client.

---

## 2. Contract Design

### 2.1 Dependencies

OpenZeppelin Contracts v5.2+ provides all building blocks:

| Module | Purpose |
|--------|---------|
| `Account` | ERC-4337 account interface — `validateUserOp`, `executeUserOp`, EntryPoint integration |
| `SignerP256` | P-256 signature verification with automatic RIP-7212 precompile detection and Solidity fallback |
| `ERC7821` | Minimal batch executor — `execute(bytes32 mode, bytes executionData)` |
| `SignerERC7702` | EIP-7702 delegation support — handles nonce separation between protocol-level and account-level nonces |
| `Initializable` | One-time initialization guard per EOA storage context |
| `WebAuthn` | WebAuthn signature verification — OZ utility library for verifying WebAuthn authentication assertions |

### 2.2 Contract: `KeypoAccount.sol`

The contract is a thin composition of OZ building blocks with two pieces of custom logic: the `initialize` function and the dual-path `_rawSignatureValidation` override.

**Interface and behavior specification** (not final implementation — follow OZ documentation for exact import paths and API):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Import Account, SignerP256, ERC7821, SignerERC7702, Initializable, WebAuthn from OpenZeppelin v5.2+.
// Exact import paths depend on the OZ version installed — consult OZ documentation.

contract KeypoAccount is Account, SignerP256, ERC7821, SignerERC7702, Initializable {

    /// @notice Initialize the account with a P-256 public key.
    /// @dev Can only be called once per EOA storage context.
    ///      The caller must be the EOA itself (during the setup transaction).
    ///      Calls SignerP256._setSigner(qx, qy) to store the key.
    /// @param qx The x-coordinate of the P-256 public key (32 bytes).
    /// @param qy The y-coordinate of the P-256 public key (32 bytes).
    function initialize(bytes32 qx, bytes32 qy) external initializer {
        // Store the P-256 public key via the inherited _setSigner function.
        // This key is used by both the raw P-256 and WebAuthn validation paths.
    }

    /// @dev Defines which callers can trigger ERC-7821 execution.
    ///      - address(this): allows the account to call itself (ERC-4337 flow where
    ///        EntryPoint calls executeUserOp, which internally calls execute)
    ///      - address(0): allows direct execution with signature validation
    ///
    ///      Test: Verify that address(this) and address(0) return true, all other
    ///      addresses return false.
    function _erc7821AuthorizedExecutor(
        address caller,
        bytes32, /* mode */
        bytes calldata /* executionData */
    ) internal view override returns (bool) {
        // Return true for address(this) and address(0), false otherwise.
    }

    /// @dev Dual-path signature validation.
    ///      Routes based on signature length:
    ///      - 64 bytes → raw P-256: decode as (r, s) and validate via SignerP256
    ///      - >64 bytes → WebAuthn: decode the WebAuthn authentication assertion
    ///        and verify via OZ's WebAuthn.verify(), using the same stored (qx, qy)
    ///
    ///      Both paths validate against the same P-256 public key set during initialize().
    ///
    ///      Override resolution: both SignerP256 and SignerERC7702 implement
    ///      _rawSignatureValidation. This override resolves the conflict and adds
    ///      the WebAuthn path.
    ///
    ///      Test: Verify with 64-byte raw signature (valid, invalid, high-S).
    ///      Test: Verify with WebAuthn-wrapped signature (valid, invalid).
    ///      Test: Verify that both paths reject when wrong key is stored.
    function _rawSignatureValidation(
        bytes32 hash,
        bytes calldata signature
    ) internal view override(SignerP256, SignerERC7702) returns (bool) {
        // If signature.length == 64:
        //   Route to SignerP256._rawSignatureValidation(hash, signature)
        //   This handles raw r || s P-256 signatures from Secure Enclave.
        //
        // If signature.length > 64:
        //   Decode the WebAuthn authentication assertion fields from the signature.
        //   Read the stored (qx, qy) from SignerP256 storage.
        //   Call WebAuthn.verify() with the authenticator data, client data JSON,
        //   challenge (derived from hash), r, s, qx, qy.
        //   Return the verification result.
        //
        // Otherwise (signature.length < 64):
        //   Return false.
    }
}
```

**Implementation notes:**
- The exact WebAuthn signature encoding (how authenticatorData, clientDataJSON, r, s are packed into the `signature` bytes) should follow OZ's `WebAuthn` library conventions. Consult the OZ v5.2+ WebAuthn documentation for the expected encoding format.
- The WebAuthn path uses the same `(qx, qy)` key stored by `_setSigner` during initialization. No additional key storage is needed.
- The `hash` parameter in the WebAuthn path is the `userOpHash` or message hash, which becomes the WebAuthn challenge.

### 2.3 Signature Format

The contract accepts two signature formats, routed by length:

#### Raw P-256 (64 bytes)

Used for direct Secure Enclave signing via keypo-signer-cli. This is the primary path for the Rust CLI client.

| Field | Size | Encoding | Notes |
|-------|------|----------|-------|
| `r` | 32 bytes | Big-endian uint256 | Left-padded with zeros if < 32 bytes |
| `s` | 32 bytes | Big-endian uint256 | Must be low-S normalized (s ≤ N/2) |

**Total: 64 bytes.** `abi.encodePacked(bytes32 r, bytes32 s)`. No prefix bytes, no length encoding, no recovery ID. **No WebAuthn wrapper** — this is a pure P-256 signature, matching the OpenZeppelin `SignerP256` interface directly.

#### WebAuthn-Wrapped (>64 bytes)

Used for browser-based and passkey authentication flows. The signature contains the WebAuthn authentication assertion fields as defined by OZ's `WebAuthn` library.

The exact encoding format (how `authenticatorData`, `clientDataJSON`, `r`, `s`, and challenge index are packed) should follow OZ's `WebAuthn.verify()` parameter expectations. Consult OZ v5.2+ documentation for the canonical encoding.

**Both paths validate against the same stored `(qx, qy)` key.**

#### Low-S Normalization

OZ's `SignerP256` enforces `s ≤ secp256r1.N / 2`. keypo-signer-cli already outputs low-S normalized signatures, so no client-side transformation is needed for the raw P-256 path. The WebAuthn path should also enforce low-S (verify OZ's `WebAuthn.verify()` behavior).

P-256 curve order N: `0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551`

### 2.4 Storage Layout

Since EIP-7702 executes the implementation contract's code in the context of the delegating EOA, all storage writes go to the **EOA's storage**, not the implementation contract's storage. This means:

- Each delegating EOA has independent initialization state
- Each delegating EOA stores its own P-256 public key
- The implementation contract's own storage is never written to during normal operation
- `Initializable` works correctly because its storage slot (`_initialized`) lives in the EOA's storage

**Fresh-EOA-only stipulation:** This contract assumes delegation targets fresh EOAs — addresses that have never had their storage written to before. Re-delegation scenarios (an EOA that previously delegated to a different implementation, or an EOA whose `Initializable` storage slot was written to by a prior delegation) are **out of scope** for this version. The behavior of `Initializable` in re-delegation scenarios is not tested or guaranteed.

### 2.5 ERC-4337 Validation Flow

When a UserOperation targets this account:

1. **EntryPoint** calls `validateUserOp(PackedUserOperation, bytes32 userOpHash, uint256 missingAccountFunds)`
2. **Account** (OZ) extracts `signature` from the UserOperation
3. **Account** calls `_rawSignatureValidation(userOpHash, signature)`
4. **Dual-path routing** checks `signature.length`:
   - **64 bytes → Raw P-256 path:** `SignerP256` decodes `(r, s)` from signature, reads `(qx, qy)` from storage, attempts RIP-7212 precompile at `0x0100`. If precompile returns `1` → valid (~3,450 gas). If precompile unavailable → Solidity P-256 verification (~200,000 gas).
   - **>64 bytes → WebAuthn path:** Decode the WebAuthn assertion from the signature. Read `(qx, qy)` from storage. Verify via OZ's `WebAuthn.verify()`.
5. Validation result returned to EntryPoint
6. If valid, **EntryPoint** calls `executeUserOp` → decodes and executes via **ERC7821**

The **digest that the client must sign is `userOpHash`**: `keccak256(abi.encode(keccak256(packedUserOp), entryPoint, chainId))`

**CRITICAL — Pre-hashed signing:** The client's P-256 signer must sign this 32-byte `userOpHash` digest **directly, without applying additional SHA-256 hashing**. The on-chain P-256 verification (via RIP-7212 precompile or Solidity fallback) checks the signature against the raw `userOpHash`. If the signer applies SHA-256 before signing (as some P-256 libraries do by default, e.g., CryptoKit's `signature(for: Data)` or the `p256` crate's `Signer::sign()`), the resulting signature will be over `SHA256(userOpHash)` instead of `userOpHash`, and on-chain verification will fail with `AA24 signature error`. See `keypo-signer-cli/Sources/KeypoCore/SecureEnclaveManager.swift` and `keypo-wallet-spec.md §4.4` for implementation details.

For the WebAuthn path, `userOpHash` becomes the WebAuthn challenge.

---

## 3. Project Structure

```
keypo-account/
├── foundry.toml
├── remappings.txt
├── src/
│   └── KeypoAccount.sol
├── test/
│   ├── KeypoAccount.t.sol
│   ├── KeypoAccountSetup.t.sol
│   ├── KeypoAccount4337.t.sol
│   └── helpers/
│       └── P256Helper.sol
├── script/
│   ├── Deploy.s.sol
│   └── Verify.s.sol
└── out/
```

See root `README.md` for the full monorepo layout.

### 3.1 Foundry Configuration

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.28"
evm_version = "prague"           # Required for EIP-7702 support in tests
optimizer = true
optimizer_runs = 200

[rpc_endpoints]
base_sepolia = "${BASE_SEPOLIA_RPC_URL}"
base = "${BASE_RPC_URL}"

[etherscan]
base_sepolia = { key = "${BASESCAN_API_KEY}", url = "https://api-sepolia.basescan.org/api" }
base = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
```

---

## 4. Testing Strategy

**Assume all code is wrong. Tests prove it right.**

All automated tests must pass before any manual testing. Manual smoke tests are consolidated at the end of the phase.

### 4.1 Unit Tests (`KeypoAccount.t.sol`)

| Test | Description |
|------|-------------|
| `test_initialize_setsPublicKey` | After `initialize(qx, qy)`, the stored key matches |
| `test_initialize_revertsOnSecondCall` | Calling `initialize` twice reverts with `InvalidInitialization()` |
| `test_rawSignatureValidation_rawP256_validSig` | A valid 64-byte P-256 signature over a known hash returns true |
| `test_rawSignatureValidation_rawP256_invalidSig` | A corrupted 64-byte signature returns false |
| `test_rawSignatureValidation_rawP256_highS` | A 64-byte signature with s > N/2 is rejected |
| `test_rawSignatureValidation_rawP256_wrongKey` | 64-byte signature valid for different key returns false |
| `test_rawSignatureValidation_webauthn_validSig` | A valid WebAuthn-wrapped signature returns true |
| `test_rawSignatureValidation_webauthn_invalidSig` | A corrupted WebAuthn signature returns false |
| `test_rawSignatureValidation_webauthn_wrongKey` | WebAuthn signature valid for different key returns false |
| `test_rawSignatureValidation_tooShort` | Signature shorter than 64 bytes returns false |
| `test_erc7821AuthorizedExecutor_self` | `caller == address(this)` returns true |
| `test_erc7821AuthorizedExecutor_zero` | `caller == address(0)` returns true |
| `test_erc7821AuthorizedExecutor_other` | Any other caller returns false |

### 4.2 EIP-7702 Integration Tests (`KeypoAccountSetup.t.sol`)

These require Foundry's Prague EVM support (`vm.etch` with 7702 delegation designator or `vm.signDelegation` cheatcode):

| Test | Description |
|------|-------------|
| `test_delegation_codePrefix` | After delegation, EOA code starts with `0xef0100` |
| `test_delegation_initialize` | EOA can call `initialize` on itself after delegation |
| `test_delegation_storageIsolation` | Two delegating EOAs have independent storage |

### 4.3 ERC-4337 Integration Tests (`KeypoAccount4337.t.sol`)

| Test | Description |
|------|-------------|
| `test_validateUserOp_rawP256_validSignature` | A correctly signed UserOp with 64-byte sig passes validation |
| `test_validateUserOp_rawP256_invalidSignature` | A bad 64-byte signature fails validation |
| `test_validateUserOp_webauthn_validSignature` | A correctly signed UserOp with WebAuthn sig passes validation |
| `test_validateUserOp_webauthn_invalidSignature` | A bad WebAuthn signature fails validation |
| `test_validateUserOp_wrongSender` | UserOp with mismatched sender fails |
| `test_executeUserOp_singleCall` | Single call execution via EntryPoint succeeds |
| `test_executeUserOp_batchCalls` | Batch execution via ERC-7821 succeeds |
| `test_executeUserOp_ethTransfer` | ETH transfer via UserOperation succeeds |
| `test_executeUserOp_erc20Transfer` | ERC-20 transfer via UserOperation succeeds |
| `test_gasEstimate_rawP256_withPrecompile` | Gas cost for raw P-256 path with RIP-7212 precompile available |
| `test_gasEstimate_rawP256_withoutPrecompile` | Gas cost for raw P-256 path with Solidity fallback |
| `test_gasEstimate_webauthn` | Gas cost for WebAuthn validation path |

### 4.4 P-256 Test Helpers (Wycheproof)

Use `ecdsa_secp256r1_sha256_p1363_test.json` from [C2SP/wycheproof](https://github.com/C2SP/wycheproof).

**Approach:**
- **Unit tests:** Hardcode a handful of vectors (valid signature, invalid signature, high-S, wrong key) directly in `test/helpers/P256Helper.sol`. These are self-contained — no file parsing, no external dependencies.
- **Comprehensive coverage (optional):** Parse the full Wycheproof JSON file via a test script for exhaustive vector testing.

**Explicitly not using:** `vm.ffi` to openssl, Rust helper binaries, or `vm.p256` cheatcodes.

### 4.5 WebAuthn End-to-End Testing (Frontend + Playwright)

Tests for the WebAuthn signature path require a real WebAuthn challenge/response flow. To test this end-to-end without human interaction:

**Architecture:**
- A **basic test frontend** served at `localhost:3000` that exercises the WebAuthn `navigator.credentials.create()` and `navigator.credentials.get()` flows against the smart contract's WebAuthn validation path.
- The frontend takes a challenge (the `userOpHash` or a test hash), triggers the WebAuthn ceremony, and outputs the authenticator data, client data JSON, and P-256 signature components needed for the contract's `>64 byte` WebAuthn signature path.
- **Playwright MCP server** drives the browser automation end-to-end — no human clicks, no manual passkey prompts. Playwright's `cdp` session can mock the WebAuthn authenticator via Chrome DevTools Protocol's `WebAuthn.addVirtualAuthenticator` and `WebAuthn.addCredential`, allowing fully automated passkey creation and assertion without hardware.

**Test flow:**
1. Start the test frontend (`localhost:3000`)
2. Playwright creates a virtual authenticator with a known P-256 keypair
3. Frontend triggers `navigator.credentials.create()` → registers the passkey
4. Frontend triggers `navigator.credentials.get()` with the test challenge → produces the WebAuthn assertion
5. Extract `authenticatorData`, `clientDataJSON`, `r`, `s` from the assertion
6. Encode the WebAuthn-wrapped signature per the contract's expected format
7. Submit to the contract (via Foundry fork test or live testnet) and verify validation passes

**Location:** The test frontend lives in `tests/webauthn-frontend/` at the monorepo root. It is a minimal HTML + JS page — not a production UI. Its sole purpose is enabling automated WebAuthn testing.

```
keypo-wallet/
├── tests/
│   ├── integration/
│   └── webauthn-frontend/       # Test-only WebAuthn frontend
│       ├── index.html           # Minimal page for WebAuthn ceremony
│       ├── package.json         # Dev dependencies (serve, playwright)
│       └── playwright.config.ts # Playwright test configuration
```

```solidity
// test/helpers/P256Helper.sol
//
// Hardcoded Wycheproof P1363 test vectors for P-256 signature validation.
// These provide known-good and known-bad test cases for both the raw P-256
// and WebAuthn paths.
//
// Interface:
// - P256TestVectors.TEST_QX, TEST_QY: known test public key coordinates
// - P256TestVectors.TEST_HASH: keccak256("test message")
// - P256TestVectors.TEST_R, TEST_S: valid signature over TEST_HASH (low-S normalized)
// - P256TestVectors.testSignature(): returns abi.encodePacked(TEST_R, TEST_S) (64 bytes)
// - P256TestVectors.INVALID_R, INVALID_S: corrupted signature values
// - P256TestVectors.HIGH_S: s value > N/2 (should be rejected)
//
// How to test:
// 1. Deploy KeypoAccount, initialize with (TEST_QX, TEST_QY)
// 2. Call _rawSignatureValidation(TEST_HASH, testSignature()) — should return true
// 3. Call _rawSignatureValidation(TEST_HASH, invalidSignature()) — should return false
// 4. Call _rawSignatureValidation(TEST_HASH, highSSignature()) — should return false
```

---

## 5. Deployment

### 5.1 CREATE2 Deployment

The implementation contract is deployed via CREATE2 for deterministic cross-chain addresses.

**Script interface** (`script/Deploy.s.sol`):
- Uses the Safe Singleton Factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C` (deployed on 248+ chains)
- Salt: `keccak256("keypo-account-v0.1.0")` (fixed for deterministic address)
- Computes expected address before deployment, checks if already deployed
- Deploys via Factory call with `abi.encodePacked(SALT, creationCode)`
- Verifies deployment by checking code exists at expected address

**How to test:**
- Unit test: verify `computeCreate2Address` produces the expected address for known inputs
- Integration test: deploy to a fork, verify code exists and matches expected code hash
- Idempotency test: running the script twice should detect existing deployment and skip

### 5.2 Post-Deployment Verification

**Script interface** (`script/Verify.s.sol`):
- Confirms code exists at the deployed address
- Confirms implementation's own storage is clean (sanity check for EIP-7702)
- Confirms ERC-165 interface support (if implemented)
- Logs code hash for cross-chain verification

**How to test:** Run against deployed address on Base Sepolia, verify all checks pass.

### 5.3 Deployment Targets

| Chain | Chain ID | Status | Priority | Notes |
|-------|----------|--------|----------|-------|
| Base Sepolia | 84532 | **First target** | P0 | Testnet. EIP-7702 confirmed. RIP-7212 active. EntryPoint v0.7 deployed. |
| Sepolia | 11155111 | Planned | P0 | Ethereum testnet. Pectra activated. |
| Base | 8453 | Planned | P1 | First mainnet target. RIP-7212 live. |
| Ethereum | 1 | Planned | P2 | Mainnet. RIP-7212 via Fusaka. |
| Optimism | 10 | Planned | P2 | RIP-7212 live. |
| Arbitrum | 42161 | Planned | P2 | RIP-7212 live. |

### 5.4 Deployment Record Format

Each deployment writes a JSON file to the shared `deployments/` directory at the repo root:

```json
{
  "chain": "base-sepolia",
  "chainId": 84532,
  "contract": "KeypoAccount",
  "address": "0x...",
  "deployTxHash": "0x...",
  "deployer": "0x...",
  "salt": "0x...",
  "codeHash": "0x...",
  "blockNumber": 12345678,
  "timestamp": "2026-03-01T00:00:00Z",
  "ozVersion": "5.2.0",
  "solcVersion": "0.8.28",
  "verified": true,
  "verificationUrl": "https://sepolia.basescan.org/address/0x..."
}
```

This file is consumed by the Rust client (`keypo-wallet`) to resolve implementation addresses per chain.

---

## 6. ABI Export

After compilation, the contract's ABI is exported for use by the Rust client:

```bash
forge build
cp out/KeypoAccount.sol/KeypoAccount.json ../keypo-wallet/abi/KeypoAccount.json
```

The Rust crate uses this ABI (via alloy's `sol!` macro or JSON ABI loading) to encode calldata. The key functions the client needs:

| Function | Selector | When Used |
|----------|----------|-----------|
| `initialize(bytes32,bytes32)` | `0x...` | Account setup — called once during EIP-7702 delegation tx |
| `execute(bytes32,bytes)` | `0x...` | Every transaction — ERC-7821 execution |

The client also needs to understand the **signature format** (64 bytes raw P-256 or WebAuthn-wrapped) and the **validation digest** (`userOpHash` for ERC-4337).

---

## 7. Contract Interface Specification

This section defines the interface contract that any smart account implementation must satisfy to be compatible with the `keypo-wallet` Rust crate. This is the **contract** (in the software-engineering sense) between this project and the Rust client.

### 7.1 Required Interface

Any compatible smart account implementation must:

1. **Accept P-256 public key during initialization.** A function that takes `(bytes32 qx, bytes32 qy)` and stores them as the account's signing key.

2. **Validate P-256 signatures on UserOperations.** Implement ERC-4337's `validateUserOp` such that the `signature` field contains either:
   - **Raw P-256 (64 bytes):** `abi.encodePacked(bytes32 r, bytes32 s)` — a raw P-256 signature over the `userOpHash`.
   - **WebAuthn-wrapped (>64 bytes):** A WebAuthn authentication assertion containing a P-256 signature, verified against the same `(qx, qy)` key.

3. **Support ERC-7821 execution.** Expose `execute(bytes32 mode, bytes calldata executionData)` for batch calls. Note: mode `0x01` (batch) is used for all calls, including single calls (encoded as a 1-element batch). Mode `0x00` is not used.

4. **Work as an EIP-7702 delegation target.** The contract must function correctly when its code is executed in the context of a delegating EOA (storage belongs to the EOA, not the implementation).

### 7.2 Interface Definition

```solidity
interface IKeypoCompatibleAccount {
    /// @notice Initialize the account with a P-256 signing key.
    function initialize(bytes32 qx, bytes32 qy) external;

    /// @notice Execute a batch of calls.
    /// @param mode 0x01...00 for batch (always — single calls use a 1-element batch).
    /// @param executionData Encoded call(s).
    function execute(bytes32 mode, bytes calldata executionData) external payable;
}
```

**Signature validation is not part of the explicit interface** — it is called internally by the ERC-4337 `validateUserOp` flow. Implementations must accept either 64-byte raw P-256 or WebAuthn-wrapped signatures (or both) as described in §7.1.

### 7.3 Swappability

To use a different smart account implementation with `keypo-wallet`:

1. Deploy the alternative implementation on the target chain
2. Verify it satisfies the interface in §7.1 — specifically, it must accept **P-256 signatures** (raw, WebAuthn, or both)
3. Pass its address to `keypo-wallet setup --implementation <address>`
4. If the signature format or digest computation differs, implement the corresponding `AccountImplementation` trait in the Rust crate (see keypo-wallet spec §3)

---

## 8. Future Work

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | WebAuthn signature encoding format | **DESIGN** | Confirm exact encoding format expected by OZ's `WebAuthn.verify()`. Document how `authenticatorData`, `clientDataJSON`, `r`, `s`, and challenge index are packed into the `signature` bytes field. |
| 2 | WebAuthn low-S enforcement | **VERIFY** | Confirm whether OZ's `WebAuthn.verify()` enforces low-S normalization or if the contract must enforce it before calling. |
