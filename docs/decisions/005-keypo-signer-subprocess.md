---
title: keypo-signer as Subprocess (not FFI)
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# ADR-005: keypo-signer as Subprocess (not FFI)

## Status

Accepted

## Context

The Rust CLI needs to create P-256 keys, sign data, and manage key metadata using Apple's Secure Enclave. The Secure Enclave API is only available through Apple frameworks (CryptoKit, Security), which are Swift/Objective-C only. We needed to bridge this gap.

### Alternatives Considered

1. **FFI binding** (Rust -> C -> Swift): Complex build system, fragile across Xcode versions, requires managing memory across language boundaries.
2. **Shared library** (Swift framework linked into Rust): Same complexity as FFI, plus code-signing complications.
3. **Subprocess** (shell out to a Swift CLI): Simple, well-defined interface, independently deployable.

## Decision

Use a **subprocess approach**: the Rust crate shells out to the `keypo-signer` Swift CLI binary and parses its JSON output. The interface contract is defined in [keypo-signer/JSON-FORMAT.md](../../keypo-signer/JSON-FORMAT.md).

```rust
// In signer.rs -- KeypoSigner shells out to the binary
let output = Command::new("keypo-signer")
    .args(["sign", hex_data, "--key", label, "--format", "json"])
    .output()?;
let result: SignResult = serde_json::from_slice(&output.stdout)?;
```

## Consequences

- `keypo-signer` must be installed and on `$PATH`. The CLI provides a helpful error message with `brew install` instructions if it's not found.
- The interface is the JSON output format. Changes to JSON field names or structure are breaking changes. See [JSON-FORMAT.md](../../keypo-signer/JSON-FORMAT.md) for the verified schema.
- The subprocess approach adds latency (~50ms per invocation) but this is negligible compared to network round-trips.
- Each tool can be versioned and released independently. `keypo-signer` is distributed via Homebrew with code-signing and notarization.
- The Rust crate includes a `MockSigner` (gated on `test-utils` feature) that implements the same trait without requiring the Swift binary, enabling CI testing on Linux.

## References

- `keypo-wallet/src/signer.rs` -- `KeypoSigner` implementation
- `keypo-signer/JSON-FORMAT.md` -- JSON output contract
- `keypo-signer/CLAUDE.md` -- Swift project architecture
