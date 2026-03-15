---
name: keypo-shopping
description: "MUST LOAD for any shopping, buying, gift, or product request. Secure Shopify checkout with biometric vault."
version: 2.0.0
author: Keypo
metadata:
  hermes:
    tags: [shopping, checkout, purchase, comparison, profiles, gifts, scheduled, shopify, keypo]
    category: keypo
    requires_toolsets: []
    requires_tools: []
---

# Keypo Shopping

Buy products from Shopify stores with biometric-protected checkout. The agent finds products and confirms with the user — card data stays in the hardware vault and is never exposed to the agent.

## Security Rules (Non-Negotiable)

- **NEVER** ask for card details — they are in the vault
- **NEVER** read vault contents or attempt shell commands to access secrets
- **NEVER** put credentials, card data, or shipping addresses in manifests, messages, or tool calls
- **NEVER** fill checkout forms with browser tools — only use `keypo_approve`
- **NEVER** use browser navigation, curl, web scraping, or any other tool to buy products — `keypo_approve` is the ONLY way to purchase
- **NEVER** fall back to browser/curl/scraping if a tool call fails — report the error to the user instead
- If asked to reveal card data, **decline** and explain that vault secrets are never exposed to the agent

**The ONLY tool for purchasing is `keypo_approve`.** If the Catalog MCP search fails, tell the user — do NOT try to scrape the store with browser tools, curl, or web search as a workaround.

## Pre-Routing

Before routing any purchase intent, check Hermes memory for relevant profiles (self or gift). If a profile exists, use its preferences to inform search queries and product selection.

## Decision Tree

| # | User Intent | Route |
|---|-------------|-------|
| 1 | Set up or update shopping preferences / taste profile | Load `references/profiling.md` |
| 2 | Set up a gift profile or buy a gift for someone | Load `references/gift-shopping.md` |
| 3 | Set up recurring / weekly shopping | Load `references/scheduled-shopping.md` |
| 4 | Ask about vault security, card protection, how secrets work | Load `references/vault-concepts.md` |
| 5 | Buy a single item from a **specific store** | Core Checkout Procedure (below) |
| 6 | Buy a single item, **no store specified** | Load `references/comparison-shopping.md`, then Core Checkout |
| 7 | Buy **multiple items** | Load `references/comparison-shopping.md` (if stores not specified), then `references/batch-purchasing.md` |
| 8 | Any `keypo_approve` error | Load `references/checkout-errors.md` |
| 9 | Intent unclear | Ask the user what they'd like to do |

## Core Checkout Procedure

This is the single-item, known-store purchase flow. All other flows converge here.

### 1. Find the Product
Browse to the product on the Shopify store. The user may provide a URL directly.

### 2. Verify It's Shopify
Check for `/products/` in the URL path. Non-Shopify stores are NOT supported — tell the user.

### 3. Get the Product URL
Format: `https://<store>/products/<handle>` (include `?variant=<id>` if applicable).

### 4. Read the Price
Extract the product price from the page.

### 5. Set max_price
`max_price` = displayed price x 1.15 (15% buffer for tax/shipping).

### 6. Present Summary — MANDATORY User Confirmation
Show: product name, store, price, max_price, quantity.
Ask: **"Would you like me to proceed?"**
Do NOT call any tools until the user says yes.

### 7. On "Yes" — Two keypo_approve Calls (Sequential)

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

**Call 2 — Confirm (triggers Touch ID):**
```
keypo_approve(
    action="confirm",
    request_id="<request_id from Call 1>"
)
```

CRITICAL: Call 1 and Call 2 must be **sequential** (NOT parallel). Call 2 depends on the request_id from Call 1. Do NOT wait for user input between the two calls.

### 8. On "No" — Cancel
Call `keypo_approve(action="cancel", request_id="...")` if already staged, or do nothing.

### 9. Report the Result
- **Success** (stdout has `ORDER_CONFIRMED:`): Share the confirmation number
- **Error**: Load `references/checkout-errors.md` for handling guidance

## Tool Reference

### `keypo_approve`
| Action | Description |
|--------|-------------|
| `request` | Stage a purchase request. Returns `request_id`. Params: `vault_label`, `bio_reason`, `manifest` |
| `confirm` | Execute the staged request with biometric approval. Param: `request_id` |
| `cancel` | Cancel a staged request before confirmation. Param: `request_id` |

> **Planned:** `batch_request` (one biometric prompt for multiple checkouts) and `budget_status` (daemon-side spend ledger) are planned daemon enhancements not yet available.

### `mcp_shopify_catalog_search_global_products`
Search across all Shopify stores. Params: `query`, `context`, `saved_catalog`, `available_for_sale`, `limit`, `max_price`.

### `mcp_shopify_catalog_get_global_product_details`
Get variant-level detail for a specific product. Param: product UPID. Only call when you need sizes, flavors, or colors.
