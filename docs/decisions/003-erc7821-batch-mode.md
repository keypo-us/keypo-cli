---
title: ERC-7821 Batch Mode Only
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# ADR-003: ERC-7821 Batch Mode Only

## Status

Accepted

## Context

ERC-7821 defines `execute(bytes32 mode, bytes executionData)` for smart account execution. The `mode` parameter determines how `executionData` is interpreted:

- `0x00` -- single call mode: `executionData = abi.encode(target, value, calldata)`
- `0x01` -- batch mode: `executionData = abi.encode(Call[])` where `Call = (target, value, calldata)`

The KeypoAccount contract implements ERC-7821 execution. We need to decide which mode(s) to use in the CLI.

## Decision

**Always use mode byte `0x01` (batch mode).** Single calls are encoded as a one-element batch. Never use mode `0x00`.

```rust
// In transaction.rs -- building the execute calldata
let mode = B256::left_padding_from(&[0x01]);  // Always batch mode

// Single call is a one-element array
let calls = vec![Call { target, value, data }];
let execution_data = calls.abi_encode();
```

### Why Not Support Both Modes?

1. **Simplicity**: One code path for encoding, one for decoding. No conditional logic based on call count.
2. **Consistency**: Every UserOp uses the same mode byte, making gas estimation, debugging, and receipt parsing uniform.
3. **No downside**: A one-element batch has negligible overhead vs. single mode (a few extra bytes of ABI encoding).
4. **The `batch` CLI command**: Already exists and uses mode `0x01`. Making `send` also use `0x01` keeps the encoding identical.

## Consequences

- All `execute()` calls use mode `0x01`, regardless of how many operations are in the batch.
- The CLI's `send` command and `batch` command share the same encoding logic.
- An agent modifying transaction construction MUST NOT switch to mode `0x00` for single calls. This would break if the contract implementation only validates one mode.
- Gas estimation is consistent across single and batch operations.

## References

- `keypo-wallet/src/transaction.rs` -- `execute` calldata construction
- `keypo-account/src/KeypoAccount.sol` -- `execute()` implementation
- ERC-7821 specification
