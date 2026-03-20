# keypo-pay Architecture

## System Overview

```
                        +-----------------------+
                        |     User / Agent      |
                        +-----------+-----------+
                                    |
                        +-----------v-----------+
                        |      keypo-pay CLI     |
                        |  (Rust binary)         |
                        +---+-------+-------+---+
                            |       |       |
                +-----------+  +----+----+  +------------+
                |              |         |               |
    +-----------v---+  +-------v--+  +---v---------+  +--v-----------+
    | keypo-signer  |  | Tempo    |  | Config      |  | MPP Server   |
    | (subprocess)  |  | RPC Node |  | (~/.keypo/) |  | (HTTP 402)   |
    +-------+-------+  +----+-----+  +-------------+  +--------------+
            |                |
    +-------v-------+  +----v-----------+
    | Secure Enclave|  | Tempo Blockchain|
    | (P-256 keys)  |  | (moderato)      |
    +---------------+  +-----------------+
```

keypo-pay is a Rust CLI that orchestrates three external systems:

1. **keypo-signer** (subprocess) for all cryptographic operations — key generation, P-256 signing
2. **Tempo RPC** for blockchain interaction — nonce queries, gas estimation, transaction submission, receipt polling
3. **Config files** (`~/.keypo/tempo/`) for local state — wallet config, access keys, token address book

## Key Architecture: Root + Access Keys

```
    +-------------------+
    |    Root Key        |
    |  (biometric/open)  |
    |                    |
    |  Derives account   |
    |  address           |
    +--------+----------+
             |
             | authorizeKey (on-chain)
             |
    +--------v---+----+--------+
    |            |             |
+---v----+ +----v---+ +-------v--+
|agent-1 | |agent-2 | |agent-3   |
|open    | |open    | |open      |
|$50 USD | |$5 USD  | |$100 USD  |
|no exp  | |1 hour  | |pathusd   |
+--------+ +--------+ +----------+
```

- **Root key**: P-256 key in Secure Enclave with biometric policy (or open in test mode). Derives the Tempo account address via `keccak256(pubKeyX || pubKeyY)`. Only key that can authorize, revoke, or update access key limits.

- **Access keys**: P-256 keys in Secure Enclave with open policy. Each is independently authorized on-chain with per-token spending limits and optional expiry. Available to any process without biometric prompt.

Both enforcement layers work together:
- **Device-level**: keypo-signer policies (biometric/passcode/open)
- **Network-level**: Tempo AccountKeychain precompile (spending limits, expiry, revocation)

## Transaction Flow

### Root Key Transaction (P-256 Signature)

```
1. Fetch nonce      ──> eth_getTransactionCount
2. Fetch gas price  ──> eth_gasPrice
3. Build TempoTx    ──> RLP encode fields
4. Compute hash     ──> keccak256(0x76 || rlp(fields))
5. Sign             ──> keypo-signer sign <hash> --key tempo-root
6. Format sig       ──> 0x01 || r || s || pubX || pubY || 0x00
7. Serialize        ──> 0x76 || rlp(fields || signature)
8. Submit           ──> eth_sendRawTransaction
9. Wait for receipt ──> eth_getTransactionReceipt (poll)
```

### Access Key Transaction (Keychain V2 Signature)

```
1-3. Same as root key
4. Compute tx hash  ──> keccak256(0x76 || rlp(fields))
5. Domain-separate  ──> keccak256(0x04 || tx_hash || root_address)  [V2]
6. Sign             ──> keypo-signer sign <v2_hash> --key tempo-ak-agent-1
7. Format inner sig ──> 0x01 || r || s || pubX || pubY || 0x00
8. Format keychain  ──> 0x04 || root_address || inner_sig
9-10. Same as root key
```

### Access Key Authorization

```
1. Generate key     ──> keypo-signer create --label tempo-ak-agent-1 --policy open
2. Derive address   ──> keccak256(pubKeyX || pubKeyY)
3. Build auth       ──> RLP([chain_id, key_type=1, key_id, expiry?, limits?])
4. Sign auth digest ──> root key signs keccak256(auth_rlp)
5. Build signed auth──> RLP([auth_rlp_list, p256_signature_bytes])
6. Build tx         ──> TempoTx with key_authorization = signed_auth
7. Sign & submit    ──> root key signs the transaction
```

## Tempo Transaction Format (Type 0x76)

```
0x76 || rlp([
  chain_id,                     // u64
  max_priority_fee_per_gas,     // u128
  max_fee_per_gas,              // u128
  gas_limit,                    // u64
  calls,                        // list of [to, value, data]
  access_list,                  // [] (unused)
  nonce_key,                    // U256
  nonce,                        // u64
  valid_before,                 // optional u64 (0x80 if none)
  valid_after,                  // optional u64 (0x80 if none)
  fee_token,                    // optional Address (0x80 if none)
  fee_payer_signature,          // optional bytes (0x80 if none)
  aa_authorization_list,        // [] (unused)
  key_authorization?,           // trailing: zero bytes if absent
  sender_signature              // raw bytes
])
```

## Signature Formats

| Type | ID | Size | Layout |
|------|-----|------|--------|
| P-256 | `0x01` | 130 bytes | `0x01 \|\| r(32) \|\| s(32) \|\| pubX(32) \|\| pubY(32) \|\| pre_hash(1)` |
| Keychain V2 | `0x04` | 151 bytes | `0x04 \|\| root_address(20) \|\| inner_p256_sig(130)` |

- `pre_hash` is always `0x00` (false) — keypo-signer signs the raw keccak256 digest without SHA-256 pre-hashing
- Keychain V1 (`0x03`) is rejected post-T1C hardfork; only V2 is accepted

## MPP Charge Flow

```
Client                          MPP Server
  |                                  |
  |  GET /resource                   |
  |  ─────────────────────────────>  |
  |                                  |
  |  402 Payment Required            |
  |  WWW-Authenticate: Payment ...   |
  |  <─────────────────────────────  |
  |                                  |
  |  [parse challenge]               |
  |  [submit TIP-20 transfer]        |
  |  [wait for receipt]              |
  |                                  |
  |  GET /resource                   |
  |  Authorization: Payment <cred>   |
  |  ─────────────────────────────>  |
  |                                  |
  |  200 OK                          |
  |  Payment-Receipt: <receipt>      |
  |  <─────────────────────────────  |
```

The challenge contains a base64url-encoded JSON request with `amount`, `currency` (token address), and `recipient`. The credential includes the challenge echoed back plus a `payload` with either the signed transaction bytes or the transaction hash.

## Module Map

```
src/
├── lib.rs              Re-exports
├── bin/main.rs          CLI (clap) — all command handlers
├── address.rs           P-256 pubkey → Tempo address derivation
├── access_key.rs        KeyAuthorization RLP, precompile ABI, on-chain queries
├── config.rs            wallet.toml, access-keys.toml, tokens.toml
├── error.rs             Error types with actionable suggestions
├── mpp.rs               MPP charge flow (402 → pay → retry → receipt)
├── rlp.rs               Tempo type 0x76 transaction RLP encode/decode
├── rpc.rs               JSON-RPC helpers, receipt polling, faucet
├── signature.rs         P-256 and Keychain V2 signature formatting
├── signer.rs            P256Signer trait, KeypoSigner subprocess, MockSigner
├── token.rs             Balance queries, decimals, amount parsing/formatting
├── transaction.rs       Tx construction, signing, submission orchestration
└── types.rs             P256PublicKey, P256Signature, KeyInfo
```

## On-Chain Contracts

| Contract | Address | Purpose |
|----------|---------|---------|
| AccountKeychain | `0xAAAAAAAA00000000000000000000000000000000` | Access key authorization, revocation, spending limits |
| pathUSD | `0x20c0000000000000000000000000000000000000` | Testnet stablecoin (6 decimals) |
| AlphaUSD | `0x20c0000000000000000000000000000000000001` | Testnet stablecoin (6 decimals) |
| BetaUSD | `0x20c0000000000000000000000000000000000002` | Testnet stablecoin (6 decimals) |
| ThetaUSD | `0x20c0000000000000000000000000000000000003` | Testnet stablecoin (6 decimals) |
