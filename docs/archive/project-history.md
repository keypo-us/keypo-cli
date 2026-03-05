# Project History

The keypo-wallet system is an EIP-7702 smart account platform that uses Apple Secure Enclave P-256 keys for transaction signing. It was built across ten implementation phases spanning contract development, Rust CLI tooling, and bundler integration.

## Phase Summary

| Phase | Name | Description | Status |
|-------|------|-------------|--------|
| 0 | Preflight | Monorepo setup, subtree migrations, secrets, toolchain verification | Complete |
| 1 | Smart Account Contract | Solidity `KeypoAccount` with P-256 + WebAuthn signature validation, ERC-4337 v0.7, ERC-7821 batch execution | Complete |
| 2 | Rust Crate Scaffolding | Core modules (error, types, traits, signer, state, paymaster), `AccountImplementation` trait, CLI skeleton | Complete |
| 3 | Account Setup Flow | EIP-7702 delegation with ephemeral secp256k1 key, P-256 owner initialization, multi-chain guard | Complete |
| 4 | Bundler Integration | UserOp construction/signing/submission, `BundlerClient` with ERC-7769, `send`/`batch` CLI commands | Complete |
| 5 | Query Commands | `info`/`balance` CLI commands, ERC-20 token support, table/JSON/CSV output formats | Complete |
| 6 | Hardening + CI | Error suggestions, `--verbose` tracing, GitHub Actions CI, documentation | Complete |
| A-B | Unified CLI (Config) | `config.rs` module, `init`/`config` commands, 4-tier config resolution (flag > env > file > default) | Complete |
| C | Unified CLI (Signer) | Seven `keypo-signer` passthrough commands surfaced directly in the wallet CLI | Complete |
| D | Unified CLI (Polish) | `wallet-list`/`wallet-info` commands, `--no-paymaster` flag, `ConfigParse`/`ConfigMissing` errors | Complete |

## Key Design Decisions

- **Ephemeral secp256k1 for EIP-7702 authorization.** The delegation transaction uses a throwaway secp256k1 key as the EOA authority, keeping the long-lived P-256 Secure Enclave key solely for UserOp signing.

- **Pre-hashed P-256 signatures.** Both `keypo-signer` (Swift/CryptoKit) and `MockSigner` (Rust/p256) sign a raw 32-byte digest using the prehash API, avoiding a double-SHA-256 that would produce invalid signatures on-chain.

- **ERC-7821 batch mode exclusively.** All `execute()` calls use mode `0x01` (batch). Single calls are encoded as one-element batches, simplifying the contract interface.

- **Shell-out to keypo-signer.** The Rust crate invokes the Swift CLI as a subprocess and parses its JSON output, avoiding FFI and allowing independent release cycles.

- **Local state file.** Account records persist in `~/.keypo/accounts.json` with `0o700` directory permissions and atomic save (write-to-tmp then rename).

- **4-tier config resolution.** CLI flag > environment variable > config file (`~/.keypo/config.toml`) > built-in default. Every setting follows this precedence chain.

- **Paymaster-first with opt-out.** Transactions are gas-sponsored by default via ERC-7677 paymaster; `--no-paymaster` switches to self-funded UserOps.

- **Deterministic contract address.** `KeypoAccount` is deployed via CREATE2, producing the same address (`0x6d15...8E43`) across all chains.

## Standards

| Standard | Role |
|----------|------|
| **EIP-7702** | EOA delegation to smart account code (type-4 transaction) |
| **ERC-4337 v0.7** | Account abstraction entry point and UserOperation format |
| **ERC-7821** | Minimal batch execution interface on the smart account |
| **ERC-7769** | Bundler JSON-RPC methods (`eth_sendUserOperation`, gas estimation, receipts) |
| **ERC-7677** | Paymaster JSON-RPC methods (`pm_getPaymasterStubData`, `pm_getPaymasterData`) |
| **RIP-7212** | Precompiled P-256 signature verification (used by `SignerP256` / Solady) |
