# Hermes x Keypo Checkout Demo

An AI agent (Hermes) asks to buy something, you approve from Touch ID or Apple Watch, and your credit card never leaves the hardware vault.

## Architecture

```
Hermes Agent ──→ keypo-approvald (daemon) ──→ keypo-signer vault exec ──→ checkout.js
     │              Unix socket                  Touch ID / Watch          Puppeteer
     │                                                                        │
     └── never sees card data                                    fills Shopify checkout
```

## Prerequisites

- macOS 14+ with Touch ID (Apple Silicon or T2)
- Hermes Agent installed (`hermes --version`)
- Node.js 18+
- Xcode Command Line Tools (for Swift)
- keypo-signer built and on PATH

## Quick Start

### 1. Build keypo-signer (if not already done)

```bash
cd keypo-signer
swift build -c release
cp .build/release/keypo-signer /usr/local/bin/keypo-signer
```

### 2. Build the approval daemon

```bash
cd demo/hermes-checkout/approvald
swift build
```

### 3. Install checkout dependencies

```bash
cd demo/hermes-checkout/checkout
npm install
```

### 4. Seed the vault

```bash
cd demo/hermes-checkout

# For testing (fake card 4242424242424242):
bash scripts/seed-vault.sh --test

# For real purchases:
bash scripts/seed-vault.sh
```

Notes:
- State codes must be uppercase (e.g., `CA` not `Ca`)
- Email is required for Shopify order confirmation
- All secrets stored in the `biometric` vault tier (Touch ID required)

### 5. Install Hermes tools and skills

```bash
# Copy tool into Hermes
cp hermes/tools/keypo_approve.py ~/.hermes/hermes-agent/tools/keypo_tool.py

# Copy the unified shopping skill and category description into Hermes
cp -R hermes/skills/keypo-shopping ~/.hermes/skills/keypo/keypo-shopping
cp hermes/skills/DESCRIPTION.md ~/.hermes/skills/keypo/DESCRIPTION.md
```

Then register the tool in Hermes:

**`~/.hermes/hermes-agent/model_tools.py`** — add to `_discover_tools()`:
```python
"tools.keypo_tool",
```

**`~/.hermes/hermes-agent/toolsets.py`** — add `"keypo_approve"` to `_HERMES_CORE_TOOLS` list, and add to `TOOLSETS`:
```python
"keypo": {
    "description": "Keypo secure checkout — purchase products via biometric-protected vault",
    "tools": ["keypo_approve"],
    "includes": []
},
```

**`~/.hermes/config.yaml`** — add `keypo` to your platform toolsets:
```yaml
platform_toolsets:
  cli:
  - keypo
  # ... other toolsets
  telegram:
  - hermes-telegram
  - keypo
```

### 6. Start the daemon

```bash
cd demo/hermes-checkout
./approvald/.build/debug/keypo-approvald \
  --socket /tmp/keypo-approvald.sock \
  --checkout-script "$(pwd)/checkout/checkout.js"
```

Leave running in a separate terminal.

### 7. Start Hermes and buy something

```bash
hermes
```

Then: "Buy me the Keypo Logo Art from shop.keypo.io"

Hermes will:
1. Browse the store and find the product
2. Show you a summary with price and ask for confirmation
3. Stage and confirm the purchase via `keypo_approve`
4. Touch ID prompt appears on your Mac
5. Checkout script fills Shopify checkout and places the order
6. Hermes reports the order confirmation

## Comparison Shopping (Catalog MCP)

Search across all Shopify stores and compare prices before buying. This is built into the unified `keypo-shopping` skill — no separate skill deployment needed.

### Setup

**1. Generate a Shopify Catalog API bearer token:**

```bash
curl --silent --request POST \
  --url 'https://api.shopify.com/auth/access_token' \
  -H 'Content-Type: application/json' \
  --data '{
    "client_id": "f1a93e954e5f9732dc1bdee1c4154ab5",
    "client_secret": "<your_client_secret>",
    "grant_type": "client_credentials"
  }' | jq .
```

Note the `access_token` and `expires_in` values. Token lasts ~24 hours; regenerate before each demo.

**2. Add the MCP server to `~/.hermes/config.yaml`:**

```yaml
mcp_servers:
  shopify_catalog:
    url: "https://discover.shopifyapps.com/global/mcp"
    headers:
      Authorization: "Bearer <paste_access_token_here>"
    tools:
      resources: false
      prompts: false
```

**3. Reload Hermes:**

Send `/reload-mcp` in Hermes, or restart. Verify with "What tools do you have?" — you should see `mcp_shopify_catalog_search_global_products` and `mcp_shopify_catalog_get_global_product_details`.

### Token Refresh

When the token expires (401 errors from Catalog MCP):
1. Re-run the curl command above to get a new `access_token`
2. Update the `Authorization` header in `~/.hermes/config.yaml`
3. Send `/reload-mcp` to Hermes or restart

### Demo Script

1. "I'm going to ask my agent to buy me cookies. I'm not telling it which store. It's going to search across every Shopify store in the world."
2. Prompt: "Buy me the best chocolate chip cookies you can find."
3. Hermes searches — one API call to Shopify's Catalog. Results from multiple stores in under a second.
4. Table presented — 3-4 stores compared with prices, ratings, per-unit costs.
5. Selection: "Go with the best value."
6. Confirmation — Hermes shows purchase summary. You say "yes."
7. Touch ID prompt appears on Mac. Approve.
8. Result — order placed (real card) or card decline (fake card).
9. Kicker: "My agent just searched every Shopify store, found the best deal, and bought it. It never saw my credit card."

## Profiles, Scheduled Shopping & Gifts

All built into the unified `keypo-shopping` skill. No separate deployment needed — the skill uses progressive disclosure to load reference files on demand.

### Usage

**Build a taste profile:**
```
You: Set up my shopping preferences
Hermes: [asks questions about food, categories, brands, budget — 1-2 per message]
Hermes: [shows 8-12 images for thumbs up/down style assessment]
Hermes: [presents profile summary, asks for confirmation]
```

**Set up weekly shopping:**
```
You: Start buying me stuff every Monday at 9am
Hermes: [confirms cron job created]
# Every Monday at 9am, Hermes sends a personalized 2-3 item shopping list via Telegram
# Reply "yes" to approve → Touch ID → checkout
```

**Set up gift reminders:**
```
You: Set up a gift profile for Mom. Her birthday is July 15.
Hermes: [questionnaire about Mom's preferences]
# 14 days before her birthday, Hermes sends gift ideas via Telegram
```

Profiles are stored in Hermes memory. They persist across sessions and drive all shopping recommendations.

## Skill Structure

All shopping capabilities are in a single unified skill (`keypo-shopping`) with progressive disclosure:

```
hermes/skills/keypo-shopping/
├── SKILL.md                    # Decision tree + core checkout procedure (~930 tokens)
├── references/
│   ├── comparison-shopping.md  # Multi-store price comparison
│   ├── batch-purchasing.md     # Buy multiple items in one session
│   ├── profiling.md            # Taste profile questionnaire
│   ├── scheduled-shopping.md   # Weekly recurring shopping lists
│   ├── gift-shopping.md        # Gift profiles + birthday reminders
│   ├── checkout-errors.md      # Error handling lookup table
│   └── vault-concepts.md       # Security explainer
└── assets/
    └── image-questionnaire-prompts.md  # Search queries for style assessment
```

SKILL.md loads on any shopping intent (~930 tokens). Reference files load on demand only when that specific flow is needed. Worst case is ~3,000 tokens — well under the 5,000 token ceiling.

Old individual skills are archived in `hermes/skills/archive/`.

## Telegram (Stage 2)

1. Create a bot via @BotFather in Telegram
2. Configure: `hermes gateway setup` (select Telegram, enter bot token + user ID)
3. Start gateway: `hermes gateway run`
4. Message your bot: "Buy me Keypo Logo Art from shop.keypo.io"
5. Touch ID prompts on your Mac; order confirmation arrives in Telegram

## Testing

```bash
cd demo/hermes-checkout

# Run all automated tests (no biometric needed):
bash tests/run-all.sh

# Run checkout.js directly with headed browser (for debugging):
echo '{"product_url":"https://shop.keypo.io/products/keypo-logo-art?variant=44740698996759","quantity":1,"max_price":1.15}' | \
  HEADLESS=false keypo-signer vault exec --allow '*' --reason "Test" -- node checkout/checkout.js
```

## Vault Secrets

| Secret | Description |
|--------|-------------|
| `CARD_NUMBER` | Credit card number |
| `CARD_EXP_MONTH` | Expiry month (2-digit) |
| `CARD_EXP_YEAR` | Expiry year (2 or 4-digit) |
| `CARD_CVV` | CVV |
| `CARD_NAME` | Cardholder name |
| `SHIP_FIRST_NAME` | Shipping first name |
| `SHIP_LAST_NAME` | Shipping last name |
| `SHIP_ADDRESS1` | Address line 1 |
| `SHIP_ADDRESS2` | Address line 2 (optional) |
| `SHIP_CITY` | City |
| `SHIP_STATE` | State code (uppercase, e.g., `CA`) |
| `SHIP_ZIP` | Postal code |
| `SHIP_COUNTRY` | Country code (e.g., `US`) |
| `SHIP_PHONE` | Phone number |
| `SHIP_EMAIL` | Email for order confirmation |

All secrets are stored in the `biometric` vault and require Touch ID to decrypt.

## Checkout Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Order placed (`ORDER_CONFIRMED:<number>`) |
| 2 | Price exceeds max (`PRICE_CHECK_FAILED`) |
| 3 | Product not found / OOS (`PRODUCT_ERROR`) |
| 4 | Checkout form error / decline (`CHECKOUT_ERROR`) |
| 5 | Missing env var / bad manifest (`CONFIG_ERROR`) |
| 6 | Navigation timeout (`NAV_ERROR`) |
