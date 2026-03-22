# CLAUDE.md -- keypo-pay

Rust CLI wallet for the Tempo blockchain. Uses Apple Secure Enclave P-256 keys as native Tempo account keys via keypo-signer (subprocess). Root-key-plus-access-keys architecture for agent-initiated payments.

## Build / Test / Lint

```bash
cd keypo-pay
cargo check
cargo test
cargo clippy --all-targets -- -D warnings
```

## Architecture

- **Root key** (biometric policy): Derives the Tempo account address, authorizes/revokes access keys
- **Access keys** (open policy): Sign transactions within spending limits, no biometric prompt
- Calls keypo-signer as a subprocess for all Secure Enclave operations (same pattern as keypo-wallet)

## Tempo Protocol Details

- **Transaction type**: `0x76` (EIP-2718)
- **Chain ID**: 42431 (moderato testnet, `0xa5bf`)
- **RPC**: `https://rpc.moderato.tempo.xyz`
- **Explorer**: `https://explore.moderato.tempo.xyz`
- **Faucet**: `tempo_fundAddress` JSON-RPC method on the testnet RPC

### RLP Field Order (confirmed from testnet)

```
0x76 || rlp([
  chain_id, max_priority_fee_per_gas, max_fee_per_gas, gas,
  calls, access_list, nonce_key, nonce,
  valid_before, valid_after, fee_token,
  fee_payer_signature, aa_authorization_list,
  key_authorization?,   // trailing: zero bytes if None
  sender_signature      // raw bytes
])
```

### Signature Formats

- **P-256 (type 0x01)**: 130 bytes = `0x01 || r(32) || s(32) || pubX(32) || pubY(32) || pre_hash(1)`
- **Keychain V2 (type 0x04)**: 151 bytes = `0x04 || root_address(20) || inner_p256_sig(130)`
- **pre_hash = false (0x00)**: keypo-signer signs raw keccak256 digest, no SHA-256 pre-hashing

### Keychain V2 Signing

Access keys sign `keccak256(0x04 || sig_hash || user_address)`, NOT the raw sig_hash.
This domain-separated hash prevents replay across accounts. Required post-T1C hardfork.

### Key Authorization

`SignedKeyAuthorization` is an RLP list with two items:
1. `KeyAuthorization` — nested RLP list `[chain_id, key_type, key_id, expiry?, limits?]`
2. `PrimitiveSignature` — P-256 formatted bytes (130 bytes)

The signing hash includes key_authorization when present in the transaction.

### Token Decimals

pathUSD, alphausd, betausd, thetausd all use **6 decimals** (not 18). Always query `decimals()` on-chain.

### AccountKeychain Precompile

Address: `0xAAAAAAAA00000000000000000000000000000000`

## Conventions

- **Policy names**: `open` / `passcode` / `biometric`
- **keypo-signer create**: `--label <name>` flag, not positional
- **Low-S normalization**: Mandatory on all P-256 signatures
- **P-256 signing**: MUST use `PrehashSigner::sign_prehash()` — no double-hashing
- **Config resolution**: CLI flag > env var (`KEYPO_PAY_RPC_URL`) > config file > error
- **Config directory**: `~/.keypo/tempo/` (wallet.toml, access-keys.toml, tokens.toml)
- **Atomic writes**: Always use temp file + rename pattern

## Dependencies

- `alloy = "1.7"` with `rlp` feature (use `alloy::rlp`, not separate `alloy-rlp`)
- `dirs = "6"` (not 5)
- `thiserror = "2"`
- `p256 = "0.13"` (optional, test-utils feature for MockSigner)
