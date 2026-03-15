---
name: keypo-comparison-shop
description: "Compare prices across multiple Shopify stores using the Shopify Catalog API and buy from the best option. Uses search_global_products to find products, presents a comparison table, and hands off to keypo-checkout for purchase."
version: 1.0.0
author: Keypo
metadata:
  hermes:
    tags: [shopping, comparison, price-comparison, shopify, keypo, catalog, e-commerce]
    category: keypo
    requires_toolsets: [keypo]
    requires_tools: [keypo_approve, mcp_shopify_catalog_search_global_products]
---

# Keypo Comparison Shopping — Multi-Store Price Comparison

Search across all Shopify stores using the Catalog API, compare prices, and buy from the best option. Card data stays in the hardware vault — the agent never sees it.

**Tools used:** `mcp_shopify_catalog_search_global_products`, `mcp_shopify_catalog_get_global_product_details`, and `keypo_approve` (for checkout).

## When to Use

Use this skill when the user asks to buy a product **without specifying a particular store**, or explicitly asks for the best price / to compare options.

Trigger phrases:
- "Buy me the cheapest..."
- "Find me the best deal on..."
- "Compare prices for..."
- "Where's the cheapest place to get..."
- "Buy me [product]" (no store specified) — **default to comparison mode**

Do **NOT** use when the user names a specific store: "Buy me cookies from shop.keypo.io" goes directly to `keypo-checkout`.

## Procedure

Follow these steps **in order**. Do not skip steps.

### 1. Parse the Product Request

Extract from the user's message:
- Product type / description
- Quantity (default 1)
- Brand or flavor preferences
- Constraints (organic, gluten-free, etc.)
- Price limits (if mentioned)

### 2. Query the Catalog MCP

Call `mcp_shopify_catalog_search_global_products` with:
- `query`: the product description (e.g., "chocolate chip cookies")
- `context`: relevant buyer context (e.g., "looking for artisan cookies, gift-quality")
- `saved_catalog`: `01kkqvbgwy7re02m7qb4524ar9`
- `available_for_sale`: `true`
- `limit`: `10`
- `max_price`: include if the user mentioned a budget

Do NOT pass `ships_to` — it's already baked into the saved catalog config (US).

One call is usually sufficient. Don't over-query.

### 3. Filter and Present Results

After receiving results, you MUST do the following — no exceptions:

1. Remove out-of-stock items (`availableForSale: false`)
2. Remove duplicates
3. If user specified preferences, filter to matches
4. **Keep only the top 5.** Discard the rest. Do NOT show more than 5.
5. If only 1 result, skip the table — say "I only found this at one store" and go to step 6.
6. Save each product's `onlineStoreUrl` internally (you need it for checkout) but do NOT show URLs to the user.

**Now present the results using this EXACT format. Copy it literally, filling in the brackets:**

I found [product] at [N] Shopify stores. Here are the top [3-5]:

1. [Store Name] — [Product Title]
   $XX.XX for [quantity/size] ($X.XX/unit) | Rating: X.X/5 (N reviews)

2. [Store Name] — [Product Title]
   $XX.XX for [quantity/size] ($X.XX/unit) | Rating: X.X/5 (N reviews)

3. [Store Name] — [Product Title]
   $XX.XX for [quantity/size] ($X.XX/unit) | Rating: X.X/5 (N reviews)

Prices don't include shipping or tax.
Best value: #[N] ([Store Name]) — [one specific reason, e.g., "cheapest per unit at $1.67"]

Which one should I buy? Or should I go with the best value?

**Mandatory format rules:**
- Show 3 to 5 options. NEVER more than 5. NEVER.
- End with EXACTLY ONE "Best value: #N" line. Pick ONE winner. Not two. Not "X or Y."
- Compute per-unit price if pack sizes differ. Show as ($X.XX/unit). Base best value on per-unit cost.
- Do NOT show URLs, store domains, or links. You have them internally.
- Do NOT add emojis, extra headers, descriptions, or commentary between items.
- Do NOT add a "best quality" line. Only "Best value."
- Ratings are optional — only show if available.

### 4. Get Product Details (If Needed)

Only if you need variant-level detail (sizes, flavors, colors), call `mcp_shopify_catalog_get_global_product_details` with the product's UPID. Usually not needed.

### 5. Wait for User Selection

### 5. Wait for User Selection

The user responds with:
- A number ("2") or store name ("buy from Levain") → proceed to step 6
- "cheapest" / "best value" / "go with your recommendation" → select the flagged best value, proceed to step 6
- "none" / "nevermind" → acknowledge and stop. Do NOT call any tools.
- A follow-up question ("tell me more about #2", "any of these organic?") → answer, then re-ask for selection

### 6. Extract the Product URL

The selected product's `onlineStoreUrl` from the API response becomes the `product_url`.

**URL parameter handling:** The `onlineStoreUrl` includes query params like `?variant=XXXX&_gsid=YYYY`.
- Keep the full URL including `?variant=...` (pre-selects the correct variant)
- The `_gsid` param is Shopify analytics tracking — keep it unless the checkout script has issues with it
- If checkout fails due to URL params, strip `_gsid` first (keep `?variant=...`), then strip everything after `/products/<handle>` if still failing

**CRITICAL:** Use `onlineStoreUrl`, NOT `checkoutUrl`. The `checkoutUrl` is a Shopify cart permalink that bypasses the product page and is NOT compatible with the checkout script.

### 7. Hand Off to keypo-checkout

From this point, follow the standard `keypo-checkout` procedure:

1. Set `max_price` = displayed price + 15% buffer (for tax/shipping)
2. Present purchase summary to user:
   - Product name, store, price, max_price, quantity
   - **Ask: "Would you like me to proceed?"**
3. On "yes" — make the two `keypo_approve` calls:

**Call 1 — Stage:**
```
keypo_approve(
    action="request",
    vault_label="biometric",
    bio_reason="Approve purchase: <product name> from <store>, $<price>",
    manifest={"product_url": "<onlineStoreUrl>", "quantity": <N>, "max_price": <max_price>}
)
```

**Call 2 — Confirm (triggers Touch ID):**
```
keypo_approve(
    action="confirm",
    request_id="<request_id from Call 1>"
)
```

Calls must be **sequential** (Call 2 depends on request_id from Call 1).

4. Report the result:
   - **Success** (`ORDER_CONFIRMED:`): Share the confirmation number
   - **Price check failed** (`PRICE_CHECK_FAILED`): Explain that shipping/tax pushed the total past max_price. **Offer to try the next best option from the comparison table** — retain the comparison context, don't re-search
   - **Card declined** (`CHECKOUT_ERROR`): Report the decline
   - **Biometric cancelled** (`cancelled`): Report that user cancelled

## Pitfalls

- **`onlineStoreUrl` is the key output, NOT `checkoutUrl`.** The checkout script navigates to the product page, adds to cart, and proceeds through guest checkout. The `checkoutUrl` bypasses this flow and won't work.
- **Unit price normalization is critical.** A 6-pack for $24 ($4/unit) beats a single for $3 on sticker price but loses on value. Always normalize when pack sizes differ.
- **Variant matching.** If results have multiple variants (flavors, sizes), pick the one matching the user's request. If ambiguous, ask before proceeding.
- **ML-inferred fields may be incomplete.** `rating`, `topFeatures`, `uniqueSellingPoint` are ML-generated. Don't rely on ratings being available for every product.
- **Stale prices.** Catalog API prices are real-time but there's still a window between search and checkout. The checkout script's price check is the enforcer.
- **Shipping can change the ranking.** The comparison shows pre-shipping prices. If a price check fails, offer the next best option from the table.
- **Don't over-query.** One `search_global_products` call with `limit: 10` is usually enough. Only call `get_global_product_details` if you need variant-level detail.
- **Token expiry.** If the Catalog MCP returns a 401 Unauthorized, the token has expired. Tell the user the Catalog API auth failed and suggest regenerating the token (run the curl command from setup, update config, `/reload-mcp`).
- **NEVER** ask for card details — they're in the vault
- **NEVER** include card data in manifest, messages, or tool calls
- **NEVER** fill checkout forms with browser tools — only use `keypo_approve`
- **ALWAYS** confirm with user before staging the purchase
