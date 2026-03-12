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

## Prerequisites Check

Before starting, verify:

```bash
# 1. Vault has card secrets in biometric tier
keypo-signer vault list
# Expect: CARD_NUMBER, NAME_ON_CARD, EXPIRATION_MONTH, EXPIRATION_YEAR, SECURITY_CODE in "biometric"
# Expect: PORT, DB_USERNAME, DB_PASSWORD, DB_NAME, DB_PORT, DB_HOST, NODE_ENV, STORE_PASSWORD in "open"

# 2. SneakerBot API is reachable
curl -s http://localhost:8080/v1/tasks | jq .success
# Expect: true

# 3. At least one address is seeded
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
