---
name: portfolio-tracker
description: Use when the user asks about token balances, what tokens a wallet holds, or wants a complete portfolio overview including ERC-20 tokens. Discovers all ERC-20 tokens and native token balances held by any EVM address using Alchemy's Portfolio API — one call returns everything. Works on both mainnets and testnets including Base Sepolia. Use this instead of manually checking individual token contracts or scraping block explorers. Also use when the user says "what tokens do I have", "show my portfolio", "what's in my wallet", "check my token balances", "what other tokens", or asks for token holdings beyond native ETH. Requires an Alchemy API key.
license: MIT
metadata:
  author: keypo-us
  version: "0.2.0"
  compatibility: Works on any EVM chain Alchemy supports, including testnets (Base Sepolia, Ethereum Sepolia, Arbitrum Sepolia, etc.).
---

# Portfolio Tracker — Token Discovery for Any EVM Wallet

Discover all token balances (native + ERC-20) for any EVM address in a single API call. Works on **mainnets and testnets** including Base Sepolia.

This skill is **read-only** — it discovers what a wallet holds but does not send transactions.

---

## Prerequisites

### Alchemy API key

An Alchemy API key is **required**. Check for it immediately:

```bash
echo $ALCHEMY_API_KEY
```

If empty, tell the user to set it in their shell environment. Do not ask them to paste the key in chat.

```
Please set your Alchemy API key as an environment variable.
Add this to your ~/.zshrc (or ~/.bashrc) and restart your terminal:

  export ALCHEMY_API_KEY="your-key-here"

Get a free API key at https://dashboard.alchemy.com/signup
Then re-run this command.
```

Do not proceed without the key.

---

## API Details

This skill uses Alchemy's **Portfolio API**, not the older Token API. One call returns native tokens and all ERC-20s together — no separate metadata calls needed.

- **Endpoint:** `https://api.g.alchemy.com/data/v1/$ALCHEMY_API_KEY/assets/tokens/balances/by-address`
- **Method:** POST
- **API key goes in the URL path**, not in a header.
- **Max 2 addresses and 5 networks per request.**

### Network slugs

| Chain | Slug | Chain ID |
|-------|------|----------|
| Ethereum | `eth-mainnet` | 1 |
| Base | `base-mainnet` | 8453 |
| Base Sepolia | `base-sepolia` | 84532 |
| Arbitrum | `arb-mainnet` | 42161 |
| Arbitrum Sepolia | `arb-sepolia` | 421614 |
| Optimism | `opt-mainnet` | 10 |
| Polygon | `polygon-mainnet` | 137 |
| Ethereum Sepolia | `eth-sepolia` | 11155111 |

---

## Querying Token Balances

### Single wallet, single chain

```bash
curl -s -X POST "https://api.g.alchemy.com/data/v1/$ALCHEMY_API_KEY/assets/tokens/balances/by-address" \
  -H 'Content-Type: application/json' \
  -d '{
    "addresses": [
      {
        "address": "<wallet-address>",
        "networks": ["base-sepolia"]
      }
    ],
    "includeNativeTokens": true,
    "includeErc20Tokens": true
  }'
```

### Response format

```json
{
  "data": {
    "tokens": [
      {
        "address": "0xWallet...",
        "network": "base-sepolia",
        "tokenAddress": null,
        "tokenBalance": "0x16b3bd933bca8"
      },
      {
        "address": "0xWallet...",
        "network": "base-sepolia",
        "tokenAddress": "0x036cbd53842c5426634e7929541ec2318f3dcf7e",
        "tokenBalance": "0x023cbca5"
      }
    ],
    "pageKey": null
  }
}
```

- `tokenAddress: null` means **native ETH** (or the chain's native token)
- `tokenAddress: "0x..."` means an **ERC-20 token**
- `tokenBalance` is a **hex string** — convert to human-readable using the token's decimals (18 for ETH/WETH, varies for others)

### Multiple wallets or chains

Pass up to 2 addresses and 5 networks per request:

```bash
curl -s -X POST "https://api.g.alchemy.com/data/v1/$ALCHEMY_API_KEY/assets/tokens/balances/by-address" \
  -H 'Content-Type: application/json' \
  -d '{
    "addresses": [
      {
        "address": "0xWallet1...",
        "networks": ["base-sepolia"]
      },
      {
        "address": "0xWallet2...",
        "networks": ["base-sepolia"]
      }
    ],
    "includeNativeTokens": true,
    "includeErc20Tokens": true
  }'
```

**If querying more than 2 wallets, batch them into sequential requests of 2.** Do not parallelize — Alchemy rate limits will cause failures. Add `sleep 0.5` between batches.

---

## Getting Token Metadata

The Portfolio API returns raw hex balances and contract addresses but not token names or decimals. For each discovered token, fetch metadata with the Token API:

```bash
curl -s -X POST "https://base-sepolia.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "alchemy_getTokenMetadata",
    "params": ["<token-contract-address>"]
  }'
```

Returns: `{ "name": "USD Coin", "symbol": "USDC", "decimals": 6, "logo": "..." }`

**For native tokens** (`tokenAddress: null`), no metadata call is needed — it's always ETH with 18 decimals on EVM chains.

---

## Known Tokens Not Found by Auto-Discovery

The Portfolio API may not discover all tokens. **Predeploy contracts on OP Stack chains** (Base, Optimism, etc.) are not indexed by Alchemy's auto-discovery. WETH is the most common example.

**Always check these known tokens explicitly** after the main query by calling the Token API:

```bash
curl -s -X POST "https://base-sepolia.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "alchemy_getTokenBalances",
    "params": ["<wallet-address>", ["0x4200000000000000000000000000000000000006"]]
  }'
```

| Chain | Token | Predeploy Address | Decimals |
|-------|-------|-------------------|----------|
| Base / Base Sepolia | WETH | `0x4200000000000000000000000000000000000006` | 18 |
| Optimism | WETH | `0x4200000000000000000000000000000000000006` | 18 |

**Merge results** from the predeploy check into the Portfolio API results before presenting. Deduplicate by `tokenAddress` — if a token appears in both, use the Portfolio API result.

---

## Converting Hex Balances

All balances are hex strings. Convert using python:

```python
hex_balance = "0x16b3bd933bca8"
decimals = 18  # ETH/WETH
balance = int(hex_balance, 16) / (10 ** decimals)
print(f"{balance:.6f}")  # 0.000399
```

Common decimals: ETH/WETH = 18, USDC = 6, USDT = 6, DAI = 18.

---

## Complete Example

Query a wallet for all tokens including WETH predeploy:

```bash
ADDR="<wallet-address>"
NETWORK="base-sepolia"

# Step 1: Portfolio API for native + discovered ERC-20s
PORTFOLIO=$(curl -s -X POST "https://api.g.alchemy.com/data/v1/$ALCHEMY_API_KEY/assets/tokens/balances/by-address" \
  -H 'Content-Type: application/json' \
  -d "{\"addresses\":[{\"address\":\"$ADDR\",\"networks\":[\"$NETWORK\"]}],\"includeNativeTokens\":true,\"includeErc20Tokens\":true}")

# Step 2: Explicit check for WETH predeploy
WETH=$(curl -s -X POST "https://$NETWORK.g.alchemy.com/v2/$ALCHEMY_API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"alchemy_getTokenBalances\",\"params\":[\"$ADDR\",[\"0x4200000000000000000000000000000000000006\"]]}")

# Step 3: Parse and display
echo "$PORTFOLIO" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tokens = data.get('data', {}).get('tokens', [])
for t in tokens:
    addr = t['tokenAddress'] or 'native (ETH)'
    bal = int(t['tokenBalance'], 16)
    if addr == 'native (ETH)':
        print(f'  ETH: {bal / 1e18:.6f}')
    else:
        print(f'  {addr}: {bal} (raw)')
"

echo "$WETH" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('result', {}).get('tokenBalances', []):
    bal = int(t['tokenBalance'], 16)
    if bal > 0:
        print(f'  WETH: {bal / 1e18:.6f}')
"
```

---

## Presenting Results

### Multi-wallet overview (most common case)

When the user asks for a portfolio overview across multiple wallets, present **one consolidated table** — not individual cards per wallet. This is the preferred format:

```
Base Sepolia Wallet Overview

  Name                       Address        Policy     ETH        USDC       WETH
  ─────────────────────────────────────────────────────────────────────────────────────
  test-open                  0xC660...Bc13  open       0.000999   —          —
  dave-test-key              0xD88E...eb80  biometric  0.003399   —          —
  dave-testkey-passcode      0x60e8...B959  passcode   0.001899   —          —
  dave-bio-test-key          0x63BC...35EC  biometric  0.001799   —          —
  dave-unified-test-key      0xEE38...5e49  open       0.001299   —          —
  dave-unified-test-key-bio  0xC702...CcE4  biometric  0.000399   37.534885  0.000100
  ─────────────────────────────────────────────────────────────────────────────────────
  Total                                                0.009794   37.534885  0.000100
```

Key rules for the consolidated table:
- One row per wallet, all wallets in a single table
- Include name, truncated address, signing policy, and all token balances as columns
- Use `—` for tokens a wallet doesn't hold
- Add a totals row at the bottom
- Only add token columns that at least one wallet holds (don't show empty columns)
- Do NOT create separate info cards, tables, or sections per wallet

### Single wallet query

When the user asks about one specific wallet, a compact format is fine:

```
dave-unified-test-key-bio (0xC702...CcE4) — Base Sepolia, biometric

  Token       Balance         Contract
  ─────────────────────────────────────────────────────
  ETH         0.000399        (native)
  WETH        0.000100        0x4200...0006
  USDC        37.534885       0x036C...CF7e
  ─────────────────────────────────────────────────────
```

### General rules

- Always include native ETH alongside ERC-20 tokens.
- If a token has a non-zero balance but you can't resolve its name via `alchemy_getTokenMetadata`, show the contract address as the identifier.
- Use `eth_getBalance` via the Alchemy RPC for native ETH if needed as a fallback.

---

## Notes

- **Testnet support** is a key advantage. Use for Base Sepolia, Ethereum Sepolia, Arbitrum Sepolia, etc.
- Alchemy does not return USD prices on testnets. For mainnet price data, use a price API.
- **Query wallets sequentially, not in parallel.** Max 2 addresses per request. Add `sleep 0.5` between requests when querying more than 2 wallets.
- **Always check predeploy tokens explicitly** (especially WETH on OP Stack chains) — they are not found by auto-discovery.
- Use `pageKey` from the response to paginate if a wallet holds many tokens.
