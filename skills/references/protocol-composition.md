# Protocol Skill Composition Reference

Detailed patterns for composing keypo-wallet with specific protocol skills and agent frameworks. This file is loaded on-demand when the agent needs deeper protocol integration context.

---

## Calldata Encoding

keypo-wallet's `--data` flag accepts raw hex-encoded calldata. To construct calldata for contract calls, use one of these approaches:

### Using cast (Foundry)

```bash
# Encode a function call
cast calldata "transfer(address,uint256)" 0xRecipient 1000000

# Encode with named function from ABI
cast calldata --abi path/to/abi.json "functionName" arg1 arg2
```

### Using Python (web3.py / eth-abi)

```python
from eth_abi import encode
from web3 import Web3

# Manual encoding
selector = Web3.keccak(text="transfer(address,uint256)")[:4].hex()
params = encode(['address', 'uint256'], ['0xRecipient', 1000000]).hex()
calldata = "0x" + selector + params
```

### Inline hex construction

For simple cases (ERC-20 transfer, approve), the agent can construct calldata directly:
- Function selector: first 4 bytes of keccak256 hash of the function signature
- Each parameter: ABI-encoded and left-padded to 32 bytes

Common selectors:
- `transfer(address,uint256)` → `0xa9059cbb`
- `approve(address,uint256)` → `0x095ea7b3`
- `balanceOf(address)` → `0x70a08231`
- `allowance(address,address)` → `0xdd62ed3e`

---

## Uniswap Integration Patterns

### With Uniswap/uniswap-ai skills

The Uniswap AI skills provide context for v4 pool operations. When composing with keypo-wallet:

**Swap execution flow:**
1. Uniswap skill determines: router address, pool parameters, calldata encoding
2. Check token allowance via RPC (`cast call`)
3. If approval needed, construct approve calldata
4. Construct swap calldata per Uniswap skill instructions
5. Execute via `keypo-wallet batch` with approve + swap calls

**Liquidity provision:**
1. Uniswap skill determines: position manager address, tick ranges, amounts
2. Approve both tokens for the position manager
3. Construct mint/addLiquidity calldata
4. Execute via `keypo-wallet batch` with approvals + mint

### With ETHSkills Uniswap building blocks

ETHSkills (`austintgriffith/ethskills`) provides verified contract addresses and interaction patterns. The building blocks skill covers Uniswap v2 and v3 router patterns. Use ETHSkills for address lookup and parameter guidance, then execute through keypo-wallet.

---

## Aave Integration Patterns

No official Aave SKILL.md exists yet. When using community skills or ETHSkills building blocks:

**Supply flow:**
1. Encode `approve(aavePoolAddress, amount)` for the supply token
2. Encode `supply(tokenAddress, amount, onBehalfOf, referralCode)` — referralCode is typically 0
3. Pipe both as a batch:
```bash
echo '[
  {"to": "<token>", "value": "0", "data": "<approve-calldata>"},
  {"to": "<aave-pool>", "value": "0", "data": "<supply-calldata>"}
]' | keypo-wallet batch --key agent-wallet --calls -
```

**Borrow flow:**
1. Must have collateral supplied first
2. Encode `borrow(tokenAddress, amount, interestRateMode, referralCode, onBehalfOf)`
3. `interestRateMode`: 1 = stable, 2 = variable
4. Execute: `keypo-wallet send --key agent-wallet --to <aave-pool> --data <borrow-calldata>`

**Supply + Borrow in one transaction:**
```bash
echo '[
  {"to": "<token>", "value": "0", "data": "<approve-calldata>"},
  {"to": "<aave-pool>", "value": "0", "data": "<supply-calldata>"},
  {"to": "<aave-pool>", "value": "0", "data": "<borrow-calldata>"}
]' | keypo-wallet batch --key agent-wallet --calls -
```

---

## ENS Integration Patterns

With OpenClaw ENS skills or ETHSkills:

**Resolve a name (read-only — no keypo-wallet needed):**
```bash
cast call 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e \
  "resolver(bytes32)(address)" $(cast namehash "example.eth") \
  --rpc-url https://eth.llamarpc.com
```

**Register or renew (write — use keypo-wallet):**
The ENS skill provides the controller address and registration calldata. Execute via:
```bash
keypo-wallet send --key <key> --to <ens-controller> --value <registration-fee-wei> --data <calldata>
```

---

## Cross-Chain Patterns

keypo-wallet currently targets Base Sepolia (chain ID 84532). The KeypoAccount contract address (`0x6d1566f9aAcf9c06969D7BF846FA090703A38E43`) is deterministic via CREATE2 and will be the same on all deployed chains.

To operate on a different chain, update the RPC and bundler URLs:

```bash
keypo-wallet config set network.rpc_url "https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY"
keypo-wallet config set network.bundler_url "https://api.pimlico.io/v2/421614/rpc?apikey=YOUR_KEY"
```

Or use environment variables per-command:
```bash
KEYPO_RPC_URL="https://arb-sepolia..." KEYPO_BUNDLER_URL="https://..." keypo-wallet send --key my-key --to 0x... --value 0
```

When using chain-specific skills (e.g., Arbitrum dApp skill), ensure the RPC and bundler are pointed at the correct chain before executing.

---

## Batch Call Patterns

All batch examples use the stdin pattern (`--calls -`). The agent constructs JSON in memory and pipes it directly — no temp files needed.

### Token swap (approve + swap)

```bash
echo '[
  {"to": "0xTokenAddress", "value": "0", "data": "0x095ea7b3<router-padded><amount-padded>"},
  {"to": "0xRouterAddress", "value": "0", "data": "0x<swap-calldata>"}
]' | keypo-wallet batch --key agent-wallet --calls -
```

### Multi-send ETH to multiple recipients

```bash
echo '[
  {"to": "0xRecipient1", "value": "1000000000000000", "data": "0x"},
  {"to": "0xRecipient2", "value": "2000000000000000", "data": "0x"},
  {"to": "0xRecipient3", "value": "500000000000000", "data": "0x"}
]' | keypo-wallet batch --key agent-wallet --calls -
```

### DeFi harvest + reinvest

```bash
echo '[
  {"to": "0xFarmContract", "value": "0", "data": "0x<claim-rewards-calldata>"},
  {"to": "0xRewardToken", "value": "0", "data": "0x095ea7b3<dex-router-padded><max-uint256>"},
  {"to": "0xDexRouter", "value": "0", "data": "0x<swap-rewards-to-deposit-token>"},
  {"to": "0xDepositToken", "value": "0", "data": "0x095ea7b3<farm-contract-padded><amount>"},
  {"to": "0xFarmContract", "value": "0", "data": "0x<deposit-calldata>"}
]' | keypo-wallet batch --key agent-wallet --calls -
```

---

## Debugging

```bash
# Enable verbose logging
keypo-wallet --verbose send --key my-key --to 0x... --value 0

# Check config
keypo-wallet config show

# Check wallet state
keypo-wallet wallet-info --key my-key

# List all keys
keypo-wallet list

# List all wallets with balances
keypo-wallet wallet-list
```

### Common issues

**"Insufficient funds for gas"** — The wallet needs ETH for gas, or configure a paymaster. Check balance with `keypo-wallet balance --key <key>`.

**"Nonce mismatch"** — A previous transaction may be pending. Wait for confirmation or check the bundler status.

**"Invalid signature"** — The P-256 key may not be registered as the account owner. Verify with `keypo-wallet wallet-info --key <key>` and check the on-chain owner.

**"Key policy requires user interaction"** — You're using a `passcode` or `bio` key in an automated context. Use `open` policy keys for agent workflows.