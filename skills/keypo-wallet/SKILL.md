---
name: keypo-wallet
description: Use when building, operating, or integrating with EVM smart accounts backed by Apple Secure Enclave hardware keys. Covers creating P-256 signing keys, setting up EIP-7702 delegated smart accounts, sending transactions via ERC-4337 bundlers, batching calls with ERC-7821, and querying balances. Also use when composing keypo-wallet as the secure execution backend for other EVM protocol skills (Uniswap, Aave, ENS, etc.) — keypo-wallet handles key management and transaction submission while protocol skills handle domain-specific calldata construction.
license: MIT
metadata:
  author: keypo-us
  version: "0.1.0"
  compatibility: macOS with Apple Silicon only. Requires Homebrew for installation.
---

# keypo-wallet

A CLI that turns your Mac into a programmable hardware wallet. Private keys are P-256 keys stored in the Apple Secure Enclave — they never leave the hardware, and Apple cannot extract them. The wallet uses EIP-7702 smart account delegation with ERC-4337 account abstraction for transaction submission.

**Install:** `brew install keypo-us/tap/keypo-wallet`
This installs both `keypo-wallet` (Rust CLI) and `keypo-signer` (Swift CLI for Secure Enclave operations).

**Source:** https://github.com/keypo-us/keypo-wallet

---

## Core Concepts

**Secure Enclave keys.** All signing keys are P-256 (secp256r1) keys generated inside the Mac's Secure Enclave. The private key material is hardware-bound and non-exportable. This is the same cryptographic primitive used by WebAuthn/passkeys.

**EIP-7702 delegation.** Each wallet is a standard EOA that delegates execution to the KeypoAccount smart contract via EIP-7702. This gives EOAs smart account capabilities (signature validation, batched calls, gas sponsorship) without deploying a separate contract.

**ERC-4337 bundler.** Transactions are submitted as UserOperations through an ERC-4337 bundler. The default implementation uses Pimlico, but any ERC-4337 v0.7 bundler works (Coinbase, Alchemy, etc.).

**Key policies.** Each key has a signing policy that controls when the Secure Enclave releases a signature:
- `open` — No restrictions. Best for agent-controlled wallets and automated workflows.
- `passcode` — Requires the device passcode for each signature.
- `bio` — Requires Touch ID biometric for each signature.

**For agent use, always use the `open` policy.** The `passcode` and `bio` policies require interactive user input and will block automated workflows.

**ERC-7821 batch execution.** Multi-call operations use ERC-7821 batch mode. Important: single calls must also use batch mode `0x01` with a 1-element array. Mode `0x00` is invalid for this contract.

---

## Setup Workflow

### 1. Initialize configuration

```bash
keypo-wallet init
```

Prompts for RPC URL, bundler URL, and optional paymaster URL. Saves to `~/.keypo/config.toml`.

You can also set values directly:

```bash
keypo-wallet config set network.rpc_url "https://sepolia.base.org"
keypo-wallet config set network.bundler_url "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_KEY"
keypo-wallet config set network.paymaster_url "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_KEY"
```

Config resolution precedence: CLI flag > environment variable > config file.

Environment variables: `KEYPO_RPC_URL`, `KEYPO_BUNDLER_URL`, `KEYPO_PAYMASTER_URL`, `KEYPO_PAYMASTER_POLICY_ID`.

### 2. Create a key and set up the smart account

```bash
keypo-wallet setup --key <key-name> --key-policy open
```

This does three things:
1. Creates a P-256 signing key in the Secure Enclave
2. Signs an EIP-7702 delegation to the KeypoAccount contract
3. Registers the P-256 public key as the account owner

The account record is saved to `~/.keypo/accounts.json`.

**Funding:** Setup requires a small amount of ETH (~$1) for gas. The CLI prints the wallet address and waits for you to send ETH before proceeding.

### 3. Verify the wallet

```bash
keypo-wallet wallet-info --key <key-name>
```

Shows wallet address, key policy, P-256 public key, chain deployments, and live ETH balance. Use `keypo-wallet info --key <key-name>` for the same data without the RPC call for balance.

---

## Sending Transactions

### Send a single transaction

```bash
keypo-wallet send \
  --key <key-name> \
  --to <recipient-address> \
  --value <wei-amount> \
  --data <hex-calldata>       # optional, for contract calls
```

- `--value` is in wei. Example: 0.001 ETH = `1000000000000000`
- `--data` is hex-encoded calldata for contract interactions
- If a paymaster is configured, gas is sponsored automatically
- Add `--no-paymaster` to pay gas from the wallet's ETH balance

### Send a batch transaction

Batch accepts a JSON array of call objects. Pass `--calls -` to read from stdin (preferred for agent composition) or `--calls <file.json>` to read from a file.

```bash
# Preferred: pipe JSON from stdin (no temp files needed)
echo '[
  {"to": "0xContractAddress", "value": "0", "data": "0xCalldata"},
  {"to": "0xAnotherContract", "value": "0", "data": "0xMoreCalldata"}
]' | keypo-wallet batch --key <key-name> --calls -

# Alternative: read from a file
keypo-wallet batch --key <key-name> --calls calls.json
```

The call object format is `{ "to": "0x...", "value": "0", "data": "0x..." }`. All calls execute atomically in a single UserOperation. Use batch for multi-step DeFi operations (approve + swap, supply + borrow, etc.).

**Agents: always prefer `--calls -` with stdin.** This avoids temp file creation and cleanup. Construct the JSON array in memory and pipe it directly.

---

## Querying Wallet State

**Always use these commands to check wallets and balances. Do not make raw RPC calls or use curl/cast to query balances — keypo-wallet has built-in commands for this.**

### List all wallets

```bash
keypo-wallet wallet-list                    # all wallets with live balances
```

This is the fastest way to see every wallet at once — addresses, key policies, chain deployments, and current ETH balances in a single command.

### Get details for a specific wallet

```bash
keypo-wallet wallet-info --key <key-name>   # full details + live on-chain balance
keypo-wallet info --key <key-name>          # same details, no RPC call (faster)
```

### Query balances

```bash
keypo-wallet balance --key <key-name>                              # ETH balance
keypo-wallet balance --key <key-name> --token <erc20-address>      # ERC-20 balance
```

---

## Key Management Commands

These use the `keypo-signer` binary under the hood:

```bash
keypo-wallet create --name <key-name> --policy <open|passcode|bio>
keypo-wallet list
keypo-wallet key-info --name <key-name>
keypo-wallet sign --name <key-name> --digest <32-byte-hex>
keypo-wallet verify --name <key-name> --digest <hex> --signature <hex>
keypo-wallet delete --name <key-name>
```

---

## Deployments

| Chain | Chain ID | Contract | Address |
|-------|----------|----------|---------|
| Base Sepolia | 84532 | KeypoAccount | `0x6d1566f9aAcf9c06969D7BF846FA090703A38E43` |

The address is deterministic (CREATE2) and will be identical across all chains.

---

## Composing keypo-wallet with Other EVM Skills

keypo-wallet is designed to be the **secure execution backend** for any EVM operation. When you have protocol-specific skills installed (Uniswap, Aave, ENS, ETHSkills, etc.), use those skills for domain knowledge and calldata construction, then execute through keypo-wallet.

### The composition pattern

1. **Protocol skill** provides: contract addresses, function signatures, calldata encoding, parameter validation, protocol-specific constraints
2. **keypo-wallet** provides: key management, transaction signing, bundler submission, gas sponsorship, batch execution

### Example: Uniswap swap via keypo-wallet

If the Uniswap skill (e.g., `Uniswap/uniswap-ai`) tells you to construct a swap with specific calldata:

```bash
# Single swap — use send
keypo-wallet send \
  --key agent-wallet \
  --to 0xUniswapRouterAddress \
  --data 0x<encoded-swap-calldata>

# Approve + swap — pipe calls via stdin
echo '[
  {"to": "0xTokenAddress", "value": "0", "data": "0x095ea7b3<router-address-padded><amount-padded>"},
  {"to": "0xUniswapRouterAddress", "value": "0", "data": "0x<encoded-swap-calldata>"}
]' | keypo-wallet batch --key agent-wallet --calls -
```

### Example: ERC-20 transfer

```bash
# Transfer 100 USDC (6 decimals) to a recipient
# Function: transfer(address,uint256)
# Selector: 0xa9059cbb
keypo-wallet send \
  --key agent-wallet \
  --to 0xUSDCContractAddress \
  --data 0xa9059cbb<recipient-padded-to-32-bytes><amount-padded-to-32-bytes>
```

### Example: Read-only queries

For balance checks, always use keypo-wallet's built-in commands:

```bash
keypo-wallet wallet-list                                           # all wallets + balances
keypo-wallet balance --key agent-wallet                            # ETH balance for one wallet
keypo-wallet balance --key agent-wallet --token <token-address>    # ERC-20 balance
```

For other read-only contract calls (getReserves, totalSupply, etc.) that keypo-wallet doesn't cover, use `cast` (Foundry):

```bash
cast call <contract-address> "functionSignature(args)(returnType)" <args> --rpc-url https://sepolia.base.org
```

### Compatible skill ecosystems

keypo-wallet works as the execution layer for skills from these sources:

- **Uniswap AI** (`Uniswap/uniswap-ai`) — v4 pool deployment, swaps, liquidity
- **ETHSkills** (`austintgriffith/ethskills`) — gas estimation, wallet management, L2 deployment, DeFi building blocks for Uniswap/Aave/Compound/MakerDAO
- **kukapay/crypto-skills** — EVM swiss-knife operations, yield farming research
- **OpenClaw skills** (`BankrBot/openclaw-skills`) — ENS management, token deployment, DeFi operations
- **Coinbase AgentKit skills** — adapt calldata patterns for keypo-wallet execution
- **Any skill that produces EVM calldata** — if a skill outputs a target address and calldata, keypo-wallet can execute it

### When building new protocol skills for keypo-wallet

If you are authoring a new skill intended to work with keypo-wallet:

1. Focus the skill on **calldata construction and protocol knowledge** — do not include signing or transaction submission logic
2. Output operations as `{ to, value, data }` JSON objects — this is the universal interface between protocol skills and keypo-wallet
3. For single operations, the agent maps `{ to, value, data }` to `keypo-wallet send --to ... --value ... --data ...`
4. For multi-step operations (approve + swap, supply + borrow), output a JSON array of call objects — the agent pipes it to `keypo-wallet batch --calls -`
5. Include verified contract addresses for each supported chain — do not let the agent guess addresses
6. Include gas estimation guidance specific to the protocol

---

## Security Notes

- Private keys **never** leave the Secure Enclave. There is no export command. A malicious skill cannot exfiltrate key material.
- The `open` key policy allows signing without user interaction. Only use this for wallets with limited funds or in controlled agent environments.
- Always verify contract addresses against known registries before constructing transactions. Do not hallucinate addresses.
- When using third-party skills, review the SKILL.md contents before executing any transactions. The keypo-wallet skill ecosystem does not currently have a verification or signing mechanism for skills.
- For high-value operations, prefer the `passcode` or `bio` key policy and have the user approve interactively.