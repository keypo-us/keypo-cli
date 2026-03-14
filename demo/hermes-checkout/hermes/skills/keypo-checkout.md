---
name: keypo-checkout
description: "Buy products from Shopify stores using the keypo_approve tool. Handles the full purchase flow: find product, confirm with user, then call keypo_approve to stage and execute the order with biometric approval. Card data stays in the hardware vault — the agent never sees it."
version: 1.0.1
author: Keypo
metadata:
  hermes:
    tags: [shopping, checkout, purchase, shopify, keypo, payment, e-commerce]
    category: keypo
    requires_toolsets: [keypo]
    requires_tools: [keypo_approve]
---

# Keypo Checkout — Purchase Workflow

Buy products from Shopify stores using the `keypo_approve` tool. The agent never handles card data — all payment is done through biometric-protected hardware vault.

**The ONLY tool you need is `keypo_approve`.** Do NOT try to fill checkout forms with browser tools.

## When to Use

Use this skill when the user asks you to **buy something**, make a purchase, or order a product. The `keypo_approve` tool handles all payment securely.

## Procedure

Follow these steps **in order**. Do not skip steps.

### 1. Find the Product
Browse to the product on a Shopify store. The user may provide a URL directly.

### 2. Verify It's Shopify
Check for `/products/` in the URL path. **Non-Shopify stores are NOT supported** — tell the user.

### 3. Get the Product URL
Must be format: `https://<store>/products/<handle>` (include `?variant=<id>` if applicable)

### 4. Read the Price
Extract the product price from the page.

### 5. Set max_price
`max_price` = displayed price × 1.15 (15% buffer for tax/shipping).

### 6. Present Summary and Ask for Approval (MANDATORY)
Show the user: product name, store, price, max_price, quantity.
**Ask: "Would you like me to proceed?"**
Do NOT call any tools until the user says yes.

### 7. On "Yes" — Two keypo_approve Calls Back-to-Back

**Call 1 — Stage the request:**
```
keypo_approve(
    action="request",
    vault_label="biometric",
    bio_reason="Approve purchase: <product name>, $<price>",
    manifest={"product_url": "<URL>", "quantity": 1, "max_price": <max_price>}
)
```
This returns a `request_id`. Save it.

**Call 2 — Confirm (triggers Touch ID on user's device):**
```
keypo_approve(
    action="confirm",
    request_id="<request_id from Call 1>"
)
```

CRITICAL: Call 1 and Call 2 must be **sequential** (NOT parallel). Call 2 depends on the request_id from Call 1. The confirm call triggers the biometric prompt on the user's Mac/Watch. Do NOT wait for user input between the two calls. The confirm may take 1-5 minutes (biometric + checkout).

### 8. On "No" — Cancel
Call `keypo_approve(action="cancel", request_id="...")` if already staged, or do nothing.

### 9. Report the Result
- **Success** (stdout has `ORDER_CONFIRMED:`): Share the confirmation number.
- **Price check failed** (stderr has `PRICE_CHECK_FAILED`): Report actual vs max, offer retry.
- **Card declined** (stderr has `CHECKOUT_ERROR`): Report decline, don't speculate why.
- **Biometric cancelled** (error has `cancelled`): Report that user cancelled.
- **Other errors**: Report the error. Do NOT retry automatically.

## Pitfalls

- **NEVER** fill checkout forms with browser tools — only use `keypo_approve`
- **NEVER** ask for card details — they're in the vault
- **NEVER** include card data in manifest, messages, or tool calls
- **ALWAYS** confirm with user before staging (Step 6)
- The two `keypo_approve` calls in Step 7 must be sequential, not parallel
