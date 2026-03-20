---
title: Architecture Overview
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# Keypo Wallet Architecture

ERC-4337 smart wallet with P-256 (Secure Enclave) signing, EIP-7702 delegation, and ERC-7821 batch execution.

## Wallet Creation (Setup)

```
keypo-wallet setup --key dave --rpc https://sepolia.base.org
```

### Step 1: Create or retrieve P-256 key

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

### Step 2: Generate ephemeral EOA

```
┌──────────────┐
│ keypo-wallet │  Generates a random secp256k1 private key in memory.
│              │  Derives an Ethereum address from it: 0xD88E...eb80
│              │  This address becomes the user's smart account address.
└──────────────┘
```

This key exists only for this setup transaction. It's discarded after.

### Step 3: Fund the EOA

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

### Step 4: Send the EIP-7702 setup transaction

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

### Step 5: Verify and save

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

### After setup — what the account looks like on-chain

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

## Using the Wallet (Sending a Transaction)

```
keypo-wallet send --key dave --to 0xBob --value 1000000000000000 \
  --bundler https://api.pimlico.io/...  --rpc https://sepolia.base.org
```

### Step 1: Build the UserOperation

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

### Step 2: Estimate gas

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

### Step 3: Sign with Secure Enclave

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

### Step 4: Submit to bundler

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

### With a paymaster (gas sponsorship)

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

## Component Overview

```
┌──────────┐    ┌──────────────┐    ┌───────────┐    ┌───────────┐    ┌──────────┐
│  Secure  │    │ keypo-wallet │    │  Bundler  │    │ EntryPoint│    │   Your   │
│  Enclave │    │   (CLI)      │    │ (Pimlico) │    │ (on-chain)│    │  Account │
│          │    │              │    │           │    │           │    │ (0xD88E) │
│  Holds   │    │  Builds      │    │ Packages  │    │ Validates │    │          │
│  P-256   │    │  UserOps,    │    │ UserOps   │    │ signature │    │ Executes │
│  private │    │  requests    │    │ into txs, │    │ via P-256 │    │ the call │
│  key     │    │  signatures  │    │ submits   │    │ on-chain  │    │          │
│          │    │              │    │ to chain  │    │ precompile│    │          │
└──────────┘    └──────────────┘    └───────────┘    └───────────┘    └──────────┘
  Hardware        Your machine        Off-chain        On-chain        On-chain
  (never leaves)
```

The key security property: the only component that touches the private key is the Secure Enclave hardware. Everything else works with public keys, hashes, and signatures.
