---
title: keypo-account (Solidity Smart Account)
owner: "@davidblumenfeld"
last_verified: 2026-03-20
status: current
---

# keypo-account

ERC-4337 v0.7 smart account with P-256 (Secure Enclave) signature verification, EIP-7702 delegation, and ERC-7821 batch execution. A single 68-line contract built on OpenZeppelin.

## Deployed Address

```
0x6d1566f9aAcf9c06969D7BF846FA090703A38E43
```

Deterministic via CREATE2 — identical address on every chain. See [deployments/](../deployments/) for per-chain records.

## How It Works

This is **not** a traditional proxy-based smart account. It's an EIP-7702 delegation target:

1. **Setup:** An EOA signs an EIP-7702 authorization delegating its code to KeypoAccount, then calls `initialize(qx, qy)` to register a P-256 public key as owner. Both happen atomically in a single transaction.

2. **Usage:** The ERC-4337 EntryPoint calls `validateUserOp()` on the EOA (which now runs KeypoAccount code). The contract verifies the UserOperation's P-256 signature against the stored public key. If valid, `execute()` runs the requested calls via ERC-7821 batch mode.

3. **Storage isolation:** Each delegating EOA gets its own storage slots. The shared implementation contract is never used directly (initialized with a placeholder key in the constructor).

## Standards

| Standard | Role |
|---|---|
| ERC-4337 v0.7 | UserOperation validation, EntryPoint integration |
| EIP-7702 | EOA code delegation (type-4 transactions) |
| ERC-7821 | Batch execution (`0x01` mode byte) |
| P-256 | Signature verification (Secure Enclave / passkeys) |

## Contract Interface

```solidity
// One-time setup — register P-256 public key as account owner
function initialize(bytes32 qx, bytes32 qy) external initializer

// ERC-4337 — validate UserOperation signatures
function validateUserOp(PackedUserOperation, bytes32, uint256) external returns (uint256)

// ERC-7821 — execute batch of calls (only EntryPoint or self can call)
function execute(bytes32 mode, bytes calldata executionData) external payable

// Returns the ERC-4337 v0.7 EntryPoint address
function entryPoint() public pure returns (IEntryPoint)
```

## Signature Validation

The contract accepts two signature formats in `_rawSignatureValidation`:

| Format | Length | Use Case |
|---|---|---|
| **Raw P-256** | 64 bytes (`r \|\| s`) | keypo-signer CLI (Secure Enclave) |
| **WebAuthn** | >64 bytes (ABI-encoded) | Browser passkeys |

**Low-S enforcement** is mandatory — signatures with `s > curve_order/2` are rejected to prevent malleability.

WebAuthn signatures are verified via OpenZeppelin's `WebAuthn.verify()`. User Verification (UV) is not required at the contract level — device-level policy (Touch ID / passcode) handles authentication before signing.

## Security Properties

- **Atomic initialization:** `initialize()` is protected by OpenZeppelin's `Initializable` — callable exactly once per EOA.
- **Implementation protection:** Constructor calls `_disableInitializers()` so the shared implementation can never be re-initialized.
- **Execution authorization:** Only the ERC-4337 EntryPoint or the account itself can call `execute()`.
- **No upgradeability:** The delegation target is fixed at setup time. Changing implementations requires a new EIP-7702 authorization.
- **Hardware-bound keys:** The P-256 private key lives in the Secure Enclave and never leaves the hardware. The contract only stores the public key.

## Project Structure

```
keypo-account/
├── src/
│   └── KeypoAccount.sol            # Smart account (68 lines)
├── test/
│   ├── KeypoAccount.t.sol          # Raw P-256 + WebAuthn signature tests (15 tests)
│   ├── KeypoAccount4337.t.sol      # ERC-4337 UserOp validation tests (11 tests)
│   ├── KeypoAccountSetup.t.sol     # EIP-7702 delegation tests (4 tests)
│   └── helpers/
│       └── P256Helper.sol          # Test keypairs, signature generation
├── script/
│   └── Deploy.s.sol                # CREATE2 deterministic deployment
└── foundry.toml                    # Solidity 0.8.28, EVM: Prague
```

## Tests

30 tests across 4 categories:

| Category | Tests | Coverage |
|---|---|---|
| Initialization | 4 | Public key setup, double-init revert, implementation protection |
| Signature validation | 8 | Raw P-256, WebAuthn, high-S rejection, wrong key, short sig |
| ERC-4337 integration | 5 | UserOp validation (raw + WebAuthn), invalid sigs, EntryPoint auth |
| ERC-7821 execution | 7 | Single call, batch, ETH transfer, ERC-20, empty batch, unauthorized caller |
| EIP-7702 delegation | 4 | Code prefix, init via delegation, storage isolation, uninitialized rejection |
| ERC-7821 authorization | 2 | Self-call allowed, EntryPoint authorized, random caller rejected |

```bash
forge test -vvv
```

## Deployment

Uses the Safe Singleton Factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) for deterministic CREATE2 deployment:

```bash
# Deploy (idempotent — skips if already deployed)
forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify

# Salt: keccak256("keypo-account-v0.1.0")
```

The script checks for existing code before deploying and verifies the code hash after deployment.

## Build

```bash
forge build
forge test -vvv
```

Requires Foundry 1.5.1+ and Solidity 0.8.28 (EVM target: Prague for EIP-7702 support in tests).

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — Account, SignerP256, ERC7821, Initializable, WebAuthn, P256
- [forge-std](https://github.com/foundry-rs/forge-std) — Test framework

## References

- [Architecture overview](../docs/architecture.md) — setup flow, transaction flow, full system diagram
- [Root README](../README.md) — full system overview
- [Root CLAUDE.md](../CLAUDE.md) — repo map and conventions
- [Full specification](../docs/archive/specs/keypo-account-spec.md)
