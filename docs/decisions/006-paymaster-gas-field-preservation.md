---
title: Paymaster Gas Field Preservation
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# ADR-006: Paymaster Gas Field Preservation

## Status

Accepted

## Context

The ERC-4337 UserOp submission flow with a paymaster involves two separate RPC calls:

1. **`pm_getPaymasterStubData`** -- returns stub paymaster fields for gas estimation. The bundler's `eth_estimateUserOperationGas` then returns gas limits including `paymasterVerificationGasLimit` and `paymasterPostOpGasLimit`.
2. **`pm_getPaymasterData`** -- returns the final signed paymaster fields. This response may or may not include updated gas limits.

The bug: `apply_paymaster_data()` was overwriting the gas fields from step 1 with the values from step 2. When `pm_getPaymasterData` omitted gas limits (returning `None`), the code set them to `None`, effectively zeroing them out. This caused **AA33 paymaster revert** on-chain because the EntryPoint expected non-zero gas limits.

## Decision

`apply_paymaster_data()` must **preserve existing gas fields** when the `pm_getPaymasterData` response omits them. Only overwrite if the response provides non-`None` values.

```rust
// In paymaster.rs -- apply_paymaster_data
if let Some(verification_gas) = pm_data.paymaster_verification_gas_limit {
    user_op.paymaster_verification_gas_limit = Some(verification_gas);
}
// Do NOT: user_op.paymaster_verification_gas_limit = pm_data.paymaster_verification_gas_limit;
// The above would overwrite with None if the response omits the field.
```

## Consequences

- Gas limits from the bundler's estimation are the default. The paymaster can override them if it returns values, but cannot zero them out by omission.
- This applies to both `paymasterVerificationGasLimit` and `paymasterPostOpGasLimit`.
- Without this fix, AA33 ("paymaster validation reverted") occurs on every paymaster-sponsored transaction.
- The fix is in `paymaster.rs` in the `apply_paymaster_data` function.

## References

- `keypo-wallet/src/paymaster.rs` -- `apply_paymaster_data` implementation
- ERC-4337 error AA33: "AA33 reverted (or OOG)" indicates paymaster validation failure
- ERC-7677: paymaster RPC specification
