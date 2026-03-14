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

# Copy skills into Hermes
mkdir -p ~/.hermes/skills/keypo/keypo-checkout ~/.hermes/skills/keypo/keypo-vault
cp hermes/skills/keypo-checkout.md ~/.hermes/skills/keypo/keypo-checkout/SKILL.md
cp hermes/skills/keypo-vault.md ~/.hermes/skills/keypo/keypo-vault/SKILL.md
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
