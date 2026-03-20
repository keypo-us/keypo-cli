---
title: P-256 Pre-Hash Signing
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# ADR-002: P-256 Pre-Hash Signing

## Status

Accepted

## Context

The keypo-wallet system uses P-256 (secp256r1) ECDSA signatures for ERC-4337 UserOperation validation. The signing digest is computed off-chain (keccak256-based ERC-4337 hash), then signed by the Secure Enclave (production) or the p256 crate (tests). The on-chain contract verifies the signature against this raw digest.

Both CryptoKit (Swift) and the p256 crate (Rust) offer two signing APIs:

1. **High-level**: `signature(for: Data)` / `Signer::sign()` -- hashes the input with SHA-256 before signing.
2. **Low-level**: `signature(for: Digest)` / `PrehashSigner::sign_prehash()` -- signs the input bytes directly, no hashing.

## Decision

All P-256 signing in this project MUST use the pre-hash / low-level API. The input is already a 32-byte digest. Applying SHA-256 again produces `SHA256(keccak256(hash))` instead of `keccak256(hash)`, which the on-chain P-256 verifier rejects (ERC-4337 error AA24).

### Rust (MockSigner in `keypo-wallet/src/signer.rs`)

```rust
use p256::ecdsa::{signature::hazmat::PrehashSigner, Signature, SigningKey};

let sig: Signature = signing_key
    .sign_prehash(digest)  // NOT .sign(digest)
    .map_err(|e| Error::Other(format!("P-256 signing failed: {e}")))?;
```

### Swift (SecureEnclaveManager in `keypo-signer/Sources/KeypoCore/SecureEnclaveManager.swift`)

```swift
// Cast 32-byte input to SHA256Digest to use signature(for: Digest)
// which signs without additional hashing.
let digest: SHA256Digest = data.withUnsafeBytes { ptr in
    ptr.baseAddress!.assumingMemoryBound(to: SHA256Digest.self).pointee
}
let signature = try privateKey.signature(for: digest)  // NOT signature(for: Data)
```

## Consequences

- **NEVER** use `Signer::sign()` or `signature(for: Data)` for signing ERC-4337 digests. Both apply SHA-256, causing double-hashing.
- The `SHA256Digest` unsafe cast in Swift is safe because `SHA256Digest` is a 32-byte value type with matching memory layout. This is the only way to pass a pre-computed digest to CryptoKit's Secure Enclave API.
- All P-256 signatures must also be low-S normalized (s <= curve_order/2). This is a separate concern but frequently co-located with the signing code.
- This bug was discovered post-Phase-6 and caused AA24 signature errors in production. It affected both the Swift CLI and the Rust MockSigner independently.

## References

- `keypo-wallet/src/signer.rs` line 281 -- Rust PrehashSigner usage
- `keypo-signer/Sources/KeypoCore/SecureEnclaveManager.swift` lines 82-95 -- Swift SHA256Digest cast
- ERC-4337 error AA24: "AA24 signature error" indicates signature validation failure in the smart account's `validateUserOp`
