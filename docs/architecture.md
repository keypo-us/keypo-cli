---
title: Architecture Overview
owner: "@davidblumenfeld"
last_verified: 2026-03-19
status: current
---

# Architecture Overview

**keypo-signer** (Swift) is the core product — hardware-bound P-256 key management, encrypted vault storage, and iCloud backup, all powered by the Secure Enclave. **keypo-wallet** (Rust) is an optional extension that builds on keypo-signer to turn your Mac Secure Enclave into a programmable hardware wallet, powered by account abstraction (EIP7702 and ERC4337). 

## keypo-signer Architecture

### Secure Enclave Key Lifecycle

```
keypo-signer create --label dave --policy biometric
```

```
┌──────────────────────────────────────────────────────────────────────────┐
│  CREATE FLOW                                                             │
│                                                                          │
│  1. Validate label: ^[a-z][a-z0-9-]{0,63}$                              │
│  2. Map policy → SecAccessControl flags:                                 │
│       open      → (none)                                                 │
│       passcode  → .devicePasscode                                        │
│       biometric → .biometryCurrentSet                                    │
│                                                                          │
│  3. Create key:                                                          │
│     SecureEnclave.P256.Signing.PrivateKey(                               │
│       accessControl: flags,                                              │
│       authenticationContext: LAContext()                                  │
│     )                                                                    │
│     → Private key stays in Secure Enclave hardware (never extractable)   │
│     → Stored in Keychain with tag: com.keypo.signer.<label>              │
│                                                                          │
│  4. Save metadata to ~/.keypo/keys.json:                                 │
│     { label, publicKey (x963 hex), policy, createdAt, signCount }        │
│                                                                          │
│  5. Return JSON: { qx, qy } (uncompressed public key coordinates)       │
└──────────────────────────────────────────────────────────────────────────┘
```

```
SIGN FLOW

┌──────────────┐     32-byte hex digest      ┌─────────────────┐
│  Caller      │────────────────────────────▶│  keypo-signer   │
│              │                              │                 │
│              │                              │  1. Load SE key │
│              │                              │     by tag      │
│              │                              │                 │
│              │                              │  2. Cast 32B →  │
│              │                              │     SHA256Digest │
│              │                              │     (pointer    │
│              │                              │      reinterpret│
│              │                              │      — no public│
│              │                              │      init)      │
│              │                              │                 │
│              │     { r, s }                 │  3. Sign digest │
│              │◀────────────────────────────│     (no rehash) │
│              │                              │                 │
│              │                              │  4. Low-S       │
│              │                              │     normalize:  │
│              │                              │     if s > n/2  │
│              │                              │     then s=n-s  │
└──────────────┘                              └─────────────────┘

Pre-hash signing is critical — CryptoKit's signature(for: Data) would
SHA-256 the input again, breaking on-chain P-256 verification.
See ADR-002.
```

### Vault Encryption (ECIES)

Secrets are encrypted per-entry using ECIES with Secure Enclave key agreement keys. Secrets never exist on disk in plaintext.

```
ENCRYPT (vault set)

┌───────────────────────────────────────────────────────────────────────┐
│                                                                       │
│  1. Generate ephemeral P256.KeyAgreement.PrivateKey (in software)     │
│                                                                       │
│  2. ECDH: ephemeralPrivate × SE_public_key → sharedSecret             │
│                                                                       │
│  3. HKDF-SHA256:                                                      │
│       IKM:  sharedSecret                                              │
│       salt: (empty)                                                   │
│       info: "keypo-vault-v1" || secret_name (UTF-8 bytes)             │
│       output: 32 bytes (256-bit symmetric key)                        │
│                                                                       │
│  4. AES-256-GCM seal(plaintext, key)                                  │
│                                                                       │
│  5. Store in ~/.keypo/vault.json:                                     │
│     {                                                                 │
│       "ephemeralPublicKey": <x963 base64>,                            │
│       "nonce": <12 bytes base64>,                                     │
│       "ciphertext": <base64>,                                         │
│       "tag": <16 bytes base64>,                                       │
│       "createdAt": <ISO 8601>,                                        │
│       "updatedAt": <ISO 8601>                                         │
│     }                                                                 │
└───────────────────────────────────────────────────────────────────────┘


DECRYPT (vault get)

┌───────────────────────────────────────────────────────────────────────┐
│                                                                       │
│  1. Load SE KeyAgreement private key (with LAContext for auth)         │
│     Tag: com.keypo.vault.<policy>                                     │
│     Policy gate: biometric → Touch ID, passcode → device passcode     │
│                                                                       │
│  2. Reconstruct ephemeral public key from stored x963 bytes           │
│                                                                       │
│  3. ECDH: SE_private_key × ephemeralPublic → sharedSecret             │
│                                                                       │
│  4. HKDF-SHA256 (same params as encrypt)                              │
│                                                                       │
│  5. AES-256-GCM open(nonce, ciphertext, tag, key) → plaintext         │
│                                                                       │
│  6. Zeroize plaintext after use                                       │
└───────────────────────────────────────────────────────────────────────┘
```

**HMAC integrity envelope**: Before any vault mutation, the HMAC is verified. Key derivation: ECDH with SE key → HKDF-SHA256 (info: `"keypo-vault-integrity-v1"`) → HMAC-SHA256 over canonical JSON (`.sortedKeys` formatting). This detects tampering or corruption before any write.

**Vault storage**: Default is Keychain — one `kSecClassGenericPassword` item per policy tier, scoped to access group `FWJKHZ4TZD.com.keypo.signer`. Per-item atomicity (not transactional across tiers). 50 KB size limit per tier. Legacy file store (`~/.keypo/vault.json`, POSIX `flock`, permissions 600) available via `--config` flag. Auto-migrated on first run.

### Vault Key Types

The Secure Enclave holds two distinct P-256 key types:

| Purpose | Key Type | Keychain Tag |
|---|---|---|
| Signing (create/sign/verify) | `P256.Signing.PrivateKey` | `com.keypo.signer.<label>` |
| Vault encryption (ECDH) | `P256.KeyAgreement.PrivateKey` | `com.keypo.vault.<policy>` |

Signing keys are per-label (user-named). Vault keys are per-policy (one per access tier). Both are hardware-bound and non-extractable.

### Backup/Restore Crypto

```
BACKUP (vault backup)

┌───────────────────────────────────────────────────────────────────────┐
│                                                                       │
│  Pre-flight: verify iCloud sign-in + iCloud Drive + iCloud Keychain   │
│                                                                       │
│  1. Generate or retrieve synced key (256-bit random):                 │
│     Stored in iCloud Keychain:                                        │
│       service: "com.keypo.vault-backup"                               │
│       kSecAttrSynchronizable: true                                    │
│       kSecAttrAccessible: afterFirstUnlock                            │
│                                                                       │
│  2. Generate passphrase: 4-word Diceware (EFF short wordlist)         │
│     Case-sensitive, confirmation by re-entering 2 random words        │
│                                                                       │
│  3. Generate random salts:                                            │
│     argon2Salt: 16 bytes                                              │
│     hkdfSalt:   32 bytes                                              │
│                                                                       │
│  4. Key derivation (two-factor):                                      │
│     a. Argon2id(passphrase, argon2Salt)                               │
│        ops: 3, mem: 64 MB, output: 32 bytes                           │
│        (via libsodium / Sodium package)                               │
│                                                                       │
│     b. HKDF-SHA256:                                                   │
│        IKM:  syncedKey || argon2Output                                │
│        salt: hkdfSalt                                                 │
│        info: "keypo-vault-backup-v1"                                  │
│        output: 32 bytes (backup encryption key)                       │
│                                                                       │
│  5. Serialize all vault secrets → BackupPayload JSON                  │
│                                                                       │
│  6. AES-256-GCM seal(payload, backupKey)                              │
│                                                                       │
│  7. Write BackupBlob to iCloud Drive:                                 │
│     ~/Library/Mobile Documents/com~apple~CloudDocs/                   │
│       Keypo/vault-backup.json                                         │
│     { version: 1, deviceName, argon2Salt, hkdfSalt,                  │
│       nonce, ciphertext, authTag, secretCount, vaultNames }           │
│                                                                       │
│  Two-factor security: both the synced key (iCloud Keychain)           │
│  AND the passphrase are required to decrypt. Losing either one        │
│  makes the backup unrecoverable.                                      │
└───────────────────────────────────────────────────────────────────────┘


RESTORE (vault restore)

┌───────────────────────────────────────────────────────────────────────┐
│                                                                       │
│  1. Read BackupBlob from iCloud Drive                                 │
│     Reject if version != 1                                            │
│                                                                       │
│  2. Retrieve synced key from iCloud Keychain                          │
│     Prompt for passphrase                                             │
│                                                                       │
│  3. Derive backup key (same Argon2id + HKDF as backup)                │
│                                                                       │
│  4. AES-256-GCM open → BackupPayload                                  │
│                                                                       │
│  5. Compute diff:                                                     │
│     localOnly  — secrets only on this device                          │
│     backupOnly — secrets only in backup                               │
│     inBoth     — secrets on both (local version wins on merge)        │
│                                                                       │
│  6. Output depends on TTY detection (isatty(STDIN_FILENO)):           │
│     TTY:  interactive diff display + merge/replace/cancel prompt      │
│     Pipe: JSON conflict output for scripted consumption               │
│                                                                       │
│  7. Two-phase merge:                                                  │
│     Phase A: verify HMACs for all affected vaults                     │
│              (triggers auth prompts — one LAContext per policy)        │
│     Phase B: mutate vault with cached LAContexts                      │
│              (no additional auth prompts)                              │
└───────────────────────────────────────────────────────────────────────┘
```

---

## keypo-wallet Architecture

keypo-wallet (Rust) builds on keypo-signer — it shells out to the Swift CLI for all Secure Enclave operations (key creation, signing, vault access). Everything above applies as the foundation layer.

### Wallet Creation (Setup)

```
keypo-wallet setup --key dave --rpc https://sepolia.base.org
```

#### Step 1: Create or retrieve P-256 key

```
┌──────────────┐         ┌──────────────────┐         ┌─────────────────┐
│ keypo-wallet │──shell──▶│  keypo-signer    │────────▶│ Secure Enclave  │
│   (Rust)     │◀─JSON───│  (Swift CLI)     │◀────────│ (Apple Silicon) │
└──────────────┘         └──────────────────┘         └─────────────────┘
                          create --label dave           Generates P-256
                          --policy biometric            private key.
                                                       Never leaves
                          Returns: { qx, qy }           the hardware.
```

The P-256 public key (qx, qy) is returned. The private key stays in the Secure Enclave permanently — no software, not even the OS, can extract it.

#### Step 2: Generate ephemeral EOA

```
┌──────────────┐
│ keypo-wallet │  Generates a random secp256k1 private key in memory.
│              │  Derives an Ethereum address from it: 0xD88E...eb80
│              │  This address becomes the user's smart account address.
└──────────────┘
```

This key exists only for this setup transaction. It's discarded after.

#### Step 3: Fund the EOA

```
┌──────────────┐                              ┌──────────────┐
│ keypo-wallet │──── send 0.001 ETH ─────────▶│  Base Sepolia │
│              │     to 0xD88E...eb80          │  (L2 chain)  │
│              │◀─── tx confirmed ────────────│              │
└──────────────┘                              └──────────────┘

  Funding source:
  - TEST_FUNDER_PRIVATE_KEY env var (automated), OR
  - User manually sends ETH (CLI waits, polling every 5s)
```

#### Step 4: Send the EIP-7702 setup transaction

This is a single type-4 transaction that does two things atomically:

```
┌──────────────┐                              ┌──────────────────────────┐
│ keypo-wallet │──── type-4 tx ──────────────▶│  Base Sepolia            │
│              │     from: 0xD88E (EOA)        │                          │
│              │                               │  1. Authorization List:  │
│              │     authorization_list: [      │     EVM sets 0xD88E's   │
│              │       delegate to 0x6d15      │     code to:             │
│              │       (KeypoAccount)          │     0xef0100 || 0x6d15   │
│              │     ]                         │     (delegation prefix)  │
│              │                               │                          │
│              │     calldata:                 │  2. Calls 0xD88E which   │
│              │       initialize(qx, qy)      │     now runs KeypoAccount│
│              │                               │     code. Stores qx,qy  │
│              │                               │     as the authorized    │
│              │◀─── tx confirmed ────────────│     signer.              │
└──────────────┘                              └──────────────────────────┘
```

#### Step 5: Verify and save

```
┌──────────────┐                              ┌──────────────┐
│ keypo-wallet │──── eth_getCode(0xD88E) ────▶│  Base Sepolia │
│              │◀─── 0xef0100||0x6d15... ─────│              │
│              │                              └──────────────┘
│              │     ✓ Delegation confirmed
│              │
│              │──── Save to ~/.keypo/accounts.json:
│              │     {
│              │       key_label: "dave",
│              │       address: "0xD88E...eb80",
│              │       chain_id: 84532,
│              │       public_key: { qx, qy },
│              │       implementation: "0x6d15..."
│              │     }
└──────────────┘

  The ephemeral secp256k1 key is dropped and zeroized.
  0xD88E is now permanently controlled by the P-256 key.
```

#### After setup — what the account looks like on-chain

```
┌─────────────────────────────────────────────────┐
│  EOA: 0xD88E...eb80                             │
│                                                 │
│  Code: 0xef0100 || 0x6d15...8E43                │
│         ▲                                       │
│         │ EIP-7702 delegation pointer            │
│         │                                       │
│  Storage (written by initialize):               │
│    slot 0: qx (P-256 public key x-coordinate)  │
│    slot 1: qy (P-256 public key y-coordinate)  │
│                                                 │
│  Balance: whatever ETH remains after setup gas  │
└─────────────────────────────────────────────────┘
         │
         │ When called, EVM loads code from:
         ▼
┌─────────────────────────────────────────────────┐
│  KeypoAccount: 0x6d15...8E43                    │
│  (shared implementation — not your account)     │
│                                                 │
│  Logic:                                         │
│    - validateUserOp(): verify P-256 signature   │
│    - execute(): ERC-7821 batch execution        │
│    - Conforms to ERC-4337 v0.7                  │
└─────────────────────────────────────────────────┘
```

---

### Using the Wallet (Sending a Transaction)

```
keypo-wallet send --key dave --to 0xBob --value 1000000000000000 \
  --bundler https://api.pimlico.io/...  --rpc https://sepolia.base.org
```

#### Step 1: Build the UserOperation

```
┌──────────────┐                              ┌──────────────┐
│ keypo-wallet │──── getNonce(0xD88E) ───────▶│  EntryPoint   │
│              │◀─── nonce: 3 ────────────────│  (on-chain)   │
│              │                              └──────────────┘
│              │──── eth_gasPrice ───────────▶┌──────────────┐
│              │◀─── gas prices ─────────────│  RPC node     │
│              │                              └──────────────┘
│              │
│              │  Constructs UserOperation:
│              │  {
│              │    sender: 0xD88E,
│              │    nonce: 3,
│              │    callData: execute(0x01, encode([
│              │      { to: 0xBob, value: 0.001 ETH, data: 0x }
│              │    ])),
│              │    maxFeePerGas: ...,
│              │    signature: 0x (empty — filled in step 3)
│              │  }
└──────────────┘
```

#### Step 2: Estimate gas

```
┌──────────────┐                              ┌──────────────┐
│ keypo-wallet │──── estimateUserOpGas ──────▶│  Bundler      │
│              │◀─── gas limits ─────────────│  (Pimlico)    │
│              │                              └──────────────┘
│              │  Fills in:
│              │    preVerificationGas (+ 10% buffer)
│              │    verificationGasLimit
│              │    callGasLimit
└──────────────┘
```

#### Step 3: Sign with Secure Enclave

```
┌──────────────┐                                        ┌─────────────────┐
│ keypo-wallet │  1. Compute UserOp hash                │                 │
│              │     (ERC-4337 v0.7 packed format)      │                 │
│              │                                        │                 │
│              │  2. Shell out to keypo-signer:          │                 │
│              │──── sign <hash> --key dave ────────────▶│ Secure Enclave  │
│              │                                        │                 │
│              │     (biometric policy → Touch ID        │  Signs with     │
│              │      prompt appears on screen)          │  P-256 private  │
│              │                                        │  key            │
│              │◀─── { r, s } ──────────────────────────│                 │
│              │                                        └─────────────────┘
│              │  3. Encode signature into UserOp:
│              │     signature = abi.encode(r, s)
└──────────────┘
```

#### Step 4: Submit to bundler

```
┌──────────────┐                              ┌──────────────┐
│ keypo-wallet │──── sendUserOperation ──────▶│  Bundler      │
│              │◀─── userOpHash ─────────────│  (Pimlico)    │
│              │                              └──────┬───────┘
│              │                                     │
│              │  Polls for receipt...                │ Bundles UserOp
│              │  (exponential backoff:               │ into a regular
│              │   2s → 3s → 4.5s → 6.75s → 10s)    │ transaction
│              │                                     ▼
│              │                              ┌──────────────┐
│              │                              │  EntryPoint   │
│              │                              │  (on-chain)   │
│              │                              └──────┬───────┘
│              │                                     │
│              │                                     ▼
│              │                              ┌──────────────────────┐
│              │                              │  On-chain execution: │
│              │                              │                      │
│              │                              │  1. EntryPoint calls │
│              │                              │     0xD88E           │
│              │                              │     .validateUserOp()│
│              │                              │                      │
│              │                              │  2. KeypoAccount code│
│              │                              │     runs at 0xD88E:  │
│              │                              │     - reads qx,qy   │
│              │                              │       from storage   │
│              │                              │     - P-256 verify(  │
│              │                              │         hash, r, s,  │
│              │                              │         qx, qy)     │
│              │                              │     - returns OK     │
│              │                              │                      │
│              │                              │  3. EntryPoint calls │
│              │                              │     0xD88E.execute() │
│              │                              │     → sends 0.001   │
│              │                              │       ETH to 0xBob  │
│              │                              └──────┬───────────────┘
│              │                                     │
│              │◀─── receipt { success: true } ──────┘
│              │
│              │  "Transaction sent!"
│              │  "  UserOp hash: 0x..."
│              │  "  Tx hash:     0x..."
│              │  "  Success:     true"
└──────────────┘
```

#### With a paymaster (gas sponsorship)

Same flow, but before signing:

```
┌──────────────┐                              ┌──────────────┐
│ keypo-wallet │──── pm_getPaymasterStubData ▶│  Paymaster    │
│              │◀─── stub paymaster fields ───│  (Pimlico)    │
│              │                              └──────────────┘
│              │     (used during gas estimation)
│              │
│              │──── pm_getPaymasterData ────▶┌──────────────┐
│              │◀─── signed paymaster fields ─│  Paymaster    │
│              │                              └──────────────┘
│              │     (paymaster commits to sponsoring this UserOp)
│              │
│              │  Then signs and submits as normal.
│              │  Gas is paid by the paymaster, not the account.
└──────────────┘
```

---

## Full System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│  keypo-signer (Swift)                                                   │
│                                                                         │
│  ┌──────────┐   ┌──────────────┐   ┌──────────────┐   ┌─────────────┐ │
│  │  Secure  │   │  Key Mgmt    │   │  Vault       │   │  Backup     │ │
│  │  Enclave │   │              │   │  (ECIES)     │   │  (Argon2id  │ │
│  │          │   │  create      │   │              │   │   + HKDF    │ │
│  │  P-256   │   │  sign        │   │  set/get     │   │   + AES)   │ │
│  │  Signing │   │  verify      │   │  exec        │   │             │ │
│  │  + Key   │   │  rotate      │   │  import      │   │  iCloud    │ │
│  │  Agree-  │   │  delete      │   │              │   │  Keychain  │ │
│  │  ment    │   │              │   │  HMAC        │   │  + Drive   │ │
│  │  keys    │   │  ~/.keypo/   │   │  integrity   │   │             │ │
│  │          │   │  keys.json   │   │              │   │  vault-    │ │
│  │  (never  │   │              │   │  ~/.keypo/   │   │  backup    │ │
│  │  leaves  │   │              │   │  vault.json  │   │  .json     │ │
│  │  HW)     │   │              │   │              │   │             │ │
│  └──────────┘   └──────────────┘   └──────────────┘   └─────────────┘ │
└────────────────────────────┬────────────────────────────────────────────┘
                             │ shell out (JSON over stdout)
┌────────────────────────────▼────────────────────────────────────────────┐
│  keypo-wallet (Rust)                                                    │
│                                                                         │
│  ┌──────────────┐   ┌───────────┐   ┌───────────┐   ┌──────────────┐  │
│  │  Account     │   │  Bundler  │   │ EntryPoint│   │  Your        │  │
│  │  Setup       │   │ (Pimlico) │   │ (on-chain)│   │  Account     │  │
│  │              │   │           │   │           │   │  (0xD88E)    │  │
│  │  EIP-7702   │   │  Packages │   │ Validates │   │              │  │
│  │  delegation  │   │  UserOps  │   │ signature │   │  Executes    │  │
│  │  + P-256    │   │  into txs │   │ via P-256 │   │  the call    │  │
│  │  key reg    │   │           │   │ precompile│   │              │  │
│  └──────────────┘   └───────────┘   └───────────┘   └──────────────┘  │
│                                                                         │
│  ~/.keypo/accounts.json    ~/.keypo/config.toml                         │
└─────────────────────────────────────────────────────────────────────────┘
```

The key security property: the only component that touches private keys is the Secure Enclave hardware. Everything else works with public keys, hashes, and signatures.
