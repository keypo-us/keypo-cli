---
name: sneakerbot-purchase
description: Use when the user asks to buy a product from the test Shopify store.
  Orchestrates SneakerBot to complete a purchase with credit card details
  injected via keypo-signer vault exec (biometric policy — Touch ID required).
version: "0.1.0"
metadata:
  author: keypo-us
  requires: keypo-signer, Node 18, PostgreSQL
---

# SneakerBot Purchase Skill

Orchestrate a Shopify purchase via SneakerBot with credit card secrets injected at runtime from the keypo-signer vault. The agent never sees or handles card data — Touch ID acts as the human-in-the-loop approval.

**For vault usage rules, see `skills/keypo-signer/SKILL.md`.**

---

## Startup

Before running a purchase, ensure all services are up. Start them in order:

### 1. PostgreSQL

```bash
# Homebrew
brew services start postgresql@14

# Or Docker
docker compose -f demo/sneakerbot/docker-compose.yml up -d
```

### 2. SneakerBot API server

```bash
cd demo/sneakerbot/bot
nvm use 18
NODE_ENV=local node ./scripts/start-api-server.js &
```

Wait for the server to be ready:

```bash
curl -s http://localhost:8080/v1/tasks | jq .success
# Expect: true
```

### 3. Prerequisites check

```bash
# 1. Vault has card secrets in biometric tier
keypo-signer vault list
# Expect: CARD_NUMBER, NAME_ON_CARD, EXPIRATION_MONTH, EXPIRATION_YEAR, SECURITY_CODE in "biometric"
# Expect: PORT, DB_USERNAME, DB_PASSWORD, DB_NAME, DB_PORT, DB_HOST, NODE_ENV, STORE_PASSWORD in "open"

# 2. At least one address is seeded
curl -s http://localhost:8080/v1/addresses | jq 'length'
# Expect: >= 1
```

If vault secrets are missing, **tell the user to set up the vault** — do not attempt to store secrets yourself.

---

## Workflow

### 1. Check existing addresses

```bash
curl -s http://localhost:8080/v1/addresses | jq .
```

Use an existing address or create one if needed:

```bash
curl -s -X POST http://localhost:8080/v1/addresses \
  -H 'Content-Type: application/json' \
  -d '{"type":"shipping","first_name":"...","last_name":"...","address_line_1":"...","address_line_2":"","city":"...","state":"XX","postal_code":"...","country":"US","email_address":"...","phone_number":"..."}'
```

### 2. Create a task

```bash
curl -s -X POST http://localhost:8080/v1/tasks \
  -H 'Content-Type: application/json' \
  -d '{
    "site_id": 3,
    "url": "<product-url>",
    "shipping_address_id": <id>,
    "billing_address_id": <id>,
    "notification_email_address": "<email>"
  }'
```

- `site_id`: 3 = Shopify
- `size`: omit for single-variant products, or provide as string (e.g., `"10"`)
- Note the returned task `id`

### 3. Start the task via vault exec

```bash
demo/sneakerbot/run-with-vault.sh <TASK_ID>
```

This triggers `keypo-signer vault exec --env .env.vault-template` which will:
- Decrypt open-tier config (no auth needed)
- Decrypt biometric-tier card secrets (**Touch ID prompt appears for user**)
- Launch SneakerBot with all secrets injected

**Wait for the user to authenticate via Touch ID before proceeding.**

### 4. Monitor output

Watch stdout for SneakerBot status:
- `Navigating to URL` — browser launching
- `Store password page detected, bypassing...` — password gate
- `Attempting to add product to cart` — add to cart
- `Entering contact email` — checkout started
- `Entering card details` — payment fields
- `Clicking Pay now button` — submitting order
- `has completed` — **success**
- `has a checkout error` — **failure**, inspect browser

### 5. Report result

Tell the user whether the checkout succeeded or failed. If succeeded, note that they should check their email for the order confirmation.

---

## Forbidden Actions

These rules are **absolute** — violating them breaks the security model.

1. **Never call `vault get`** — this retrieves plaintext secrets. Use only `vault exec`.
2. **Never write secrets to files** — no `.env` files with real card values.
3. **Never inspect the subprocess environment** — don't try to read env vars from the vault exec child.
4. **Never populate the blank `CARD_*` fields** in `.env.vault-template` — they must remain blank.
5. **Never attempt to store vault secrets** — if secrets are missing, tell the user to set them up.
6. **Never log, echo, or print card values** in any command you construct.

See `skills/keypo-signer/SKILL.md` for the complete vault safety rules.

---

## Shutdown

After the user is done, tear down services in reverse order:

```bash
# 1. Stop the API server
lsof -ti:8080 | xargs kill

# 2. Stop PostgreSQL (Homebrew)
brew services stop postgresql@14

# Or stop PostgreSQL (Docker)
docker compose -f demo/sneakerbot/docker-compose.yml down
```

Only shut down when the user asks — they may want to run multiple purchases in a session.
