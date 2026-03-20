---
title: keypo-account (Solidity Smart Account)
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# keypo-account

ERC-4337 v0.7 smart account with P-256 (Secure Enclave) signing, EIP-7702 delegation, and ERC-7821 batch execution. Built with OpenZeppelin Contracts.

## Key Files

| File | Purpose |
|---|---|
| `src/KeypoAccount.sol` | Smart account implementation |
| `test/KeypoAccount.t.sol` | Forge tests (30 tests) |
| `script/Deploy.s.sol` | CREATE2 deployment script |
| `foundry.toml` | Foundry configuration |

## Build and Test

```bash
forge build
forge test -vvv
```

## Deployed Address

`0x6d1566f9aAcf9c06969D7BF846FA090703A38E43` (CREATE2, deterministic across chains).

See [deployments/](../deployments/) for per-chain deployment records.

## References

- [Architecture overview](../docs/architecture.md)
- [Full specification](../docs/archive/specs/keypo-account-spec.md)
- [Root CLAUDE.md](../CLAUDE.md)
