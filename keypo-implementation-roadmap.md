# keypo-wallet Implementation Roadmap

**Version:** 0.3.0-draft
**Date:** 2026-03-01
**Author:** Dave / Keypo, Inc.

---

## Overview

This document defines the implementation plan for the keypo smart account system. The system lives in a **single monorepo called `keypo-wallet`** containing three projects:

1. **keypo-account** — Foundry project. Solidity smart account contract, tests, deployment scripts.
2. **keypo-wallet** — Rust crate + CLI. Client for account setup, P-256 signing via keypo-signer, ERC-4337 bundler interaction.
3. **keypo-signer-cli** — Swift CLI. Secure Enclave P-256 signing. Migrated from its standalone repo at [github.com/keypo-us/keypo-signer-cli](https://github.com/keypo-us/keypo-signer-cli).

The monorepo also contains:

- **`homebrew/`** — Homebrew tap formulae and release automation. Migrated from the standalone repo at [github.com/keypo-us/homebrew-tap](https://github.com/keypo-us/homebrew-tap).
- **`deployments/`** — Shared deployment records consumed by both keypo-account scripts and keypo-wallet.
- **`tests/integration/`** — Top-level integration tests that exercise the full stack (contract + wallet + signer).

### Monorepo Structure

```
keypo-wallet/                    # Monorepo root
├── keypo-account/               # Foundry project
│   ├── foundry.toml
│   ├── src/
│   ├── test/
│   └── script/
├── keypo-wallet/                # Rust crate + CLI
│   ├── Cargo.toml
│   ├── src/
│   └── tests/
├── keypo-signer-cli/            # Swift CLI (migrated from github.com/keypo-us/keypo-signer-cli)
│   ├── Package.swift
│   ├── Sources/
│   ├── Tests/
│   └── SPEC.md                  # Canonical CLI specification
├── homebrew/                    # Homebrew tap (migrated from github.com/keypo-us/homebrew-tap)
│   ├── Formula/
│   │   └── keypo-signer.rb
│   └── README.md
├── deployments/                 # Shared deployment records (per-chain JSON)
│   ├── base-sepolia.json
│   └── README.md
├── tests/                       # Top-level integration tests
│   ├── integration/
│   └── webauthn-frontend/       # Test-only WebAuthn frontend (localhost:3000)
│       ├── index.html           # Minimal page for WebAuthn ceremony
│       ├── package.json         # Dev dependencies (serve, playwright)
│       └── playwright.config.ts # Playwright test configuration
├── .env.example                 # Template for local secrets
├── .github/
│   └── workflows/
│       ├── foundry.yml          # Foundry CI (contract tests)
│       ├── rust.yml             # Rust CI (crate tests)
│       ├── swift.yml            # Swift CI (keypo-signer-cli build + test)
│       ├── release-signer.yml   # Build + release keypo-signer-cli binary
│       └── update-homebrew.yml  # Update homebrew formula on new signer release
└── README.md
```

### Design Principles

- **Maximum parallelism.** Tasks are organized so that as many workstreams as possible can proceed end-to-end (including testing and verification) independently. Dependencies between tasks are explicit.
- **Automated tests first, human tests last.** Every phase runs all automated test suites to completion before any manual/human verification begins. Manual smoke tests are consolidated at the end.
- **Assume all code is wrong.** Tests exist to prove code is correct, not to confirm it works. Test coverage must exercise failure modes, edge cases, and known-bad inputs — not just the happy path.

### Bundler and Paymaster Standards

- **Bundler: Pimlico via raw JSON-RPC.** No SDK. ZeroDev was evaluated and rejected due to Kernel coupling.
- **BundlerClient targets ERC-7769** — the standard JSON-RPC API (`eth_sendUserOperation`, `eth_estimateUserOperationGas`, `eth_getUserOperationReceipt`, `eth_getUserOperationByHash`, `eth_supportedEntryPoints`). This makes the client bundler-agnostic. Pimlico-specific extensions (like `pimlico_getUserOperationGasPrice`) are optional enhancements, not core dependencies.
- **Paymaster: ERC-7677** — the standard paymaster interface (`pm_getPaymasterStubData` + `pm_getPaymasterData`). A single implementation that takes a paymaster URL and an opaque context value (forwarded as-is) works across Pimlico, Coinbase, Alchemy, and any ERC-7677 compliant provider. No `PaymasterProvider` trait needed.

**Target chain for all initial work: Base Sepolia (84532).**

**Specs:**
- [keypo-account-spec.md](./keypo-account-spec.md) — Contract design, testing, deployment
- [keypo-wallet-spec.md](./keypo-wallet-spec.md) — Rust crate architecture, CLI, bundler integration

**External repos being migrated into this monorepo:**
- [keypo-signer-cli](https://github.com/keypo-us/keypo-signer-cli) — Swift CLI source, SPEC.md, GitHub Actions
- [homebrew-tap](https://github.com/keypo-us/homebrew-tap) — Homebrew formulae, release workflow

---

## Phase 0 — Preflight: Accounts, Secrets & Verification

**Goal:** Set up all accounts/secrets/API keys, configure the repo, migrate external repos, verify keypo-signer-cli works, and answer every open question that could change the architecture before writing code.

**Duration:** 1–2 days

**Workflow — Human Setup Then Claude Code Handoff:**

Phase 0 is **human-driven**. A human completes all steps in this phase: creates accounts, provisions API keys, stores secrets in `.env` and GitHub Actions, initializes the monorepo structure, migrates external repos, and runs the keypo-signer-cli verification steps. Once Phase 0 is complete and all exit criteria are met, the human starts a Claude Code session and provides:

1. The GitHub repo URL (e.g., `github.com/keypo-us/keypo-wallet`)
2. A reference to this roadmap and the spec documents
3. The current phase to begin (Phase 1 + Phase 2 in parallel)

From that point, Claude Code drives implementation through the remaining phases, working within the monorepo, running tests, and committing code. The human reviews PRs and performs manual testing steps at the end of each phase.

**The Claude Code kickstart prompt is defined in `keypo-claude-code-prompt.md`.**

### 0.1 Accounts & Secrets Setup

Before any code is written, provision all external accounts and store secrets in the appropriate locations.

| Account / Secret | Where to Store | Purpose |
|------------------|----------------|---------|
| Pimlico API key | `.env` (`PIMLICO_API_KEY`) + GitHub Actions secrets | Bundler + paymaster JSON-RPC access |
| Base Sepolia RPC URL | `.env` (`BASE_SEPOLIA_RPC_URL`) + GitHub Actions secrets | Chain interaction |
| Basescan API key | `.env` (`BASESCAN_API_KEY`) + GitHub Actions secrets | Contract verification |
| Deployer private key | `.env` (`DEPLOYER_PRIVATE_KEY`) — **never committed** | Contract deployment via `forge script` |
| Test funder private key | `.env` (`TEST_FUNDER_PRIVATE_KEY`) + GitHub Actions secrets | Pre-funded account for CI integration tests |
| Paymaster URL (Pimlico) | `.env` (`PAYMASTER_URL`) + GitHub Actions secrets | ERC-7677 paymaster endpoint |

**Actions:**
1. Create Pimlico account, generate API key, confirm Base Sepolia (84532) is enabled.
2. Set up `.env.example` with all variable names (no values). Add `.env` to `.gitignore`.
3. Add all secrets to GitHub Actions repository settings.
4. Fund a test account on Base Sepolia with faucet ETH for CI use.

### 0.2 Monorepo Initialization

1. Create the `keypo-wallet/` monorepo structure shown above.
2. **Migrate `keypo-signer-cli`** from [github.com/keypo-us/keypo-signer-cli](https://github.com/keypo-us/keypo-signer-cli) into the monorepo:
   - Copy the full source tree (`Sources/`, `Tests/`, `Package.swift`, `SPEC.md`, `CLAUDE.md`, `.claude/commands/`) into `keypo-wallet/keypo-signer-cli/`.
   - Migrate GitHub Actions workflows from `.github/workflows/` in the standalone repo into the monorepo's `.github/workflows/`, adjusting paths for the new directory structure. These include the Swift build/test CI workflow.
   - Preserve git history with `git subtree` or `git filter-repo` if practical.
3. **Migrate `homebrew-tap`** from [github.com/keypo-us/homebrew-tap](https://github.com/keypo-us/homebrew-tap) into the monorepo:
   - Copy `Formula/` directory and `README.md` into `keypo-wallet/homebrew/`.
   - Migrate the GitHub Actions workflow from `.github/workflows/` (the formula update automation) into the monorepo's `.github/workflows/update-homebrew.yml`.
   - Update the Homebrew formula to point to the monorepo for source releases.
   - **Note:** The `homebrew-tap` repo at [github.com/keypo-us/homebrew-tap](https://github.com/keypo-us/homebrew-tap) must remain active as a public Homebrew tap endpoint (`brew tap keypo-us/tap`). The monorepo's CI will push formula updates to the tap repo on new releases.
4. Initialize Foundry project in `keypo-account/`.
5. Initialize Rust project in `keypo-wallet/`.
6. Create `deployments/` directory with `README.md`.
7. Set up `.github/workflows/` with CI workflows:
   - `foundry.yml` — Foundry build + test
   - `rust.yml` — Rust build + test
   - `swift.yml` — Swift build + test (keypo-signer-cli)
   - `release-signer.yml` — Build universal binary, create GitHub release, compute SHA256
   - `update-homebrew.yml` — On new signer release, update formula in `homebrew-tap` repo

### 0.3 keypo-signer-cli Verification

Before any Rust client work begins, verify that keypo-signer-cli works correctly and that its output format is documented.

**Reference:** Review the [SPEC.md](https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md) in the keypo-signer-cli repo for the canonical specification of commands, flags, output formats, and key policies.

**Verification steps:**

1. Install keypo-signer-cli via Homebrew (`brew tap keypo-us/tap && brew install keypo-signer`) or build from source in the monorepo.
2. Create a test key with each supported policy:
   - `keypo-signer create --label test-open --policy open` (no biometric, no passcode)
   - `keypo-signer create --label test-passcode --policy passcode`
   - `keypo-signer create --label test-biometric --policy biometric` (Touch ID)
3. Run `keypo-signer info <label> --format json` for each key. Document exact JSON field names and encoding (especially `publicKey` format — expected: `0x04 || qx || qy`, 65 bytes hex-encoded).
4. Run `keypo-signer sign <hex-digest> --key <label> --format json` for each key. Document exact JSON field names (`r`, `s`) and encoding (expected: hex-encoded 32-byte big-endian, low-S normalized).
5. Confirm `keypo-signer list --format json` returns all keys with labels and policies.

**If `--format json` isn't implemented yet**, add it to keypo-signer-cli first. This is a prerequisite for Phase 3. Refer to the [SPEC.md](https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md) for the expected JSON schema.

**Deliverable:** A verified mapping of keypo-signer-cli commands → JSON output fields that the Rust crate's `KeypoSigner` wrapper will parse.

### 0.4 Chain Infrastructure Checks (VERIFIED)

All four blocking checks against Base Sepolia have been confirmed:

| Check | Status | Finding |
|-------|--------|---------|
| EIP-7702 on Base Sepolia | **VERIFIED** | Type-4 transactions are valid on Base Sepolia. |
| EntryPoint v0.7 on Base Sepolia | **VERIFIED** | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` is deployed. |
| Safe Singleton Factory on Base Sepolia | **VERIFIED** | `0x4e59b44847b379578588920cA78FbF26c0B4956C` is deployed. |
| RIP-7212 precompile on Base Sepolia | **VERIFIED** | Active. OZ's `SignerP256` will use the precompile path (~3,450 gas). |
| Bundler availability on Base Sepolia | **VERIFIED** | Pimlico supports chain 84532 with EntryPoint v0.7. |

**Base Sepolia is confirmed as the target chain. No fallback needed.**

### 0.5 Toolchain Checks

| Check | How | Blocking? |
|-------|-----|-----------|
| Foundry EIP-7702 support | Check if `forge test` with `evm_version = "prague"` supports `vm.signDelegation` cheatcode | **Yes** for Phase 1 contract testing |
| alloy 0.12 EIP-7702 API | `Authorization` struct + `sign_authorization` + `with_authorization_list` all present. Verify `sign_authorization` on `Signer` trait vs two-step fallback. | **Yes** for Phase 3 |
| alloy `PackedUserOperation` | Confirmed: matches v0.7. BundlerClient needs packed→unpacked serialization for RPC. | **Yes** for Phase 4 |

### 0.6 Exit Criteria

- All accounts provisioned and secrets stored in `.env` + GitHub Actions.
- Monorepo `keypo-wallet/` structure created; keypo-signer-cli and homebrew-tap migrated in.
- All GitHub Actions workflows ported and functional (Swift CI, release, Homebrew update).
- keypo-signer-cli verified: JSON output format documented for `info`, `sign`, `list`. All three key policies tested (open, passcode, biometric).
- Target chain confirmed: Base Sepolia (all checks VERIFIED).
- All toolchain blocking checks pass.
- No architecture changes needed — proceed to Phases 1 and 2.

---

## Phase 1 — Smart Account Contract (keypo-account) ✅ COMPLETE

**Goal:** Write, test, and deploy the `KeypoAccount` contract on Base Sepolia.

**Status:** Complete. 30/30 tests pass. Contract deployed and verified on Base Sepolia.

**Depends on:** Phase 0 (monorepo set up, secrets configured, target chain confirmed)

**Can run in parallel with:** Phase 2 (Rust crate scaffolding)

### 1.1 Project Setup ✅

- OZ Contracts v5.6.1 installed (Phase 0)
- forge-std v1.15.0 installed
- `foundry.toml` configured with `evm_version = "prague"`, `solc_version = "0.8.28"`, remappings for `@openzeppelin/contracts/` and `forge-std/`

### 1.2 Contract Implementation ✅

`src/KeypoAccount.sol` — ~65 lines including imports, ~30 lines of custom logic atop OZ building blocks.

**Inheritance:** `Account, SignerP256, ERC7821, Initializable`

**Dual-path signature validation:** The `_rawSignatureValidation` override routes by signature length:
- 64 bytes → raw P-256 via `SignerP256._rawSignatureValidation`
- \>64 bytes → WebAuthn via `WebAuthn.tryDecodeAuth` + `WebAuthn.verify(..., requireUV=false)`
- <64 bytes → rejected

**Implementation findings (deviations from spec):**

1. **`_rawSignatureValidation` override specifier:** Must be `override(AbstractSigner, SignerP256)` — NOT `override(Account, SignerP256)`. `Account` inherits `AbstractSigner` but doesn't directly define `_rawSignatureValidation`, so it's invalid in the override list.
2. **`SignerERC7702` removed entirely.** It only does secp256k1 ECDSA recovery — NOT nonce separation as spec claimed. P-256 is the sole signing key; no secp256k1 needed.
3. **EntryPoint v0.7** override via `ERC4337Utils.ENTRYPOINT_V07` (OZ defaults to v0.9).
4. **`_erc7821AuthorizedExecutor`:** Allows `entryPoint()` + `address(this)` (via super). EntryPoint calls `callData` directly on the account, so `msg.sender` is the EntryPoint address.
5. **WebAuthn `requireUV`:** Must use 5-param `WebAuthn.verify(..., false)` — the 4-param version defaults to `requireUV=true`.
6. **Constructor** uses P-256 generator point `(P256.GX, P256.GY)` as placeholder, with `_disableInitializers()`.

**Contract size:** 7,928 bytes runtime (well under 24KB limit).

### 1.3 P-256 Test Vector Setup ✅

`test/helpers/P256Helper.sol` — derives P-256 keypairs dynamically using `vm.signP256` + `P256.recovery` instead of hardcoded Wycheproof vectors. This is simpler and equally rigorous:

- Two keypairs derived from constant private keys
- Helper functions: `_signRaw`, `_signRawHighS`, `_invalidSignature`, `_signWebAuthn`, `_invalidWebAuthnSignature`
- WebAuthn helpers build valid `clientDataJSON` + `authenticatorData` and sign per the WebAuthn spec

**WebAuthn encoding finding:** Must use `abi.encode(r, s, challengeIndex, typeIndex, authenticatorData, clientDataJSON)` as a flat tuple — NOT `abi.encode(struct)`, which adds an outer offset pointer that `tryDecodeAuth` doesn't expect.

**WebAuthn `challengeIndex`:** Must point to the opening `"` of `"challenge":"..."` in `clientDataJSON` (index 23 for the standard format), not to `c` (index 24).

### 1.4 Automated Tests ✅ — 30/30 Pass

#### 1.4.1 Unit Tests (`KeypoAccount.t.sol`) — 15 tests ✅

| # | Test | Validates |
|---|------|-----------|
| 1 | `test_initialize_setsPublicKey` | `signer()` returns correct (qx, qy) |
| 2 | `test_initialize_revertsOnSecondCall` | Reverts with `InvalidInitialization()` |
| 3 | `test_implementationCannotBeReinitialized` | Fresh deploy → `initialize()` reverts |
| 4 | `test_uninitializedAccount_rejectsSignature` | Generator-point key rejects valid sig |
| 5 | `test_rawSigValidation_rawP256_valid` | Valid 64-byte sig → true |
| 6 | `test_rawSigValidation_rawP256_invalid` | Corrupted sig → false |
| 7 | `test_rawSigValidation_rawP256_highS` | s > N/2 → false |
| 8 | `test_rawSigValidation_rawP256_wrongKey` | Valid sig, wrong key → false |
| 9 | `test_rawSigValidation_webauthn_valid` | Valid WebAuthn sig → true |
| 10 | `test_rawSigValidation_webauthn_invalid` | Bad WebAuthn sig → false |
| 11 | `test_rawSigValidation_webauthn_wrongKey` | WebAuthn sig, wrong key → false |
| 12 | `test_rawSigValidation_tooShort` | < 64 bytes → false |
| 13 | `test_erc7821AuthorizedExecutor_self` | `address(account)` → true |
| 14 | `test_erc7821AuthorizedExecutor_entryPoint` | EntryPoint v0.7 → true |
| 15 | `test_erc7821AuthorizedExecutor_other` | Random address → false |

Uses `KeypoAccountHarness` to expose internal functions. Resets Initializable storage via `vm.store` to enable `initialize()`.

#### 1.4.2 EIP-7702 Integration Tests (`KeypoAccountSetup.t.sol`) — 4 tests ✅

| # | Test | Validates |
|---|------|-----------|
| 1 | `test_delegation_codePrefix` | EOA code starts with `0xef0100` + impl address |
| 2 | `test_delegation_initialize` | EOA can call `initialize()` after delegation |
| 3 | `test_delegation_storageIsolation` | Two EOAs have independent (qx, qy) |
| 4 | `test_delegation_uninitializedRejectsSignature` | Delegated but uninitialized EOA (signer = 0,0) rejects sigs |

Uses `vm.signAndAttachDelegation`. Foundry's local EVM fully supports EIP-7702 — no fork testing needed.

#### 1.4.3 ERC-4337 Integration Tests (`KeypoAccount4337.t.sol`) — 11 tests ✅

| # | Test | Validates |
|---|------|-----------|
| 1 | `test_validateUserOp_rawP256_valid` | Valid sig → `SIG_VALIDATION_SUCCESS` (0) |
| 2 | `test_validateUserOp_rawP256_invalid` | Bad sig → `SIG_VALIDATION_FAILED` (1) |
| 3 | `test_validateUserOp_webauthn_valid` | WebAuthn sig → success |
| 4 | `test_validateUserOp_webauthn_invalid` | Bad WebAuthn → failure |
| 5 | `test_validateUserOp_notFromEntryPoint` | Call without prank → reverts |
| 6 | `test_execute_singleCall` | 1-element batch succeeds |
| 7 | `test_execute_batchCalls` | Multi-call batch succeeds |
| 8 | `test_execute_ethTransfer` | ETH transfer via batch |
| 9 | `test_execute_erc20Transfer` | ERC-20 transfer (MockERC20) |
| 10 | `test_execute_emptyBatch` | Empty batch succeeds (no-op) |
| 11 | `test_execute_unauthorizedCaller` | Random addr → reverts |

Uses `vm.prank(ENTRYPOINT_V07)` instead of a mock EntryPoint. ERC-7821 batch mode `0x01` with `Execution[]` from `draft-IERC7579.sol`.

#### 1.4.4 WebAuthn End-to-End Tests (Playwright)

**Deferred.** WebAuthn signature validation is fully covered by the Foundry unit tests (tests 9–11 in §1.4.1 and tests 3–4 in §1.4.3), which construct valid WebAuthn assertions programmatically. The Playwright-based virtual authenticator tests remain available as an optional future enhancement but are not blocking.

### 1.5 Deployment to Testnet ✅

- `script/Deploy.s.sol` — CREATE2 via Safe Singleton Factory (`0x4e59...956C`), salt `keccak256("keypo-account-v0.1.0")`, idempotent
- `script/Verify.s.sol` — checks code existence, entryPoint v0.7, batch mode support
- **Deployed** to Base Sepolia at block 38360751
- **Verified** on Basescan
- `deployments/base-sepolia.json` written with full deployment record
- ABI exported to `keypo-wallet/abi/KeypoAccount.json`

**Deployment details:**

| Field | Value |
|-------|-------|
| Address | `0x6d1566f9aAcf9c06969D7BF846FA090703A38E43` |
| Tx Hash | `0x7ba79964f2399c39f141d0862fe1ebaeaefc2ff283114de20a5d0afb08cbd032` |
| Block | 38360751 |
| Runtime Code Hash | `0x7af79db7b41ae7199b9cf778c17193fa6222350724bba13d55db9acb3b0e2816` |
| Basescan | [View on Basescan](https://sepolia.basescan.org/address/0x6d1566f9aacf9c06969d7bf846fa090703a38e43) |

**RPC note:** `BASE_SEPOLIA_RPC_URL` in `.env` is a Pimlico bundler URL (limited to ERC-4337 methods). Use `https://sepolia.base.org` for standard RPC calls (deployment, verification, `cast` commands).

### 1.6 Manual Smoke Test (Human Testing — Only After All Automated Tests Pass)

Manually verify the contract works end-to-end using `cast`:

1. Generate a secp256k1 keypair with `cast wallet new`
2. Fund it from faucet
3. Send an EIP-7702 delegation tx: `cast send --auth 0x6d1566f9aAcf9c06969D7BF846FA090703A38E43 ...`
4. Call `initialize(qx, qy)` on the delegated EOA
5. Verify the P-256 key is stored: read the storage slots

This confirms the on-chain side works before adding Rust client complexity.

**Milestone: Contract deployed and verified on Base Sepolia. All 30 automated tests pass. Manual smoke test pending.**

---

## Phase 2 — Rust Crate Scaffolding (keypo-wallet) ✅ COMPLETE

**Goal:** Set up the Rust project structure with all types, traits, and the `KeypoSigner` subprocess wrapper. No chain interaction yet.

**Status:** Complete. 51 tests pass (41 lib + 7 bin + 3 integration). All modules implemented. CLI parses all arguments.

**Depends on:** Phase 0 (keypo-signer-cli JSON format confirmed and verified, monorepo set up).

**Runs in parallel with:** Phase 1 (contract work). No dependency on the deployed contract.

### 2.1 Project Setup ✅

- `Cargo.toml` updated with `test-utils` feature (enables `MockSigner` via optional `p256` dep), `tempfile` dev-dep, self dev-dep with `test-utils` feature for integration tests
- Module structure: `error`, `types`, `traits`, `impls`, `signer`, `state`, `paymaster`

### 2.2 Core Types and Errors ✅

- `error.rs` — `Error` enum with 12 variants via `thiserror`, `Result<T>` type alias (expanded to 17 variants in Phase 3: added `FundingTimeout`, `ImplementationNotDeployed`, `DelegationFailed`, `TransactionFailed`, `MultiChainNotSupported`)
- `types.rs` — 7 domain types: `P256PublicKey`, `P256Signature`, `Call`, `KeyInfo`, `ChainDeployment`, `AccountRecord`, `ChainConfig`
- `KeyInfo` includes `label()` convenience method to strip `com.keypo.signer.` prefix
- 8 unit tests (serde roundtrips, B256 hex format, KeyInfo deserialization from JSON-FORMAT.md)

### 2.3 `AccountImplementation` Trait ✅

- `traits.rs` — 8-method trait with default `encode_webauthn_signature` returning `None`

### 2.4 `KeypoAccountImpl` ✅

- `impls/keypo_account.rs` — ABI encoding via alloy `sol!` macro matching the deployed contract
- `from_deployments_dir(path)` reads `deployments/*.json` files (parses `chainId` + `address`)
- ERC-7821 batch mode `0x01` in byte[0] (matches `KeypoAccount4337.t.sol`)
- WebAuthn encoding uses `abi_encode_params()` (NOT `abi_encode()`) — flat tuple matching `P256Helper.sol:122`
- 14 unit tests including roundtrips, known vectors, deployment dir loading, and error propagation

**Implementation finding:** `alloy-sol-types` 1.5.7 `abi_decode()` takes 1 argument (no `validate: bool` parameter). This differs from earlier alloy versions referenced in some documentation.

### 2.5 `KeypoSigner` Wrapper ✅

- `signer.rs` — `P256Signer` trait (named to avoid collision with `alloy::signers::Signer`)
- `KeypoSigner` subprocess wrapper with `run_command` helper, parses JSON output per `JSON-FORMAT.md`
- `parse_public_key` — validates `0x04` prefix, splits 128 hex chars into qx/qy
- `MockSigner` — gated on `#[cfg(any(test, feature = "test-utils"))]`, uses `p256` crate with low-S normalization
- `MockSigner` supports `add_key`, `add_deterministic_key` (same seed → same key), implements full `P256Signer` trait
- 6 unit tests (public key parsing valid/invalid, sign response parsing, mock signer create+sign, deterministic keys)

### 2.6 `StateStore` ✅

- `state.rs` — JSON-backed persistence at `~/.keypo/accounts.json`
- `open()` creates dir (mode 0o700) and file on first use; corrupt files return `Error::StateFormat`
- `add_chain_deployment` creates or appends; rejects duplicate chain_id with `Error::DuplicateDeployment`
- Atomic save via write-to-tmp + `fs::rename`
- 9 unit tests (create from scratch, reopen, corrupt file, CRUD, duplicate rejection, save/reload roundtrip)

### 2.7 ERC-7677 Paymaster Client ✅

- `paymaster.rs` — types only (no HTTP calls — deferred to Phase 4)
- `PaymasterClient` with `build_stub_request` / `build_data_request` builders
- `PaymasterUserOp` — unpacked v0.7 UserOp with `#[serde(rename_all = "camelCase")]`
- chain_id encoded as hex string per ERC-7677 (e.g., 84532 → `"0x14a34"`)
- 4 unit tests (request serialization, response deserialization, chain_id hex format)

### 2.8 CLI Argument Parsing ✅

- `src/bin/main.rs` — clap derive with 5 subcommands: `Setup`, `Send`, `Batch`, `Info`, `Balance`
- All args match spec §5.1 including defaults (`--key-policy biometric`, `--impl-name KeypoAccount`)
- All handlers print `"<command>: not implemented"`
- 7 unit tests (all-args parsing for each subcommand, defaults, missing required `--key`)

### 2.9 Automated Tests ✅ — 51/51 Pass

```
41 lib tests + 7 bin tests + 3 integration tests = 51 total
```

Integration tests (`tests/integration_scaffolding.rs`):
1. `KeypoAccountImpl` encode/decode roundtrip (initialize + execute with 2-call batch)
2. `StateStore` full lifecycle (open, add 2 chains, save, reload, verify)
3. `MockSigner` create → get_public_key → sign → encode_signature via `KeypoAccountImpl` → verify 64 bytes

**Milestone: `cargo build` succeeds with no warnings. `cargo test` passes all 51 tests. CLI parses all arguments and prints stub output.**

---

## Phase 1.5 — Fast-Track Contract Deployment (Shortcut) ✅ SUPERSEDED

**Status:** Superseded. Phase 1 completed the full deployment (CREATE2, Basescan verification, 30/30 tests) in a single pass, so the fast-track shortcut was not needed. The contract is deployed at `0x6d1566f9aAcf9c06969D7BF846FA090703A38E43` — Phase 2/3/4 can proceed immediately.

---

## Phase 3 — Account Setup Flow (keypo-wallet) ✅ COMPLETE

**Goal:** Implement the `setup` command end-to-end: key creation/selection with policy choice, ephemeral EOA generation, funding wait, EIP-7702 delegation, initialization, key erasure.

**Status:** Complete. 67 tests pass (53 lib + 7 bin + 3 scaffolding + 4 setup integration). Full setup flow verified on Base Sepolia with MockSigner + programmatic funding.

**Depends on:** Phase 1 (contract deployed on testnet), Phase 2 (crate scaffolding complete)

### 3.1 alloy Provider Integration ✅

Set up the alloy HTTP provider with the target chain's RPC endpoint. All basic operations confirmed working:

- `provider.get_chain_id()`
- `provider.get_balance(address)`
- `provider.get_code_at(address)`
- `provider.get_transaction_count(address)`

**Implementation findings (deviations from spec/plan):**

1. **`ProviderBuilder::new().on_http(url)` renamed to `connect_http(url)`** in alloy 1.7.3. The older `on_http` method does not exist.
2. **`with_to()` requires explicit import** of `use alloy::network::TransactionBuilder` — it's on the `TransactionBuilder` trait, not directly on `TransactionRequest`.
3. **`connect_http()` returns a concrete type** (not generic), which resolves type inference issues that would occur with the older `on_http` pattern.

### 3.2 EIP-7702 Authorization Construction ✅

Implemented using the two-step manual construction approach (not `sign_authorization` on `Signer` trait):

- `PrivateKeySigner::random()` for ephemeral key generation
- `Authorization { chain_id: U256::from(id), address, nonce }` struct construction
- `eoa_signer.sign_hash_sync(&auth.signature_hash())` for signing
- `auth.into_signed(sig)` to produce `SignedAuthorization`
- `TransactionRequest::default().with_authorization_list(vec![signed_auth])` for the type-4 tx

**Critical implementation finding — EIP-7702 authorization nonce:**

Per the EIP-7702 spec, the sender's transaction nonce is incremented **BEFORE** the authorization list is processed. When sender == authority (our case — the ephemeral EOA both sends and authorizes), the authorization nonce must be `current_nonce + 1`, not `current_nonce`. For a fresh EOA (nonce 0), the auth nonce must be 1.

This was confirmed empirically on Base Sepolia: auth_nonce=0 resulted in the delegation being silently ignored (empty code), while auth_nonce=1 succeeded.

**Additional finding — `alloy-eip7702` `k256` feature:**

The `recover_authority()` method on `SignedAuthorization` requires the `k256` feature on `alloy-eip7702`, which is not enabled by default. Unit tests use `r()`/`s()` non-zero checks instead of authority recovery.

**Security note for ephemeral key generation:** `PrivateKeySigner::random()` uses `k256::SigningKey::random()` → `OsRng` → `SecRandomCopyBytes` on macOS. Best practice for cryptographic key generation.

### 3.3 Full Setup Flow ✅

The `account::setup()` function implements the complete 17-step flow:

1. `get_or_create_key()` — get/create P-256 key via signer
2. Build read-only provider (`ProviderBuilder::new().connect_http(url)`)
3. `verify_implementation()` — check contract code exists on-chain
4. Resolve chain_id (from config or auto-detect via `provider.get_chain_id()`)
5. Guard: duplicate deployment (same key + same chain) → `DuplicateDeployment` error
6. Guard: multi-chain (key already has account on any chain) → `MultiChainNotSupported` error
7. `PrivateKeySigner::random()` — generate ephemeral EOA
8. `wait_for_funding()` — dispatches on `FundingStrategy`
9. Get auth nonce (`get_transaction_count() + 1`)
10. `build_signed_authorization()` — sign EIP-7702 auth with ephemeral secp256k1 key
11. `encode_initialize(qx, qy)` — build init calldata
12. Build signing provider with `EthereumWallet::from(ephemeral_signer)`
12a. **Confirm funding visibility** on signing provider (retry up to 10x, 2s delay)
13. `send_setup_transaction()` — type-4 tx with manual 500k gas limit
14. `verify_delegation()` — confirm `0xef0100 || impl_address` (retry up to 5x, 2s delay)
15. `drop(signing_provider)` — release `Arc<PrivateKeySigner>`, trigger zeroize
16. Persist `ChainDeployment` to `StateStore`
17. Return `SetupResult`

**Implementation findings — RPC stale data:**

Public RPCs (like `sepolia.base.org`) use load balancers that route requests to different nodes. After a transaction is confirmed on one connection, a different connection may return stale data. Two retry mechanisms were added:

- **Balance confirmation (step 12a):** After programmatic funding, the signing provider's connection may not see the balance yet. Retries up to 10 times with 2-second delays before sending the setup tx. Without this, `send_transaction` fails with "insufficient funds for gas" even though funding was confirmed on the read-only provider.
- **Delegation verification (step 14):** After the setup tx is confirmed, `get_code_at` may return empty code. Retries up to 5 times with 2-second delays. Empirically, the delegation is consistently visible by the 2nd attempt (~2 seconds after tx confirmation).

**Implementation finding — gas estimation for type-4 txs:**

Auto gas estimation for EIP-7702 type-4 transactions underestimates because estimation runs against the EOA's current code (empty), not the post-delegation code. The setup tx uses a manual gas limit of 500,000. Actual gas usage is ~103,000, so 500k provides ample margin.

### 3.4 Wire CLI `setup` Command ✅

Connected the CLI's `setup` subcommand to `account::setup()`:

- `main()` converted to `#[tokio::main] async fn main()` with `tracing_subscriber::fmt().try_init().ok()` for progress output
- `run_setup()` handles argument validation, deployment lookup, funding strategy selection
- Deployment resolution: `from_deployments_dir()` uses `CARGO_MANIFEST_DIR/../deployments/` for `cargo run`, falls back to empty `KeypoAccountImpl::new()` for installed binaries (requires `--implementation` flag)
- Auto-detect chain_id from RPC if neither `--chain-id` nor `--implementation` is provided
- Funding strategy: auto-detects `TEST_FUNDER_PRIVATE_KEY` env var → `FundFrom`, else `WaitForFunding` (5s poll, 300s max)
- Prints result: address, tx hash, chain_id

### 3.5 Mock Signer Test Account for CI ✅

Integration tests use `MockSigner` with `FundFrom` strategy against live Base Sepolia. Each test creates a fresh ephemeral EOA, funds it programmatically, and runs the full setup flow. The `test_setup_with_deterministic_key` test validates that a deterministic P-256 key (from a fixed seed) produces the expected public key in the setup result.

**CI funding pattern:** All automated tests use `TEST_FUNDER_PRIVATE_KEY` to transfer 0.001 ETH to ephemeral addresses. Tests must run with `--test-threads=1` to avoid nonce conflicts on the shared funder wallet.

### 3.6 Automated Tests ✅ — 67/67 Pass

```
53 lib tests + 7 bin tests + 3 scaffolding integration + 4 setup integration = 67 total
```

#### Unit Tests (`account.rs #[cfg(test)]`) — 12 tests ✅

| # | Test | Validates |
|---|------|-----------|
| 1 | `get_or_create_key_existing` | Returns existing key from MockSigner |
| 2 | `get_or_create_key_new` | Creates key when label not found |
| 3 | `build_signed_authorization_fields` | Correct chain_id, address, nonce in auth |
| 4 | `build_signed_authorization_has_signature` | Non-zero r, s values |
| 5 | `verify_delegation_valid` | `0xef0100` + correct address passes |
| 6 | `verify_delegation_empty` | Empty code → `DelegationFailed` |
| 7 | `verify_delegation_wrong_addr` | Wrong implementation address → `DelegationFailed` |
| 8 | `verify_delegation_short_code` | Code < 23 bytes → `DelegationFailed` |
| 9 | `parse_rpc_url_valid_and_invalid` | Valid URL parses, invalid → `Error::Other` |
| 10 | `duplicate_deployment_rejected` | State guard detects existing key+chain |
| 11 | `funding_timeout_returns_error` | `poll_balance` with always-zero checker → `FundingTimeout` |
| 12 | `transaction_reverted_returns_error` | `TransactionFailed` error construction |

#### Integration Tests (`tests/integration_setup.rs`, `#[ignore]`) — 4 tests ✅

| # | Test | Validates |
|---|------|-----------|
| 1 | `test_setup_full_flow` | Full setup on Base Sepolia: fund → delegate → init → verify delegation + state |
| 2 | `test_setup_duplicate_fails` | Second setup same (key, chain) → error |
| 3 | `test_setup_bad_implementation` | Nonexistent address → `ImplementationNotDeployed` |
| 4 | `test_setup_with_deterministic_key` | Deterministic MockSigner key → correct public key in result |

Run integration tests with:
```bash
# Load .env, run serially (shared funder wallet)
set -a && source .env && set +a && \
cargo test --test integration_setup -- --ignored --test-threads=1
```

### 3.7 Manual End-to-End Test (Human Testing — Last) ✅

Ran the full setup flow against Base Sepolia with the real `KeypoSigner` (Secure Enclave `test-open` key, policy `open`):

```bash
keypo-wallet setup \
    --key test-open \
    --key-policy open \
    --rpc https://sepolia.base.org
```

Used `TEST_FUNDER_PRIVATE_KEY` for auto-funding. All checks confirmed:

- **Transaction succeeded:** Setup tx `0x5bb3d6fd48d7dc1f24283ceb29abe5479e502cbd8067542556278c94de2bddfb`
- **Delegation code:** `cast code 0xC66025eaa0aaA2d2619F70423d8c0246625EBc13` → `0xef01006d1566f9aacf9c06969d7bf846fa090703a38e43`
- **P-256 key stored:** `cast call 0xC66025eaa0aaA2d2619F70423d8c0246625EBc13 "signer()(bytes32,bytes32)"` → matches `test-open` key coordinates (`qx=0xc8ecfc...de5e`, `qy=0x5c7ebd...785a`)
- **State persisted:** `~/.keypo/accounts.json` written with correct address, key label, public key, and chain deployment record

**Account address:** `0xC66025eaa0aaA2d2619F70423d8c0246625EBc13` (Base Sepolia, controlled by Secure Enclave `test-open` key)

**Milestone: `keypo-wallet setup` creates a working smart account on testnet, controlled by a Secure Enclave P-256 key. All 67 automated tests pass. 4 integration tests verified on live Base Sepolia. Manual end-to-end test confirmed with real `KeypoSigner`.**

---

## Phase 4 — Bundler Integration (keypo-wallet)

**Goal:** Implement the `BundlerClient` (ERC-7769) and `UserOperation` construction. Be able to estimate gas and submit operations, but not yet sign them with keypo-signer (use the mock signer for testing).

**Duration:** 3–5 days

**Depends on:** Phase 3 (a deployed smart account exists on testnet to test against, including a mock-signer test account)

### 4.1 BundlerClient (ERC-7769)

Implement `bundler.rs` targeting the **ERC-7769 standard JSON-RPC API**:

- `eth_supportedEntryPoints` — first call, confirms connectivity
- `eth_estimateUserOperationGas` — requires a valid UserOp skeleton
- `eth_sendUserOperation` — submit signed UserOp
- `eth_getUserOperationReceipt` — poll for inclusion
- `eth_getUserOperationByHash` — lookup by hash
- `wait_for_receipt` — exponential backoff wrapper

**Raw JSON-RPC only.** No Pimlico SDK, no bundler-specific abstractions. The BundlerClient speaks the ERC-7769 standard, making it bundler-agnostic.

**Optional Pimlico extensions** (not in core path):
- `pimlico_getUserOperationGasPrice` — convenience for gas pricing

Test against Pimlico on Base Sepolia. Start with `eth_supportedEntryPoints` to confirm the bundler is reachable and returns the v0.7 EntryPoint.

### 4.2 UserOperation Construction

Implement `transaction.rs`:

- `PackedUserOperation` struct — CONFIRMED: matches v0.7. BundlerClient needs packed→unpacked serialization for RPC.
- `compute_user_op_hash` — the digest that gets signed
- `pack_without_signature` — serialization for hashing
- Gas field packing (`account_gas_limits`, `gas_fees` are packed `bytes32` values in v0.7)
- ERC-4337 nonce querying (call EntryPoint's `getNonce(address, uint192 key)` on-chain)

### 4.3 Gas Estimation Flow

Build the gas estimation round-trip:

1. Construct UserOp with dummy signature (from `AccountImplementation::dummy_signature()`)
2. Call `eth_estimateUserOperationGas` on the bundler (ERC-7769)
3. Parse the gas estimate
4. Apply gas values to the UserOp
5. Set `maxFeePerGas` and `maxPriorityFeePerGas` (from bundler suggestion or provider's `eth_gasPrice` + margin)

### 4.4 ERC-7677 Paymaster Integration

Wire the ERC-7677 paymaster client (built in Phase 2.7) into the UserOp construction flow:

1. Before gas estimation: call `pm_getPaymasterStubData` to get stub paymaster data
2. Include stub data in the UserOp for gas estimation
3. After gas estimation: call `pm_getPaymasterData` with the gas-estimated UserOp
4. Replace stub data with real paymaster data before signing

### 4.5 Automated Tests

- Unit tests for JSON-RPC serialization/deserialization (request and response formats)
- Unit tests for `compute_user_op_hash` against known test vectors
- Unit tests for packed→unpacked UserOp serialization
- Unit tests for ERC-7677 stub/real paymaster data flow
- Integration test: MockSigner-signed UserOp submission against testnet bundler

```bash
cargo test
```

**Gate: All automated tests pass before mock-signed submission test.**

### 4.6 Mock-Signed Submission Test (Automated, Not Human)

Using the **mock-signer test account created in Phase 3.5** (an account initialized with the MockSigner's P-256 public key instead of a Secure Enclave key), run the full submission flow against testnet:

1. Build a simple ETH transfer UserOp for the mock-signer test account
2. Estimate gas
3. Compute `userOpHash`
4. Sign with `MockSigner`
5. Submit to bundler
6. Wait for receipt

Because the mock signer's P-256 public key was registered during the test account's setup, the mock-signed UserOp **will pass on-chain validation**. This gives a true end-to-end automated test without needing Secure Enclave access in CI.

**Milestone: UserOps are correctly constructed, gas-estimated, and submitted to a real bundler. Mock-signed operations pass on-chain validation end-to-end. ERC-7677 paymaster flow works. All automated tests pass.**

---

## Phase 5 — Transaction Signing + CLI (keypo-wallet)

**Goal:** Wire keypo-signer signing into the transaction flow. Implement `send`, `batch`, and `balance` commands. Achieve the first real transaction: a P-256-signed, bundler-submitted, on-chain-verified operation from a Secure Enclave key.

**Duration:** 2–3 days

**Depends on:** Phase 4 (bundler integration working)

### 5.1 Live Signing Integration

Replace the mock signer in the transaction flow with the real `KeypoSigner`:

1. Build UserOp → estimate gas → compute `userOpHash`
2. Call `keypo-signer sign <userOpHash> --key <label> --format json`
3. Touch ID / passcode prompt appears (depending on key policy)
4. Parse (r, s) from JSON response
5. Encode signature via `AccountImplementation::encode_signature`
6. Submit to bundler

### 5.2 `send` Command

Wire the CLI's `send` subcommand:

- Look up `AccountRecord` from state store by `(key_label, chain_id)`
- Build a single `Call` from `--to`, `--value`, `--data`
- Call `transaction::execute`
- Print progress: building, signing (Touch ID), submitted, confirmed

### 5.3 `batch` Command

Wire the CLI's `batch` subcommand:

- Parse `--calls` JSON file into `Vec<Call>`
- Call `transaction::execute` with the full batch
- Same progress output

### 5.4 `info` and `balance` Commands

Wire the remaining read-only commands:

- `info` — read from state store, display all chain deployments for the key
- `balance` — query all tokens across all chains where the account is deployed, with GraphQL-style filtering

The `balance` command should:
- Default to showing all tokens on all chains the account is deployed on
- Support `--chain <ID>` to filter to a specific chain
- Support `--token <SYMBOL_OR_ADDRESS>` to filter to a specific token
- Support `--query <FILE>` to run a structured query from a JSON file that defines the filtering interface (tokens, chains, minimum balance thresholds, etc.)

The query file interface is defined in keypo-wallet spec §5.3.

### 5.5 Automated Tests

- Unit tests for CLI argument parsing → command dispatch
- Unit tests for `send` and `batch` call encoding
- Unit tests for `balance` query parsing and filtering
- Integration tests with MockSigner (reuse Phase 4 infrastructure)

```bash
cargo test
```

**Gate: All automated tests pass before manual end-to-end test.**

### 5.6 Manual End-to-End Test (Human Testing — Last)

The full flow on testnet with real Secure Enclave signing:

```bash
# Send testnet ETH
keypo-wallet send --key testnet-key --to 0x<faucet-or-self> --value 0.0001

# Batch: send ETH to two addresses
keypo-wallet batch --key testnet-key --calls test-batch.json

# Check balance — all tokens, all chains
keypo-wallet balance --key testnet-key

# Check balance — specific chain
keypo-wallet balance --key testnet-key --chain 84532

# Check balance — structured query
keypo-wallet balance --key testnet-key --query balance-query.json
```

**Milestone: First real P-256-signed transaction confirmed on-chain via ERC-4337 bundler. The full pipeline works: Secure Enclave → keypo-signer → keypo-wallet → bundler → EntryPoint → smart account → execution.**

---

## Phase 6 — Hardening + CI (keypo-wallet)

**Goal:** Improve error handling, add CI integration tests, and polish for initial release. Paymaster already integrated in Phase 4.

**Duration:** 3–5 days

**Depends on:** Phase 5 (core flow working)

### 6.1 Gas-Sponsored Transaction Test

- Test a gas-sponsored transaction using ERC-7677 paymaster (Pimlico on Base Sepolia)
- The smart account doesn't need ETH for gas — confirm this works end-to-end
- Wire `--paymaster <URL>` through the CLI

### 6.2 Error Handling Polish

- Improve error messages for common failure modes:
  - `keypo-signer` not found on PATH
  - Key label doesn't exist
  - Insufficient funding during setup
  - Bundler rejects UserOp (decode revert reason)
  - Gas estimation too low (auto-retry with buffer?)
  - Receipt timeout
  - ERC-7677 paymaster errors (stub data vs real data failures)
- Add `--verbose` / `-v` flag for tracing output
- Structured error output with suggestions ("did you mean...?", "try funding your account first")

### 6.3 CI Integration Tests

- Set up GitHub Actions workflow for Foundry, Rust, and Swift
- Use `MockSigner` + the mock-signer test account on Base Sepolia (created in Phase 3.5)
- Use secrets from Phase 0.1 (Pimlico API key, RPC URL, test funder key)
- **Ephemeral EOA funding in CI:** All integration tests that require funded accounts use `TEST_FUNDER_PRIVATE_KEY` to programmatically transfer testnet ETH during test setup. No faucet polling, no human interaction. The faucet path is only exercised during manual testing (Phase 6.5).
- Automated tests (no human intervention):
  - Foundry: `forge test` (unit + integration)
  - Rust: `cargo test` (unit + integration)
  - Swift: `swift test` (keypo-signer-cli)
  - Setup flow with mock signer against fork or live testnet (funded via test funder wallet)
  - UserOp construction, submission, and on-chain validation (mock signer test account)
  - ERC-7677 paymaster flow
  - State store persistence (multi-chain records)
  - CLI argument parsing and validation
  - Balance query parsing

### 6.4 Documentation

- README with quickstart
- `--help` text for all commands
- Architecture diagram
- Example scripts / tutorials
- Balance query file format documentation

### 6.5 Manual Testing (Human Testing — Consolidated at End)

After all automated CI tests pass:

1. Full end-to-end setup + send + batch on Base Sepolia with Secure Enclave
2. Gas-sponsored transaction via paymaster
3. Error recovery scenarios (insufficient funds, wrong key label, network timeout)
4. Balance queries across multiple chains (if deployed on more than one)

**Milestone: Gas-sponsored transactions work. CI passes. README and docs written. Ready for internal use and mainnet deployment planning.**

---

## Summary Timeline

| Phase | Duration | Parallel? | Deliverable | Exit Criteria |
|-------|----------|-----------|-------------|---------------|
| **0 — Preflight** | 1–2 days | — | Accounts, secrets, monorepo, migrated repos, signer verified | ✅ Complete |
| **1 — Contract** | 3–5 days | ↕ Phase 2 | Deployed + verified `KeypoAccount` on testnet | ✅ Complete — 30/30 tests, deployed at `0x6d15...8E43` |
| **1.5 — Fast Deploy** | 0.5–1 day | ↕ Phase 1 tests | Minimal deployment for Rust work to begin | ✅ Superseded — full Phase 1 completed |
| **2 — Crate Scaffold** | 2–3 days | ↕ Phase 1 | Rust crate with types, traits, signer, state, ERC-7677 | ✅ Complete — 51/51 tests, all modules implemented |
| **3 — Setup Flow** | 3–5 days | — | `keypo-wallet setup` working on testnet + mock signer test account | ✅ Complete — 67/67 tests, EIP-7702 delegation verified on Base Sepolia |
| **4 — Bundler** | 3–5 days | — | ERC-7769 BundlerClient + ERC-7677 paymaster + UserOp | Automated tests pass, mock-signed submission passes on-chain |
| **5 — Signing + CLI** | 2–3 days | — | Full `send`, `batch`, `balance` commands | Automated tests pass, then first real P-256 tx |
| **6 — Hardening** | 3–5 days | — | CI, docs, error polish, gas-sponsored tx | CI green, all manual testing passes |

**Total: 16–27 days** (roughly 3.5–6 weeks with buffer for unknowns)

Phases 0, 1, 1.5, 2, and 3 are complete. Phase 4 can proceed immediately — the setup flow is working end-to-end on Base Sepolia, mock-signer test accounts can be created programmatically, and the `account::setup()` function is fully tested with 67 automated tests. Everything after Phase 3 is sequential because each phase depends on artifacts from the previous one.

---

## Dependency Graph

```
Phase 0 (Preflight: Accounts, Secrets, Monorepo, Repo Migration, Signer Verification)
   │
   ├──► Phase 1 (Contract: Write + Test)  ◄──────────────┐
   │       │                                              │
   │       ├──► Phase 1.5 (Fast Deploy)    [parallel]     │
   │       │       │                                      │
   │       │       ▼                                      │
   │       │    Phase 3 (Setup Flow + Mock Test Account) ◄── Phase 2 (Scaffold) [parallel with Phase 1]
   │       │       │
   │       │       ▼
   │       │    Phase 4 (Bundler: ERC-7769 + ERC-7677 + Mock E2E)
   │       │       │
   │       │       ▼
   │       │    Phase 5 (Signing + CLI + Balance)
   │       │       │
   │       ▼       ▼
   └──► Phase 6 (Hardening + CI)
```

---

## Testing Philosophy

Every phase follows this order:

1. **Write tests first** where possible (or alongside code). Tests define correctness.
2. **Run all automated tests.** Unit tests, integration tests, mock-based end-to-end tests. These must all pass before proceeding.
3. **Manual / human testing last.** Manual verification happens only after automated tests pass, and is used to confirm things that can't be automated (Secure Enclave interaction, visual output, UX flow).

**Assume all code is wrong.** Tests exist to prove otherwise:
- Every encoder has a decoder test (and vice versa).
- Every happy path has corresponding failure tests.
- Every serialization format is tested against known vectors or reference implementations.
- Edge cases (empty inputs, maximum values, off-by-one) are explicitly tested.
- Mock-based tests exercise the full flow before real infrastructure is involved.
- The mock-signer test account enables true on-chain validation in CI without Secure Enclave access.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Foundry lacks EIP-7702 test cheatcodes | Blocks contract integration tests | Medium | Use fork testing against live testnet instead of local EVM. |
| alloy `sign_authorization` API differs from expected | Adds 1–2 days to Phase 3 | Low | Verify exact API in Phase 0 toolchain checks. Fallback: two-step manual construction. |
| Bundler rejects UserOps (format mismatch) | Blocks Phase 4 | Medium | Start with `eth_supportedEntryPoints` to verify compatibility. Test packed→unpacked serialization thoroughly. |
| `keypo-signer --format json` not implemented | Blocks Phase 3 | Low–Medium | Verify in Phase 0.3 against [SPEC.md](https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md). Implement it first if missing. |
| OZ contract behaves unexpectedly with EIP-7702 | Could require contract redesign | Low | Phase 1 automated tests + manual smoke test catch this before Rust work begins. |
| ERC-7677 paymaster response format varies by provider | Adds 1–2 days to Phase 4 | Low | ERC-7677 is a standard. Test with Pimlico first; the opaque context forwarding handles provider differences. |
| ERC-4337 v0.7 nonce handling is non-trivial | Adds 1–2 days to Phase 4 | Medium | Study OZ's `Account` nonce management and EntryPoint's `getNonce` early in Phase 4. |
| Homebrew tap migration breaks install flow | Blocks user installation | Low | Keep `keypo-us/homebrew-tap` repo active as the tap endpoint; monorepo CI pushes updates to it. |
| WebAuthn signature path adds contract complexity | Adds 1–2 days to Phase 1 | Low–Medium | OZ provides `WebAuthn.verify()` — the dual-path routing is minimal. Test both paths thoroughly. WebAuthn path is tested end-to-end via Playwright + virtual authenticator at `localhost:3000` — no hardware required. |
