---
title: Alloy Version Pinning (1.7)
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# ADR-004: Alloy Version Pinning (1.7)

## Status

Accepted

## Context

The Rust crate depends on `alloy = "1.7"` for Ethereum provider, transaction, and ABI functionality. alloy 1.x has significant API differences from the 0.x versions commonly referenced in online tutorials, blog posts, and LLM training data.

## Decision

Pin to alloy 1.7 and document all API differences that commonly trip up agents and developers.

### Key API Differences from 0.x

| Operation | 0.x (wrong) | 1.7 (correct) |
|---|---|---|
| Create provider | `ProviderBuilder::new().on_http(url)` | `ProviderBuilder::new().connect_http(url)` |
| EIP-7702 types | `alloy = { features = ["eip7702"] }` | No feature flag needed -- available via default `eips` feature at `alloy::eips::eip7702::*` |
| `abi_decode()` | `abi_decode(data, validate)` | `abi_decode(data)` (single arg, no validate bool) |
| `provider.call()` | Takes `&TransactionRequest` | Takes owned `TransactionRequest` |
| Transaction builder | Import not needed | Must `use alloy::network::TransactionBuilder` for `with_to()` |

### Minimum Rust Version

alloy 1.7 requires Rust 1.91+. Earlier Rust versions will fail to compile.

## Consequences

- Do NOT add `eip7702` to the alloy features list in `Cargo.toml`. It does not exist and will cause a compile error.
- Use `connect_http()`, not `on_http()`.
- `dirs` crate must be version 6, not 5 (unrelated but commonly co-confused).
- Agents must disregard alloy 0.x examples found online.

## References

- `keypo-wallet/Cargo.toml` -- alloy dependency declaration
- [alloy documentation](https://docs.rs/alloy/latest/alloy/)
