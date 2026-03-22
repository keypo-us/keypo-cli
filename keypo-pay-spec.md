# keypo-pay: Secure Enclave Wallet for Tempo

## Overview

keypo-pay is a Rust CLI wallet for the Tempo blockchain that uses Apple Secure Enclave P-256 keys as native Tempo account keys. It implements a root-key-plus-access-keys architecture where a biometric-gated root key delegates scoped spending authority to one or more open-policy access keys, enabling autonomous agents to transact within user-defined limits without repeated biometric prompts.

keypo-pay lives at the root level of the keypo-cli monorepo, adjacent to keypo-wallet (the existing ERC-4337/EIP-7702 Rust wallet). It depends on keypo-signer (called as a subprocess) for all Secure Enclave operations.

## Motivation

Tempo natively supports P-256 ECDSA signatures and WebAuthn at the protocol level. Users can derive Tempo addresses directly from P-256 public keys without requiring secp256k1 or smart contract account abstraction. The Secure Enclave generates and stores P-256 keys in hardware, making keypo-signer a natural Tempo signer.

Tempo's Access Key system allows a root key to provision scoped access keys with per-TIP-20 token spending limits, expiry timestamps, and a strict authorization hierarchy enforced at the protocol level. This mirrors keypo-signer's vault tier model (biometric/passcode/open) and enables a two-layer enforcement architecture: device-level policy from keypo-signer and network-level constraints from Tempo.

The primary use case is agent-initiated payments over the Machine Payments Protocol (MPP). An agent holds a reference to the open-policy access key and can sign MPP credentials (Tempo charge and session vouchers) within the bounds the user authorized, without biometric prompts per transaction.

## Architecture

### Root Key + Access Keys Model

keypo-pay manages one root key and zero or more access keys, all P-256 keys in the Secure Enclave:

**Root Key (biometric policy)**
- Gated behind LAContext biometric authentication (Face ID / Touch ID)
- Derives the Tempo account address via `keccak256(abi.encodePacked(pubKeyX, pubKeyY))`, taking the last 20 bytes
- Only key authorized to call AccountKeychain precompile mutations: `authorizeKey`, `revokeKey`, `updateSpendingLimit`
- Used infrequently: wallet setup, delegation, limit updates, revocation

**Access Keys (open policy)**
- No biometric gate; available to any process with access to keypo-signer
- Each access key is independently authorized by the root key via Tempo's `KeyAuthorization` mechanism
- Each has its own spending limits, expiry, and revocation status
- Signs transactions using Tempo's Keychain signature format (type `0x03` + root account address + inner P-256 signature)
- Subject to on-chain spending limits per TIP-20 token and expiry timestamp
- Used frequently: every agent-initiated payment
- Multiple access keys enable scoped delegation per agent or use case (e.g., one key for a shopping agent with a $50 limit, another for an LLM inference agent with a $5 limit)

Wallet initialization creates only the root key. Access keys are created and authorized as separate actions.

### Dependency on keypo-signer

keypo-pay calls keypo-signer as a subprocess for all Secure Enclave operations, following the same pattern as the existing keypo-wallet. It does not access the Secure Enclave directly. The keypo-signer CLI provides:

- Key generation with configurable access control policy (open, passcode, biometric)
- P-256 ECDSA signing (returns raw r, s, pubX, pubY)
- Key enumeration and metadata

### Relationship to keypo-wallet

keypo-pay is a separate Rust binary from keypo-wallet. They share keypo-signer as a dependency (called as a subprocess) but target different chains and account models:

- keypo-wallet: Ethereum L1/L2, ERC-4337 UserOps, secp256k1 (with P-256 for on-chain signature validation), Pimlico bundler
- keypo-pay: Tempo, native Tempo transactions (type `0x76`), P-256 natively, no bundler needed

## Features

### 1. Wallet Initialization

Create a new keypo-pay wallet. This generates a single root key in the Secure Enclave and derives the Tempo account address. Access keys are created separately (see Feature 3).

**Behavior:**
- Generate root key in SE with biometric policy (or open policy in test mode)
- Derive Tempo address from root key public coordinates: `address = last20bytes(keccak256(pubKeyX || pubKeyY))`
- Store wallet metadata to `~/.keypo/tempo/wallet.toml` containing: root key identifier, Tempo address, chain ID, RPC endpoint
- The wallet is not usable on-chain until funded

**CLI:**
- `keypo-pay wallet create` — creates the wallet (root key only)
- `keypo-pay wallet info` — displays address, root key ID, chain ID, and lists all access keys with their on-chain status
- `keypo-pay wallet create --test` — creates wallet with root key using open policy (for automated testing)

### 2. Tempo Transaction Construction and Signing

Build and sign Tempo transactions (type `0x76`) using either the root key or the access key.

**Behavior:**
- Construct the Tempo transaction struct with all required fields: chain_id, nonce, nonce_key, calls, gas_limit, max_fee_per_gas, max_priority_fee_per_gas, and optional fields (fee_token, valid_before, valid_after, key_authorization, fee_payer_signature)
- RLP-encode the transaction per the Tempo spec
- Compute the signing hash: `keccak256(0x76 || rlp(fields))`
- Call keypo-signer to produce a P-256 signature over the hash
- Format the signature as Tempo P-256 (type `0x01` + r + s + pubX + pubY + pre_hash byte) when signing with root key
- Format the signature as Tempo Keychain (type `0x03` + root_address + inner P-256 signature) when signing with access key
- Serialize the signed transaction envelope: `0x76 || rlp(fields || signature)`

**RPC interaction:**
- Fetch nonce via `eth_getTransactionCount` (for nonce_key 0) or the Nonce precompile for user nonce keys
- Fetch gas estimates via `eth_estimateGas` or use sensible defaults
- Submit via `eth_sendRawTransaction`
- Wait for receipt via `eth_getTransactionReceipt` with polling

**CLI:**
- `keypo-pay tx send --to <address> --token <token_address> --amount <amount>` — send a TIP-20 transfer signed by root key
- `keypo-pay tx send --to <address> --token <token_address> --amount <amount> --key <name>` — send using a named access key (Keychain signature)

### 3. Access Key Management

Create, authorize, revoke, and manage multiple access keys. Creating an access key (generating an SE key) and authorizing it on-chain (registering with the AccountKeychain precompile) are separate actions.

**Key Creation Behavior:**
- Generate a new P-256 key in SE with open policy
- Assign a user-provided name for local reference (e.g., "shopping-agent", "llm-agent")
- Derive the key's Tempo address from its public coordinates
- Store the key name, keypo-signer key identifier, and derived address in `~/.keypo/tempo/access-keys.toml`
- The key is not usable on-chain until authorized

**Authorization Behavior:**
- Construct a `KeyAuthorization` struct: chain_id, key_type (P256 = 1), key_id (access key address derived from its public key), expiry (optional unix timestamp), limits (list of token address + amount pairs)
- RLP-encode the authorization: `rlp([chain_id, key_type, key_id, expiry?, limits?])`
- Compute the authorization digest: `keccak256(rlp_encoded_authorization)`
- Sign the digest with the root key via keypo-signer (biometric prompt in production, no prompt in test mode)
- Build a Tempo transaction that includes the `key_authorization` field with the signed authorization
- The transaction itself is signed by the access key (the "authorize and use" pattern), or by the root key if no simultaneous operation is needed
- Submit and confirm receipt
- The access key is now active on-chain with the specified limits

**CLI:**
- `keypo-pay access-key create --name <name>` — generate a new SE key with open policy and store locally
- `keypo-pay access-key create --name <name> --test` — same, using open policy for root key signing during authorization (automated testing)
- `keypo-pay access-key authorize --name <name> --token <token_address> --limit <amount> [--expiry <unix_timestamp_or_duration>]` — authorize the named key on-chain with spending limits
- `keypo-pay access-key authorize --name <name> --token <token_address> --limit <amount> --token <token_address_2> --limit <amount_2>` — multiple token limits in one authorization
- `keypo-pay access-key list` — list all local access keys with their on-chain status (authorized/revoked/not-yet-authorized), expiry, and remaining limits
- `keypo-pay access-key info --name <name>` — query the AccountKeychain precompile for a specific key's status, expiry, remaining limits
- `keypo-pay access-key revoke --name <name>` — revoke an access key on-chain (root key signs a call to `revokeKey`)
- `keypo-pay access-key update-limit --name <name> --token <token_address> --limit <new_amount>` — update a spending limit (root key signs a call to `updateSpendingLimit`)
- `keypo-pay access-key delete --name <name>` — remove a local access key entry (does not revoke on-chain; warn if still authorized)

### 4. TIP-20 Token Operations

Send TIP-20 token transfers, query balances, and manage a local token address book.

**Transfer Behavior:**
- Query balance via the TIP-20 `balanceOf` contract call
- Construct `transfer(to, amount)` calldata for token transfers
- Support `transferWithMemo(to, amount, memo)` if Tempo's TIP-20 supports it
- When using an access key (`--key <name>`), the on-chain spending limit is enforced by the protocol; if the transfer exceeds the remaining limit, the transaction reverts with `SpendingLimitExceeded`

**Token Address Book:**
- Store commonly used token addresses with human-readable names in `~/.keypo/tempo/tokens.toml`
- Pre-populate with testnet defaults: `pathusd` (`0x20c0...000`), `alphausd` (`0x20c0...001`), `betausd` (`0x20c0...002`), `thetausd` (`0x20c0...003`)
- Tokens can be referenced by name anywhere a `--token` flag is accepted (e.g., `--token pathusd` instead of `--token 0x20c0...000`)
- Users can add, remove, and list custom token entries

**CLI:**
- `keypo-pay balance [--token <name_or_address>]` — show token balance (defaults to pathusd)
- `keypo-pay send --to <address> --amount <amount> [--token <name_or_address>] [--memo <text>] --key <name>` — send tokens using a named access key
- `keypo-pay send --to <address> --amount <amount> [--token <name_or_address>] --use-root-key` — send tokens using root key (bypasses spending limits)
- `keypo-pay token add --name <name> --address <token_address>` — save a token address to the address book
- `keypo-pay token remove --name <name>` — remove a token from the address book
- `keypo-pay token list` — list all saved tokens with names and addresses

### 5. MPP Client Integration

Pay for MPP-enabled services using the Tempo charge and session intents.

**Behavior:**
- Make an HTTP request to an MPP-enabled endpoint
- Parse the 402 response to extract the Challenge from `WWW-Authenticate: Payment method="tempo" intent="charge|session" ...`
- For charge intent: construct a TIP-20 transfer to the recipient address for the specified amount, sign with the access key, submit on-chain, build the Credential with the transaction hash as proof, retry the original request with `Authorization: Payment <credential>`
- For session intent: open a payment channel by depositing funds into the escrow contract, then sign off-chain vouchers for each subsequent request using the access key; the session lifecycle (open, voucher, close) should be managed automatically
- Parse the Receipt from the `Payment-Receipt` header on successful responses

**CLI:**
- `keypo-pay pay <url> --key <n>` — make a single paid request using a named access key (charge intent)
- `keypo-pay pay <url> --key <n> --session` — open a session and make paid requests (session intent)
- `keypo-pay pay <url> --key <n> --session --max-deposit <amount>` — cap the session deposit

**Note:** The MPP client integration may depend on the mppx TypeScript SDK or reimplement the protocol natively. The planning session should evaluate both approaches and choose based on complexity. A minimal viable approach is to implement the HTTP transport charge flow natively and defer session support.

### 6. Configuration

**Wallet config:** `~/.keypo/tempo/wallet.toml`

Required fields:
- `chain_id` — Tempo chain ID
- `rpc_url` — Tempo RPC endpoint
- `root_key_id` — keypo-signer key identifier for the root key
- `address` — derived Tempo account address

Optional fields:
- `default_token` — default token name or address for operations (defaults to `pathusd`)
- `block_explorer_url` — for linking to transaction receipts in CLI output

**Access keys config:** `~/.keypo/tempo/access-keys.toml`

A list of access key entries, each with:
- `name` — user-assigned name (e.g., "shopping-agent")
- `key_id` — keypo-signer key identifier
- `address` — derived Tempo address for this key

**Token address book:** `~/.keypo/tempo/tokens.toml`

A list of token entries, each with:
- `name` — human-readable name (e.g., "pathusd")
- `address` — TIP-20 contract address

Pre-populated with testnet defaults on wallet creation.

**Precedence:** CLI flags > environment variables > config file (same pattern as keypo-wallet)

## Tempo Protocol Reference

This section captures the protocol details the implementation must conform to. All values are sourced from the Tempo Transaction Specification.

### Transaction Type

EIP-2718 type byte: `0x76`

### P-256 Signature Format

Type identifier `0x01`, total 130 bytes:
- 1 byte: type ID (`0x01`)
- 32 bytes: r
- 32 bytes: s
- 32 bytes: public key X coordinate
- 32 bytes: public key Y coordinate
- 1 byte: pre_hash flag (set to `true` if the signer pre-hashes with SHA-256 before signing; the Secure Enclave's `SecKeyCreateSignature` with `ecdsaSignatureMessageX962SHA256` does pre-hash internally, so this flag should be `true`)

### Keychain Signature Format

Type identifier `0x03`, variable length:
- 1 byte: type ID (`0x03`)
- 20 bytes: root account address (the user_address)
- Variable: inner signature (P-256 format as above, 130 bytes)

Total: 151 bytes for P-256 inner signature.

### Address Derivation from P-256 Public Key

`address = bytes20(keccak256(abi.encodePacked(pubKeyX, pubKeyY)))`

This takes the last 20 bytes of the keccak256 hash of the concatenated 32-byte X and Y coordinates.

### KeyAuthorization RLP Encoding

Unsigned: `rlp([chain_id, key_type, key_id, expiry?, limits?])`

Where:
- `chain_id`: u64 (0 = valid on any chain)
- `key_type`: 0 (secp256k1), 1 (P256), 2 (WebAuthn)
- `key_id`: 20-byte address derived from the access key's public key
- `expiry`: optional u64 unix timestamp (omit or `0x80` if none)
- `limits`: optional list of `[token_address, limit_amount]` pairs (omit or `0x80` if none)

The root key signs: `keccak256(rlp([chain_id, key_type, key_id, expiry?, limits?]))`

Signed format appends the signature: `rlp([chain_id, key_type, key_id, expiry?, limits?, signature])`

### AccountKeychain Precompile

Address: `0xAAAAAAAA00000000000000000000000000000000`

Relevant functions:
- `authorizeKey(keyId, signatureType, expiry)` — root key only
- `revokeKey(keyId)` — root key only
- `updateSpendingLimit(keyId, token, newLimit)` — root key only; replaces (does not add to) remaining limit
- `getKey(account, keyId)` — returns `KeyInfo { signatureType, keyId, expiry }`
- `getRemainingLimit(account, keyId, token)` — returns remaining spending limit
- `getTransactionKey()` — returns the key ID that signed the current transaction (0x0 for root)

### Spending Limit Semantics

- Limits apply only to TIP-20 `transfer()`, `transferWithMemo()`, `approve()`, and `startReward()` calls
- Limits apply only when `msg.sender == tx.origin` (direct EOA calls, not contracts calling on behalf)
- Native value transfers are not limited
- Limits deplete as spent; they do not reset automatically
- Root key operations bypass all spending limits

### Gas Costs

Base transaction gas by signature type:
- secp256k1: 21,000
- P256: 26,000 (21,000 + 5,000)
- Keychain with P-256 inner: 29,000 (26,000 + 3,000 key validation)

Key authorization additional gas:
- P256 root signature: 35,000 base + 22,000 per spending limit entry

### Pre-hash Behavior

keypo-signer uses CryptoKit's `SecureEnclave.P256.Signing.PrivateKey.signature(for:)` with the `Digest`-typed overload. When the input is exactly 32 bytes (a pre-hashed digest), it reinterprets the raw bytes as a `SHA256Digest` via `assumingMemoryBound` and signs directly without any additional hashing. The SE treats the 32 bytes as the already-computed hash and feeds them straight into ECDSA. `SecKeyCreateSignature` is explicitly avoided (per keypo-signer's CLAUDE.md: "SecKeyCreateSignature hashes the input. Do NOT use it.").

**Therefore: `pre_hash = false` in Tempo's P-256 signature format.** No double-hashing occurs. The flow is:
1. Compute the Tempo transaction signing hash: `keccak256(0x76 || rlp(fields))`
2. Pass the 32-byte keccak256 digest to keypo-signer's `sign` command
3. keypo-signer signs it directly via the SE (no additional SHA-256)
4. Set `pre_hash = false` (0x00) in the signature so Tempo's verifier performs raw P-256 verification over the keccak256 digest without SHA-256 pre-hashing

## Test Plan

All tests use open-policy keys (no biometric or passcode prompts). Tests run against Tempo testnet. Every feature must be validated by automated tests before it is considered complete.

### Test Environment Setup

- All wallet creation uses `--test` flag to produce open-policy keys for both root and access keys
- Tempo testnet RPC endpoint: `https://rpc.moderato.tempo.xyz`
- Testnet faucet: call `tempo_fundAddress` RPC method with the wallet address on the testnet RPC endpoint. This is a JSON-RPC call, not a web UI. Each call provides 1M of each testnet stablecoin (pathUSD, AlphaUSD, BetaUSD, ThetaUSD). The test harness should call this automatically before running tests.
- pathUSD testnet address: `0x20c0000000000000000000000000000000000000`
- **All test amounts must be very small** (0.001 to 0.10 tokens) to allow thousands of test transactions per faucet drip without concern for running out of testnet funds
- Tests should be runnable via a single command (e.g., `make test-pay` or equivalent)
- Each test run should create a fresh wallet to avoid state pollution between runs

### T1: Wallet Creation

**T1.1 — Root key generation and address derivation**
- Create a wallet with `--test` flag
- Verify one root key ID is stored in wallet.toml
- Verify no access keys exist in access-keys.toml
- Verify the Tempo address is 20 bytes and matches `last20bytes(keccak256(pubKeyX || pubKeyY))` computed independently from the root key's public coordinates
- Verify the config file is well-formed and contains all required fields
- Verify tokens.toml is pre-populated with testnet defaults (pathusd, alphausd, betausd, thetausd)

**T1.2 — Idempotency guard**
- Create a wallet, then attempt to create again
- Verify the second creation fails (or prompts for overwrite) rather than silently overwriting

**T1.3 — Wallet info display**
- Create a wallet, run `wallet info`
- Verify output contains the address, root key ID, and chain ID

### T2: Transaction Construction and Signing

**T2.1 — Root key P-256 signature format**
- Construct a minimal Tempo transaction (single call, nonce_key 0)
- Sign with the root key
- Verify the signature is exactly 130 bytes
- Verify the first byte is `0x01`
- Verify the public key coordinates in the signature match the root key's known public key
- Verify the last byte (pre_hash flag) is `0x00` (false), confirming no double-hashing

**T2.2 — Access key Keychain signature format**
- Sign the same transaction with the access key
- Verify the first byte is `0x03`
- Verify bytes 1-20 are the root account address
- Verify the inner signature is 130 bytes and starts with `0x01`

**T2.3 — RLP encoding round-trip**
- Construct a transaction, RLP-encode it, decode it back
- Verify all fields match the original

**T2.4 — Transaction submission (root key)**
- Fund the test wallet with testnet tokens
- Send a small TIP-20 transfer signed by the root key
- Verify the transaction is included in a block (receipt with status 1)
- Verify the sender address in the receipt matches the wallet address

**T2.5 — Nonce management**
- Send two transactions sequentially
- Verify nonces increment correctly
- Verify the second transaction does not fail due to nonce collision

### T3: Access Key Management

**T3.1 — Create access key locally**
- Create a wallet, then create an access key named "agent-1"
- Verify access-keys.toml contains one entry with name "agent-1", a key_id, and a derived address
- Verify the access key is not yet authorized on-chain (query `getKey` returns nothing)

**T3.2 — Create multiple access keys**
- Create two access keys named "agent-1" and "agent-2"
- Verify access-keys.toml contains two entries with distinct key IDs and addresses

**T3.3 — Duplicate name guard**
- Create an access key named "agent-1", then attempt to create another with the same name
- Verify the second creation fails with a clear error

**T3.4 — Authorize access key with spending limit**
- Create and fund a test wallet
- Create and authorize "agent-1" with a spending limit of 0.10 pathUSD, no expiry
- Query the AccountKeychain precompile `getKey` to verify the key is registered
- Query `getRemainingLimit` to verify the limit matches 0.10 pathUSD (in token units)

**T3.5 — Authorize with expiry**
- Authorize "agent-1" with a spending limit and a short expiry (e.g., current time + 3600 seconds)
- Query `getKey` to verify the expiry timestamp is set correctly

**T3.6 — Authorize with multiple token limits**
- Authorize "agent-1" with limits on two different TIP-20 tokens (0.10 pathUSD + 0.10 alphausd)
- Query `getRemainingLimit` for each token to verify both are set correctly

**T3.7 — Authorize multiple keys independently**
- Create "agent-1" and "agent-2"
- Authorize "agent-1" with 0.10 pathUSD limit
- Authorize "agent-2" with 0.05 pathUSD limit
- Query limits for both and verify they are independent

**T3.8 — Revoke access key**
- Authorize "agent-1", then revoke it
- Attempt to send a transaction with "agent-1"
- Verify the transaction fails (key is no longer authorized)
- Verify other access keys (if any) are unaffected

**T3.9 — Update spending limit**
- Authorize "agent-1" with 0.10 pathUSD limit
- Update the limit to 0.20
- Query `getRemainingLimit` to verify it is now 0.20 (not 0.30)

**T3.10 — Access key cannot self-escalate**
- Authorize "agent-1" with a spending limit
- Attempt to call `authorizeKey`, `revokeKey`, or `updateSpendingLimit` from a transaction signed by "agent-1"
- Verify each call reverts with `UnauthorizedCaller`

**T3.11 — List access keys**
- Create two access keys, authorize one, leave the other not-yet-authorized
- Run `access-key list`
- Verify output shows both keys with correct statuses (authorized vs not-yet-authorized)

**T3.12 — Delete local access key with warning**
- Create and authorize "agent-1"
- Run `access-key delete --name agent-1`
- Verify a warning is emitted that the key is still authorized on-chain
- Verify the entry is removed from access-keys.toml

### T4: TIP-20 Token Operations

All transfer amounts use very small values (0.01 - 0.10 tokens) to allow thousands of test transactions on testnet without concern for faucet limits.

**T4.1 — Balance query**
- Fund the test wallet
- Query balance and verify it is non-zero

**T4.2 — Balance query by token name**
- Query balance using `--token pathusd` (name from address book)
- Verify it returns the same result as using the full address

**T4.3 — Transfer with access key (within limits)**
- Authorize "agent-1" with 0.10 pathUSD limit
- Send 0.01 pathUSD using "agent-1"
- Verify transfer succeeds (receipt status 1)
- Query `getRemainingLimit` and verify it decreased by 0.01

**T4.4 — Transfer with access key (exceeds limits)**
- Authorize "agent-1" with 0.10 pathUSD limit
- Attempt to send 0.15 pathUSD using "agent-1"
- Verify the transaction reverts with `SpendingLimitExceeded`
- Verify the sender's balance is unchanged (minus gas)

**T4.5 — Transfer with root key (bypasses limits)**
- With "agent-1" limited to 0.10 pathUSD, send 0.15 pathUSD using root key
- Verify transfer succeeds

**T4.6 — Spending limit depletion**
- Authorize "agent-1" with 0.05 pathUSD limit
- Send 0.02 (success, 0.03 remaining)
- Send 0.02 (success, 0.01 remaining)
- Send 0.02 (fail, only 0.01 remaining)
- Send 0.01 (success, 0 remaining)
- Send 0.01 (fail, 0 remaining)

**T4.7 — Independent limits across access keys**
- Authorize "agent-1" with 0.10 pathUSD limit and "agent-2" with 0.05 pathUSD limit
- Send 0.10 pathUSD using "agent-1" (success, depletes "agent-1")
- Send 0.05 pathUSD using "agent-2" (success, "agent-2" limit is independent)

**T4.8 — Token address book add and use**
- Add a custom token: `token add --name mytoken --address 0x...`
- Verify it appears in `token list`
- Use `--token mytoken` in a balance query and verify it resolves to the correct address

**T4.9 — Token address book remove**
- Add a token, then remove it
- Verify it no longer appears in `token list`
- Verify using the removed name returns an error

### T5: MPP Client Integration

**T5.1 — Charge intent end-to-end**
- Stand up a local test server using mppx that charges 0.001 pathUSD per request via Tempo charge
- Fund the test wallet, create and authorize "agent-1" with 0.01 pathUSD limit
- Run `keypo-pay pay <local_url> --key agent-1`
- Verify the 402 challenge is received, credential is constructed, payment is submitted on-chain, and the response body is returned successfully
- Verify the Receipt header is present in the response

**T5.2 — Charge intent with insufficient funds**
- Set up a test server charging more than the wallet balance
- Verify the payment fails gracefully with a clear error message

**T5.3 — Charge intent with insufficient access key limit**
- Authorize "agent-1" with a limit less than the charge amount
- Attempt to pay
- Verify the transaction reverts and the error surfaces to the user

**T5.4 — Session intent (if implemented)**
- Stand up a local test server using mppx with session-based billing at 0.001 pathUSD per request
- Open a session with `--max-deposit 0.01`
- Make multiple requests and verify each succeeds with voucher-based payment
- Close the session and verify unspent deposit is reclaimable

### T6: Configuration

**T6.1 — Config file creation**
- Create a wallet and verify `~/.keypo/tempo/wallet.toml` exists with all required fields
- Verify `~/.keypo/tempo/tokens.toml` exists with pre-populated testnet tokens
- Verify `~/.keypo/tempo/access-keys.toml` exists (empty)

**T6.2 — CLI flag override**
- Set a default RPC URL in config, then pass a different one via CLI flag
- Verify the CLI flag value is used

**T6.3 — Environment variable override**
- Set an env var for RPC URL, with a different value in config
- Verify the env var takes precedence over config but not over CLI flags

**T6.4 — Token name resolution**
- Add a custom token to tokens.toml
- Use the token name in a `--token` flag
- Verify it resolves to the correct address

### T7: Error Handling

**T7.1 — No wallet exists**
- Run any command without creating a wallet first
- Verify a clear error message directs the user to run `wallet create`

**T7.2 — Access key not authorized**
- Create a wallet and an access key but do not authorize it on-chain
- Attempt to send a transaction with `--key agent-1`
- Verify a clear error message indicates the access key is not authorized on-chain

**T7.3 — Expired access key**
- Authorize "agent-1" with a very short expiry (e.g., 5 seconds in test)
- Wait for expiry
- Attempt to send a transaction with "agent-1"
- Verify the transaction fails with an appropriate error

**T7.4 — RPC connectivity failure**
- Set RPC URL to an unreachable endpoint
- Attempt any network operation
- Verify a clear error message about connectivity

**T7.5 — Insufficient gas**
- Attempt a transaction with zero native balance (unable to pay gas, assuming no fee sponsor)
- Verify a clear error about insufficient gas funds

**T7.6 — Unknown access key name**
- Attempt to use `--key nonexistent`
- Verify a clear error that the key name is not found locally

## Open Questions for Planning Session

1. **~~Language choice:~~** RESOLVED. keypo-pay is written in Rust, same as keypo-wallet. It calls keypo-signer as a subprocess for SE operations. Tempo has a Rust SDK, and alloy provides RLP encoding, keccak256 hashing, and ABI encoding.

2. **~~Pre-hash flag:~~** RESOLVED. keypo-signer uses CryptoKit's Digest-typed overload with no internal SHA-256. `pre_hash = false`.

3. **MPP implementation strategy:** Implement the Tempo charge flow natively (parse 402, construct credential, retry) or wrap/call the mppx TypeScript SDK? Native is simpler for charge but session support is complex.

4. **Fee sponsorship:** Should keypo-pay support gas-sponsored transactions from the start, or defer? Tempo's protocol supports fee payer signatures natively. For testnet, faucet tokens may be sufficient.

5. **Testnet vs mainnet:** The spec assumes testnet. For mainnet, the pathUSD token address is different (`0x20c000000000000000000000b9537d11c60e8b50`). Should the config support switching between testnet and mainnet profiles?

6. **Session key rotation:** Should keypo-pay support periodic rotation of the access key (revoke old, authorize new) as a security measure? If so, what triggers rotation?
