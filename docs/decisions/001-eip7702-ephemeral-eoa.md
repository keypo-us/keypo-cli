---
title: EIP-7702 Ephemeral EOA for Setup
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# ADR-001: EIP-7702 Ephemeral EOA for Setup

## Status

Accepted

## Context

EIP-7702 delegation requires a type-4 transaction signed by a secp256k1 (Ethereum-native) key. The transaction's authorization list contains `{ chain_id, address, nonce }` tuples that must be signed by the EOA being delegated.

Keypo-wallet's signing keys are P-256 (secp256r1) stored in the Secure Enclave. P-256 keys cannot sign Ethereum transactions -- they use a different curve. We need a secp256k1 key to submit the type-4 setup transaction.

## Decision

Generate an **ephemeral secp256k1 private key** in memory for each setup. This key:

1. Derives a fresh Ethereum address that becomes the user's smart account address.
2. Signs the EIP-7702 authorization (delegating to the KeypoAccount implementation).
3. Signs the type-4 transaction that includes both the delegation and the `initialize(qx, qy)` call.
4. Is **zeroized and dropped** immediately after the setup transaction confirms.

The account is then permanently controlled by the P-256 key via the delegated KeypoAccount code. The ephemeral secp256k1 key is never stored or recoverable.

### Auth Nonce Rule

When the sender and authority are the same address (which they always are in our setup flow), the authorization nonce must be `current_nonce + 1`. This is because the sender's nonce is incremented BEFORE the authorization list is processed, per the EIP-7702 specification.

```rust
// In account.rs setup flow
let current_nonce = provider.get_transaction_count(address).await?;
let auth = Authorization {
    chain_id: U256::from(chain_id),
    address: implementation_address,
    nonce: current_nonce + 1,  // NOT current_nonce
};
```

### Gas Limit

Type-4 transactions with EIP-7702 authorization lists need a manually specified gas limit (500,000). Auto-estimation fails because it simulates against the EOA's current (empty) code, not the post-delegation code.

## Consequences

- Each `setup` invocation creates a new, unique Ethereum address. There is no address reuse.
- The ephemeral key exists only in memory for the duration of the setup transaction. No secret key material is written to disk.
- The P-256 key in the Secure Enclave becomes the sole controller of the account after setup.
- Multi-chain support for the same address would require storing the ephemeral key, which we deliberately avoid. Currently, `setup()` early-fails if a key already has an account on any chain (`MultiChainNotSupported`).

## References

- `keypo-wallet/src/account.rs` -- setup flow implementation
- EIP-7702 specification: authorization list processing order
- `keypo-wallet/src/types.rs` -- `SetupConfig`, `FundingStrategy`
