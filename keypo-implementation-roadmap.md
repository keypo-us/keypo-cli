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
   - `keypo-signer create test-none --policy none` (no biometric, no passcode)
   - `keypo-signer create test-passcode --policy passcode`
   - `keypo-signer create test-biometric --policy biometric` (Touch ID)
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
- keypo-signer-cli verified: JSON output format documented for `info`, `sign`, `list`. All three key policies tested (none, passcode, biometric).
- Target chain confirmed: Base Sepolia (all checks VERIFIED).
- All toolchain blocking checks pass.
- No architecture changes needed — proceed to Phases 1 and 2.

---

## Phase 1 — Smart Account Contract (keypo-account)

**Goal:** Write, test, and deploy the `KeypoAccount` contract on Base Sepolia.

**Duration:** 3–5 days

**Depends on:** Phase 0 (monorepo set up, secrets configured, target chain confirmed)

**Can run in parallel with:** Phase 2 (Rust crate scaffolding)

### 1.1 Project Setup

- Install OpenZeppelin Contracts: `forge install OpenZeppelin/openzeppelin-contracts`
- Configure `foundry.toml` with `evm_version = "prague"` and RPC endpoints
- Set up `remappings.txt`

### 1.2 Contract Implementation

Write `src/KeypoAccount.sol` per the keypo-account spec §2.2. This is approximately 30–40 lines of Solidity on top of OZ building blocks.

**Dual-path signature validation:** The contract supports both raw P-256 signatures (64 bytes) and WebAuthn-wrapped signatures (longer). The `_rawSignatureValidation` override checks signature length to route accordingly, both paths validating against the same stored `(qx, qy)` key. See keypo-account spec §2.3 for details.

**Critical decision during implementation:** Trace through OZ source code to confirm:

1. How `Account.validateUserOp` calls `_rawSignatureValidation` — what's the exact call path?
2. What `caller` is in the `_erc7821AuthorizedExecutor` context when called via EntryPoint → `executeUserOp` → `execute`?
3. How `SignerERC7702` interacts with EIP-7702 nonces — does it handle the protocol nonce vs account nonce separation?

Document findings. If any assumption from the spec is wrong, update the contract and the keypo-wallet spec before proceeding.

### 1.3 P-256 Test Vector Setup (Wycheproof)

Use `ecdsa_secp256r1_sha256_p1363_test.json` from [C2SP/wycheproof](https://github.com/C2SP/wycheproof).

**Approach:**
- **Unit tests:** Hardcode a handful of vectors (valid signature, invalid signature, high-S, wrong key) directly in `test/helpers/P256Helper.sol`. These are self-contained — no file parsing, no external dependencies.
- **Comprehensive coverage (optional):** Parse the full Wycheproof JSON file via `vm.ffi` or a test script for exhaustive vector testing.

**Explicitly not using:** `vm.ffi` to openssl, Rust helper binaries, or `vm.p256` cheatcodes. The hardcoded vectors are sufficient and keep the test suite self-contained.

Package as `test/helpers/P256Helper.sol`.

### 1.4 Automated Tests — All Must Pass Before Any Manual Testing

**Assume all code is wrong. Tests prove it right.**

#### 1.4.1 Unit Tests (`KeypoAccount.t.sol`)

Write all tests from keypo-account spec §4.1:

- `initialize` sets key, reverts on second call
- `_rawSignatureValidation` — valid, invalid, high-S, wrong-key cases (using Wycheproof vectors)
- `_rawSignatureValidation` — 64-byte raw P-256 path
- `_rawSignatureValidation` — WebAuthn-wrapped path (longer signature)
- `_erc7821AuthorizedExecutor` — self, zero, other callers

#### 1.4.2 EIP-7702 Integration Tests (`KeypoAccountSetup.t.sol`)

- `test_delegation_codePrefix` — After delegation, EOA code starts with `0xef0100`
- `test_delegation_initialize` — EOA can call `initialize` on itself after delegation
- `test_delegation_storageIsolation` — Two delegating EOAs have independent storage

These may require fork testing against a live testnet if Foundry's local EVM doesn't fully support EIP-7702 delegation designators.

#### 1.4.3 ERC-4337 Integration Tests (`KeypoAccount4337.t.sol`)

All tests from keypo-account spec §4.3:

- `validateUserOp` — valid signature, invalid signature, wrong sender
- `executeUserOp` — single call, batch calls, ETH transfer, ERC-20 transfer
- Gas estimates — with precompile, without precompile

#### 1.4.4 WebAuthn End-to-End Tests (Playwright)

Tests for the WebAuthn signature validation path use a test frontend at `localhost:3000` automated by Playwright MCP server. See keypo-account spec §4.5 for full details.

- Set up `tests/webauthn-frontend/` with minimal HTML + JS page for WebAuthn ceremony
- Playwright creates a virtual authenticator via Chrome DevTools Protocol (`WebAuthn.addVirtualAuthenticator`) with a known P-256 keypair
- Test flow: register credential → get assertion with test challenge → extract authenticator data + client data JSON + (r, s) → encode WebAuthn signature → verify against contract
- Tests: valid WebAuthn assertion passes on-chain validation, invalid assertion is rejected, wrong key is rejected
- **Fully automated — no human interaction.** The virtual authenticator replaces hardware passkey prompts.

#### 1.4.5 Run All Automated Tests

```bash
forge test -vvv
# If fork required:
forge test --fork-url $BASE_SEPOLIA_RPC -vvv
```

**Gate: All automated tests pass before proceeding to deployment or manual testing.**

### 1.5 Deployment to Testnet

- Write `script/Deploy.s.sol` (CREATE2 via Safe Singleton Factory)
- Deploy to Base Sepolia
- Verify on Basescan
- Write `deployments/base-sepolia.json` with address, tx hash, code hash
- Run `script/Verify.s.sol` against deployed contract
- Export ABI: `cp out/KeypoAccount.sol/KeypoAccount.json` to `keypo-wallet/abi/`

### 1.6 Manual Smoke Test (Human Testing — Only After All Automated Tests Pass)

Manually verify the contract works end-to-end using `cast`:

1. Generate a secp256k1 keypair with `cast wallet new`
2. Fund it from faucet
3. Send an EIP-7702 delegation tx: `cast send --auth <impl_address> ...`
4. Call `initialize(qx, qy)` on the delegated EOA
5. Verify the P-256 key is stored: read the storage slots

This confirms the on-chain side works before adding Rust client complexity.

**Milestone: Contract deployed and verified on Base Sepolia. All automated tests pass. Manual smoke test confirms delegation + initialization on live testnet.**

---

## Phase 2 — Rust Crate Scaffolding (keypo-wallet)

**Goal:** Set up the Rust project structure with all types, traits, and the `KeypoSigner` subprocess wrapper. No chain interaction yet.

**Duration:** 2–3 days

**Depends on:** Phase 0 (keypo-signer-cli JSON format confirmed and verified, monorepo set up).

**Runs in parallel with:** Phase 1 (contract work). No dependency on the deployed contract.

### 2.1 Project Setup

- Set up `keypo-wallet/Cargo.toml` with lib + binary targets
- Add all dependencies from keypo-wallet spec §4.1
- Create module structure per spec §4.2

### 2.2 Core Types and Errors

Implement `types.rs` and `error.rs` from the spec. These are pure data structures with serde derives — no logic, no dependencies beyond alloy primitives.

**Note:** `AccountRecord` must track all chains the smart account has been deployed and initialized on, not just a single chain. See keypo-wallet spec §4.3 for the multi-chain `AccountRecord` and `ChainDeployment` types.

### 2.3 `AccountImplementation` Trait

Implement `traits.rs` with the full trait definition from spec §3. This is the central abstraction.

### 2.4 `KeypoAccountImpl`

Implement the default trait implementation in `impls/keypo_account.rs`. This requires:

- The ABI from Phase 1.5 (or hardcoded function selectors if the ABI isn't ready yet — Phase 1 runs in parallel)
- ERC-7821 encoding logic for single and batch calls
- **BUG FIX:** Mode `0x00` is invalid for ERC-7821. Single calls must use batch mode `0x01` with a 1-element array. Fix `encode_execute` to use mode `0x01` and wrap the single call as a 1-element batch. Remove `encode_execute` / `encode_execute_batch` distinction — there is only `encode_execute` which always uses batch mode.

Write unit tests for encode/decode roundtrips.

### 2.5 `KeypoSigner` Wrapper

Implement `signer.rs` per spec §4.4. The wrapper must parse keypo-signer-cli's JSON output as documented in [SPEC.md](https://github.com/keypo-us/keypo-signer-cli/blob/main/SPEC.md) and verified in Phase 0.3.

Write unit tests with mocked subprocess output (mock the `Command` execution, not the actual binary).

Also implement the `MockSigner` for test environments without Secure Enclave access.

### 2.6 `StateStore`

Implement `state.rs` per spec §4.9. Pure file I/O and JSON serialization. Unit tests for CRUD operations, duplicate detection, file creation on first write.

The state store must support multi-chain account records — an account with a given key label can be deployed on multiple chains.

### 2.7 ERC-7677 Paymaster Client

Implement the ERC-7677 paymaster interface as part of `BundlerClient` (or a small companion module):

- `pm_getPaymasterStubData(userOp, entryPoint, chainId, context)` — returns stub paymaster data for gas estimation.
- `pm_getPaymasterData(userOp, entryPoint, chainId, context)` — returns real paymaster data for submission.

The implementation takes a paymaster URL and an opaque `serde_json::Value` context (forwarded as-is to the paymaster). No trait needed — this single implementation works across Pimlico, Coinbase, Alchemy, and any ERC-7677 compliant provider.

### 2.8 CLI Argument Parsing

Set up `src/bin/main.rs` with clap derive macros for all commands from spec §5.1, including:

- `setup` with `--key-policy` flag (none / passcode / biometric) to select keypo-signer-cli key protection level
- `balance` with optional `--chain`, `--token`, and `--query` flags for GraphQL-style filtering

Commands call stub functions that print "not implemented" — wiring comes in later phases.

### 2.9 Automated Tests — All Must Pass

```bash
cargo test
```

Tests for: types (including multi-chain AccountRecord), trait impls (especially the ERC-7821 mode `0x01` encoding), signer wrapper (against known JSON output from SPEC.md), state store (multi-chain CRUD), ERC-7677 request/response serialization, CLI argument parsing.

**Assume all code is wrong. Every encode/decode path, every serialization format, every edge case must have a test.**

**Milestone: `cargo build` succeeds. `cargo test` passes all unit tests. CLI parses all arguments.**

---

## Phase 1.5 — Fast-Track Contract Deployment (Shortcut)

**Goal:** Get a minimal `KeypoAccount` deployed on Base Sepolia as early as possible so that Phase 3 and 4 work can begin without waiting for the full Phase 1 test suite.

**Duration:** 0.5–1 day (can overlap with Phase 1 automated tests)

**Depends on:** Phase 0 (secrets configured), Phase 1.2 (contract written)

The contract is ~30–40 lines of Solidity on top of audited OZ building blocks. The efficient shortcut is:

1. `forge init`, install OZ, write the contract (already done in Phase 1.2).
2. Deploy via a simple `forge create` (skip CREATE2 deterministic deployment for now).
3. Do one manual smoke test with `cast` to confirm `initialize` stores the key.
4. Write `deployments/base-sepolia.json` with the address.
5. Start building keypo-wallet Phases 3–4 against this deployment.

The full Phase 1 test suite, CREATE2 deployment, and Basescan verification continue in parallel and replace this deployment when complete.

---

## Phase 3 — Account Setup Flow (keypo-wallet)

**Goal:** Implement the `setup` command end-to-end: key creation/selection with policy choice, ephemeral EOA generation, funding wait, EIP-7702 delegation, initialization, key erasure.

**Duration:** 3–5 days

**Depends on:** Phase 1.5 or Phase 1 (contract deployed on testnet), Phase 2 (crate scaffolding complete)

### 3.1 alloy Provider Integration

Set up the alloy HTTP provider with the target chain's RPC endpoint. Confirm basic operations work:

- `provider.get_chain_id()`
- `provider.get_balance(address)`
- `provider.get_code_at(address)`
- `provider.get_transaction_count(address)`

### 3.2 EIP-7702 Authorization Construction

This is the most alloy-specific piece. Implement:

- `PrivateKeySigner::random()` for ephemeral key generation
- `Authorization` struct construction (CONFIRMED: present in alloy)
- Signing the authorization — verify `sign_authorization` on `Signer` trait vs two-step fallback
- Building a type-4 `TransactionRequest` with `with_authorization_list`
- Sending the transaction and getting a receipt

**Security note for ephemeral key generation:** The spec uses `PrivateKeySigner::random()` from alloy, which internally uses the `k256` crate's `SigningKey::random()`. This ultimately sources entropy from `OsRng` (backed by the `getrandom` crate), which calls the OS CSPRNG — `SecRandomCopyBytes` on macOS, `getrandom(2)` on Linux. This is considered best practice for cryptographic key generation in Rust. See keypo-wallet spec §4.5 for details.

### 3.3 Full Setup Flow

Wire together the complete `account::setup` function from spec §4.5:

1. `keypo-signer create` or `keypo-signer info` → P-256 public key (with user's chosen `--key-policy`: none, passcode, or biometric)
2. Verify implementation on-chain
3. Generate ephemeral EOA
4. Wait for funding — **two paths depending on context:**
   - **Automated CI tests:** Use `TEST_FUNDER_PRIVATE_KEY` (a pre-funded account configured in Phase 0.1) to programmatically send testnet ETH to the ephemeral EOA during test setup. No human interaction, no faucet polling. The test harness calls `provider.send_raw_transaction(...)` from the funder wallet to the ephemeral address before proceeding.
   - **Manual / human tests:** Display the ephemeral EOA address and prompt the user to fund it via a faucet. The polling loop waits for the balance to appear on-chain before continuing.
5. Build and sign EIP-7702 authorization
6. Build initialization calldata via `AccountImplementation::encode_initialize` (the P-256 public key coordinates `qx, qy` are ABI-encoded directly in the calldata — see keypo-wallet spec §4.5)
7. Send type-4 tx with auth list + init calldata
8. Verify delegation
9. Zeroize ephemeral key
10. Persist `AccountRecord` to state store (including this chain in the multi-chain deployment list)

### 3.4 Wire CLI `setup` Command

Connect the CLI's `setup` subcommand to `account::setup`. Handle:

- Argument parsing → `ChainConfig` construction
- `--key-policy` flag → pass to keypo-signer for key creation (none / passcode / biometric)
- `AccountImplementation` selection (only `KeypoAccountImpl` for now)
- Progress output (funding address, waiting, tx hash, confirmation)
- State persistence

### 3.5 Mock Signer Test Account for CI

**Create a test account using the `MockSigner`'s P-256 key** during Phase 3 setup testing. This account will have a software P-256 key registered instead of a Secure Enclave key, enabling true end-to-end automated tests in Phase 4 without needing Secure Enclave access in CI.

Steps:
1. Generate a deterministic P-256 keypair in the MockSigner
2. Generate an ephemeral EOA for the test account
3. **Fund the ephemeral EOA programmatically** using `TEST_FUNDER_PRIVATE_KEY` — no faucet interaction in CI
4. Run the full setup flow using the MockSigner's public key for initialization
5. Persist this account in a test state file
6. Phase 4 integration tests will use this account for mock-signed UserOp submission that passes on-chain validation

**CI funding pattern:** All automated tests that require funding (setup flow, send tests, batch tests) use the test funder wallet (`TEST_FUNDER_PRIVATE_KEY`) to transfer testnet ETH to ephemeral addresses during test setup. The faucet polling path is only exercised during manual/human testing.

### 3.6 Automated Tests

- Unit tests for authorization construction and serialization
- Unit tests for setup flow with mocked provider (verify correct transaction structure, delegation verification logic, error paths)
- MockSigner-based integration tests against a fork or local anvil
- Mock signer test account creation (for use in Phase 4)

```bash
cargo test
```

**Gate: All automated tests pass before any manual end-to-end testing.**

### 3.7 Manual End-to-End Test (Human Testing — Last)

Run the full setup flow against the testnet. **This is the test that exercises the faucet polling path** — the human manually sends testnet ETH to the ephemeral EOA via a faucet, and the CLI polling loop detects the funding.

```bash
keypo-wallet setup \
    --key <test-key-label> \
    --key-policy biometric \
    --rpc https://sepolia.base.org \
    --bundler https://api.pimlico.io/v2/84532/rpc?apikey=... \
    --implementation <deployed-address>
```

Fund the ephemeral EOA from faucet. Confirm:

- Transaction succeeds
- EOA code is `0xef0100 || implementation_address`
- P-256 public key is stored in the EOA's storage
- `~/.keypo/accounts.json` is written correctly with the chain deployment record
- The ephemeral key is gone (can't sign again — there's no way to test this directly, but confirm it's not written to disk)

**Milestone: `keypo-wallet setup` creates a working smart account on testnet, controlled by a Secure Enclave P-256 key. All automated tests pass, then manual verification confirms.**

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
| **0 — Preflight** | 1–2 days | — | Accounts, secrets, monorepo, migrated repos, signer verified | All secrets stored, signer CLI verified, repos migrated |
| **1 — Contract** | 3–5 days | ↕ Phase 2 | Deployed + verified `KeypoAccount` on testnet | All automated tests pass, then manual smoke test |
| **1.5 — Fast Deploy** | 0.5–1 day | ↕ Phase 1 tests | Minimal deployment for Rust work to begin | `cast` smoke test confirms initialize works |
| **2 — Crate Scaffold** | 2–3 days | ↕ Phase 1 | Rust crate with types, traits, signer, state, ERC-7677 | `cargo test` passes |
| **3 — Setup Flow** | 3–5 days | — | `keypo-wallet setup` working on testnet + mock signer test account | Automated tests pass, then manual verification |
| **4 — Bundler** | 3–5 days | — | ERC-7769 BundlerClient + ERC-7677 paymaster + UserOp | Automated tests pass, mock-signed submission passes on-chain |
| **5 — Signing + CLI** | 2–3 days | — | Full `send`, `batch`, `balance` commands | Automated tests pass, then first real P-256 tx |
| **6 — Hardening** | 3–5 days | — | CI, docs, error polish, gas-sponsored tx | CI green, all manual testing passes |

**Total: 16–27 days** (roughly 3.5–6 weeks with buffer for unknowns)

Phases 1, 1.5, and 2 run in parallel — the Rust crate is scaffolded while the contract is being tested, and the fast-track deployment unblocks Phase 3 without waiting for the full Phase 1 test suite. Everything after Phase 2 is sequential because each phase depends on artifacts from the previous one.

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
