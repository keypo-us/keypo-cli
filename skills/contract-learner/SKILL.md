---
name: contract-learner
description: Use when a user provides a smart contract address and wants to generate a reusable SKILL.md file for interacting with that contract through keypo-wallet. Analyzes verified contracts by fetching their ABI, categorizes functions, and outputs a complete agent skill file with verified addresses, function signatures, calldata encoding instructions, and keypo-wallet execution commands. Also use when a user says "make a skill for this contract", "generate a skill", or "I want to interact with this contract using keypo-wallet". Requires Foundry (cast) to be installed.
license: MIT
metadata:
  author: keypo-us
  version: "0.1.0"
  compatibility: Requires Foundry (cast). Works with any EVM chain that has an Etherscan-compatible block explorer.
---

# Contract Learner — SKILL.md Generator for keypo-wallet

Given a deployed smart contract address, this skill generates a complete, portable SKILL.md file that teaches any agent how to interact with that contract using keypo-wallet as the execution backend.

**This skill does not execute transactions itself.** It produces SKILL.md files that do.

---

## Prerequisites — Check These First

Before doing anything else, resolve these two dependencies. Do not proceed until both are confirmed.

### Locate cast

Foundry's `cast` is required. Check for it in this order:

```bash
# Check PATH first
which cast 2>/dev/null || \
# Foundry's default install location
ls ~/.foundry/bin/cast 2>/dev/null || \
echo "CAST_NOT_FOUND"
```

If found at `~/.foundry/bin/cast`, use the full path for all commands in this skill (e.g., `~/.foundry/bin/cast call ...`). Set a variable for convenience:

```bash
CAST=$(which cast 2>/dev/null || echo ~/.foundry/bin/cast)
```

If not found at either location, tell the user to install Foundry: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

### Verify Etherscan API key

An Etherscan API key is **required** to fetch contract ABIs. Check for it immediately:

```bash
echo $ETHERSCAN_API_KEY
```

If the variable is set, use it silently — do not print it or include it in any output.

If empty, **tell the user to set it in their shell environment.** Do not ask them to paste the key into the chat — keys entered in conversation are stored in chat history and may be synced or logged. Instead, instruct them:

```
Please set your Etherscan API key as an environment variable before proceeding.
Add this to your ~/.zshrc (or ~/.bashrc) and restart your terminal:

  export ETHERSCAN_API_KEY="your-key-here"

Free keys are available at https://etherscan.io/myapikey and work across all chains.
Then re-run this command.
```

Do not proceed without the key. Do not attempt to fetch ABIs without a key — it will fail.

---

## Input

The user provides:
- **Contract address** — `0x...` (42 characters, required)
- **Chain** — chain name or ID (required)
- **Skill name** — lowercase hyphenated name for the output skill (optional, will be inferred from contract name)

---

## Process

### 1. Resolve the chain

Map the user's chain input to a chain ID and RPC URL:

| Chain | Chain ID | RPC URL | Explorer API Base |
|-------|----------|---------|-------------------|
| Ethereum | 1 | `https://eth.llamarpc.com` | `https://api.etherscan.io/v2/api?chainid=1` |
| Base | 8453 | `https://mainnet.base.org` | `https://api.etherscan.io/v2/api?chainid=8453` |
| Base Sepolia | 84532 | `https://sepolia.base.org` | `https://api.etherscan.io/v2/api?chainid=84532` |
| Arbitrum | 42161 | `https://arb1.arbitrum.io/rpc` | `https://api.etherscan.io/v2/api?chainid=42161` |
| Optimism | 10 | `https://mainnet.optimism.io` | `https://api.etherscan.io/v2/api?chainid=10` |
| Polygon | 137 | `https://polygon-rpc.com` | `https://api.etherscan.io/v2/api?chainid=137` |
| Sepolia | 11155111 | `https://rpc.sepolia.org` | `https://api.etherscan.io/v2/api?chainid=11155111` |

### 2. Fetch the ABI

**Only use the Etherscan API to fetch ABIs. Never try to scrape or fetch block explorer web pages (basescan.org, etherscan.io, etc.) — they return 403 errors and HTML, not ABI data.**

Use `cast interface` with the API key:

```bash
$CAST interface <address> --chain <chain-id> --etherscan-api-key $ETHERSCAN_API_KEY
```

If `cast interface` fails, fall back to the Etherscan V2 REST API:

```bash
curl -s "https://api.etherscan.io/v2/api?chainid=<chain-id>&module=contract&action=getabi&address=<address>&apikey=$ETHERSCAN_API_KEY"
```

The response JSON has `result` containing the ABI as a JSON string. Parse it to get the function list.

**If the contract is not verified:** Stop and tell the user. You cannot generate a skill for an unverified contract. They can provide the ABI manually as a JSON file.

**If the contract is a proxy:** Detect proxy patterns (implementation(), upgradeTo()). Follow the proxy to the implementation:

```bash
$CAST call <proxy-address> "implementation()(address)" --rpc-url <rpc-url>
$CAST interface <implementation-address> --chain <chain-id> --etherscan-api-key $ETHERSCAN_API_KEY
```

Use the proxy address in the generated skill (that's what users send transactions to) but note it's a proxy in the skill's description.

### 3. Gather contract metadata

Before generating the skill, collect these details using read calls:

```bash
# For tokens — try these, they may revert on non-token contracts
$CAST call <address> "name()(string)" --rpc-url <rpc-url>
$CAST call <address> "symbol()(string)" --rpc-url <rpc-url>
$CAST call <address> "decimals()(uint8)" --rpc-url <rpc-url>

# Verify the contract has code deployed
$CAST code <address> --rpc-url <rpc-url>
```

If name/symbol return values, this is likely a token contract. Include the decimals value in the generated skill — this is critical for correct amount encoding.

### 4. Categorize functions

From the ABI, sort functions into three groups:

- **Write functions** — not `view` or `pure`, these require keypo-wallet to execute
- **Read functions** — `view` or `pure`, these use `cast call` directly
- **Payable functions** — subset of write functions that accept ETH, require `--value` flag

### 5. Generate the SKILL.md

Produce a SKILL.md file following the output template below. Replace all `<placeholders>` with actual values from the contract analysis. Remove any sections that don't apply (e.g., remove the Payable section if there are no payable functions).

Write the file to `./<skill-name>/SKILL.md`.

---

## Output Template

The generated SKILL.md must follow this structure exactly. This ensures consistency across all generated skills and compatibility with keypo-wallet.

````markdown
---
name: <skill-name>
description: Interact with <contract-name> (<symbol-if-token>) at <address> on <chain-name>. <one-sentence description of what the contract does based on its functions>. Use with keypo-wallet for transaction execution — use `cast calldata` to encode function calls and pipe to `keypo-wallet send` or `keypo-wallet batch`.
license: MIT
metadata:
  author: auto-generated by contract-learner
  version: "1.0.0"
  source-contract: <address>
  chain: <chain-name>
  chain-id: <chain-id>
  generated: <YYYY-MM-DD>
---

# <Contract Name> (<chain-name>)

| Field | Value |
|-------|-------|
| Address | `<address>` |
| Chain | <chain-name> (Chain ID: <chain-id>) |
| Type | <token / protocol / proxy — inferred from functions> |
| Decimals | <decimals — only if token> |
| Symbol | <symbol — only if token> |
| RPC | `<rpc-url>` |

**Auto-generated from verified ABI.** Do not modify the address or function signatures.

---

## Read Functions

Use `cast call` — no wallet needed, no gas cost.

### <function-name>

```bash
cast call <address> "<signature>(<return-types>)" <arg-placeholders> --rpc-url <rpc-url>
```

<Repeat for each read function>

---

## Write Functions

Encode calldata with `cast calldata`, then execute via keypo-wallet.

### <function-name>

```bash
CALLDATA=$(cast calldata "<signature>" <arg-placeholders>)
keypo-wallet send --key <key-name> --to <address> --data $CALLDATA
```

<If payable, add: `# This function is payable — add --value <wei> to send ETH`>
<Add verification step: show the read function to confirm the result>

<Repeat for each write function>

---

## Common Patterns

<Include this section only if the contract has functions that naturally compose>

### Approve + <Action>

```bash
APPROVE_DATA=$(cast calldata "approve(address,uint256)" <this-contract-address> <amount>)
ACTION_DATA=$(cast calldata "<action-signature>" <args>)

echo "[
  {\"to\": \"<token-address>\", \"value\": \"0\", \"data\": \"$APPROVE_DATA\"},
  {\"to\": \"<address>\", \"value\": \"0\", \"data\": \"$ACTION_DATA\"}
]" | keypo-wallet batch --key <key-name> --calls -
```

---

## Amount Encoding

<Include this section only for token contracts>

This token uses **<decimals> decimals**. Always convert human-readable amounts:

| Human Amount | Raw Amount |
|-------------|------------|
| 1.0 | <10^decimals> |
| 0.01 | <10^(decimals-2)> |
| 100 | <100*10^decimals> |

To transfer 1.0 <symbol>:

```bash
CALLDATA=$(cast calldata "transfer(address,uint256)" <recipient> <10^decimals>)
keypo-wallet send --key <key-name> --to <address> --data $CALLDATA
```
````

---

## Rules for Generation

1. **Include only functions from the actual ABI.** Never add functions that aren't in the contract.

2. **Always hardcode the verified contract address.** The generated skill must contain the exact address — never let the consuming agent guess or substitute addresses.

3. **Include the chain ID and RPC URL.** The generated skill must be chain-specific. If the same contract exists on multiple chains, generate separate skills or include a chain table.

4. **For token contracts, always include the Amount Encoding section.** This prevents the most common agent error — sending wrong amounts.

5. **Use `cast calldata` for encoding, not manual hex.** The consuming agent runs `cast calldata` at execution time. This keeps generated skills readable and correct.

6. **For proxy contracts, note it in the description** but use the proxy address (not the implementation) for all execution commands.

7. **Group related functions.** If the contract has approve + transferFrom, show the batched pattern. If it has deposit + withdraw, group them.

8. **Omit admin-only functions** like `onlyOwner`, `renounceOwnership`, `upgradeTo` unless the user specifically asks for them.

9. **Include verification steps.** After every write function, show the corresponding read function to check the result (e.g., after `transfer`, show `balanceOf`).

10. **Test the generated skill before saving.** Run at least one read function to verify the address and RPC are working:
    ```bash
    $CAST call <address> "<simplest-read-function>" --rpc-url <rpc-url>
    ```
    If this fails, the generated skill is broken — fix before writing to disk.

---

## After Generation

1. Write the file to `./<skill-name>/SKILL.md`
2. Print a summary: skill name, contract address, chain, number of read/write/payable functions
3. Run one read function to verify the skill works
4. Show the user how to install it:
   ```
   # Use in current project (Claude Code)
   cp -r ./<skill-name> .claude/skills/

   # Or add to keypo-wallet's skills directory
   cp -r ./<skill-name> skills/

   # Or publish to GitHub for npx skills add
   # Push the <skill-name>/ folder to a repo, then:
   # npx skills add <owner>/<repo> --skill <skill-name>
   ```
