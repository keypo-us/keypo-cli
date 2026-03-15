# Comparison Shopping Skill Spec (v3 — Catalog MCP)

## Overview

Teach Hermes to comparison-shop across multiple Shopify stores before executing a purchase. When the user says "buy me chocolate chip cookies," Hermes queries Shopify's Catalog MCP to search across all Shopify merchants at once, builds a comparison table from the structured results, presents it to the user, and executes the purchase on whichever store the user picks.

## What changes

**No changes to the daemon, keypo_approve tool, vault, checkout script, or keypo-signer.** The new work is:

1. A Catalog MCP server entry in Hermes' `~/.hermes/config.yaml` (with a pre-generated bearer token from Shopify's token endpoint)
2. A new SKILL.md file that teaches Hermes to use `search_global_products` for comparison shopping

## Dependency

Requires the base `keypo-checkout.md` skill and the `keypo_approve` tool to already be working. This skill replaces the browsing/discovery phase that happens before `keypo_approve` is called.

---

## Catalog MCP Setup

### Credentials

- **Client ID:** from Dev Dashboard → Catalogs → API key (already created: `f1a93e954e5f9732dc1bdee1c4154ab5`)
- **Client Secret:** from same location (ends in `c781`)
- **Token endpoint:** `POST https://api.shopify.com/auth/access_token`
- **MCP endpoint:** `POST https://discover.shopifyapps.com/global/mcp` (JSON-RPC 2.0)
- **REST endpoint:** `GET https://discover.shopifyapps.com/global/v2/search` (alternative, query params)

### Token TTL

Shopify's docs contain a contradiction: they state "60-minute TTL" in one place but the example response shows `"expires_in": 86399` (~24 hours). **Action item:** when you first generate a token, check the actual `expires_in` value in the response.

- If `expires_in` is ~86400 (24 hours): a pre-generated token is more than sufficient for the hackathon. No proxy needed.
- If `expires_in` is ~3600 (60 minutes): a pre-generated token still covers a demo session. Regenerate before each demo run.

Either way, a token-refresh proxy is unnecessary for hackathon scope.

### Saved Catalog

In Dev Dashboard, configure the saved catalog with:
- Scope: All Shopify products
- Ships to: US
- Save the catalog

After saving, go back to the Catalogs landing page and click "Copy URL." The URL has the form:

```
https://discover.shopifyapps.com/global/v1/search/{your_catalog_id}
```

Extract `{your_catalog_id}` from this URL. This is the value you pass as the `saved_catalog` parameter in MCP tool calls. It's the catalog ID, not the display name you gave it in the dashboard.

The saved catalog's filters (Ships to: US, All Shopify products) take precedence over any runtime parameters, so you don't need to pass `ships_to` separately when using the saved catalog.

### Hermes MCP Configuration

**Step 1: Generate a bearer token.** Run this in your terminal before starting Hermes:

```bash
curl --silent --request POST \
  --url 'https://api.shopify.com/auth/access_token' \
  -H 'Content-Type: application/json' \
  --data '{
    "client_id": "f1a93e954e5f9732dc1bdee1c4154ab5",
    "client_secret": "<your_full_client_secret>",
    "grant_type": "client_credentials"
  }' | jq .
```

Response:

```json
{
  "access_token": "eyJhbGciOi...",
  "scope": "read_global_api_catalog_search",
  "expires_in": 86399
}
```

Copy the `access_token` value. Note the `expires_in` value to confirm the TTL (86399 = ~24 hours, 3600 = 1 hour).

**Step 2: Add to `~/.hermes/config.yaml`:**

```yaml
mcp_servers:
  shopify_catalog:
    url: "https://discover.shopifyapps.com/global/mcp"
    headers:
      Authorization: "Bearer eyJhbGciOi...your_actual_token_here"
```

Hermes' HTTP MCP transport accepts `url` and `headers` as config keys. The bearer token goes directly in the `Authorization` header value.

**Step 3: Start (or reload) Hermes.** If Hermes is already running, send `/reload-mcp` in the messaging gateway to pick up the new config without restarting. Otherwise, just start Hermes normally.

**Step 4: Verify.** Ask Hermes "What tools do you have?" The Shopify catalog tools should appear as:
- `mcp_shopify_catalog_search_global_products`
- `mcp_shopify_catalog_get_global_product_details`

Plus the 4 auto-registered utility tools: `mcp_shopify_catalog_list_resources`, `mcp_shopify_catalog_read_resource`, `mcp_shopify_catalog_list_prompts`, `mcp_shopify_catalog_get_prompt`.

**Token refresh:** When the token expires, regenerate it with the same curl command and update the `Authorization` header in the config. Then restart Hermes or send `/reload-mcp`. For demo day, generate a fresh token right before the demo starts.

### Available Tools (from Catalog MCP)

Once connected, Hermes registers these tools with prefixed names:

- `mcp_shopify_catalog_search_global_products` — search across all Shopify merchants. Parameters: `query` (string, required), `context` (string, required), `available_for_sale` (boolean), `limit` (int, 1-300, default 10), `min_price` (number), `max_price` (number), `saved_catalog` (string), `ships_to` (ISO country code), `include_secondhand` (boolean)
- `mcp_shopify_catalog_get_global_product_details` — get full details for a specific product by UPID or variant ID. Parameters: `upid` (string) or `variant_id` (string), `available_for_sale` (boolean), `context` (string), `option_preferences` (string)

These appear alongside Hermes' built-in tools and the `keypo_approve` tool. In the skill file and throughout this spec, we use the short names (`search_global_products`, `get_global_product_details`) for readability, but Hermes invokes them with the `mcp_shopify_catalog_` prefix.

---

## Skill: `keypo-comparison-shop.md`

**Location:** `demos/hermes-checkout/hermes/skills/keypo-comparison-shop.md`
Symlinked into `~/.hermes/skills/`.

### Frontmatter

```yaml
---
name: keypo-comparison-shop
description: Compare prices across multiple Shopify stores using the Shopify Catalog API and buy from the best option
version: 1.0.0
author: Keypo
dependencies:
  - keypo-checkout
  - keypo-vault
---
```

### When to Use

When the user asks to buy a product without specifying a particular store, or explicitly asks for the best price / to compare options. Trigger phrases:

- "Buy me the cheapest..."
- "Find me the best deal on..."
- "Compare prices for..."
- "Where's the cheapest place to get..."
- "Buy me [product]" (no store specified) — default to comparison mode

Do NOT use when the user names a specific store: "Buy me cookies from shop.keypo.io" goes directly to `keypo-checkout`.

### Procedure

1. **Parse the product request.** Extract: product type, quantity, brand/flavor preferences, constraints (organic, gluten-free, etc.), and any price limits the user mentions.

2. **Query the Catalog MCP.** Call `search_global_products` with:
   - `query`: the product description (e.g., "chocolate chip cookies")
   - `context`: any relevant buyer context (e.g., "looking for a gift box, prefers artisan bakeries")
   - `saved_catalog`: the catalog ID from Dev Dashboard (see Setup section above)
   - `available_for_sale`: `true`
   - `limit`: `10` (we'll filter down to top 3-5)
   - `max_price`: if the user mentioned a budget, include it

   Note: `ships_to` is already baked into the saved catalog config (US). No need to pass it separately.

3. **Process the results.** The API returns an array of `UniversalProduct` objects. Each contains:
   - `title` — product name (from top-ranked variant)
   - `description` — product description
   - `priceRange.min.amount` / `priceRange.max.amount` — price range
   - `products[]` — array of product variants from different shops:
     - `products[].onlineStoreUrl` — direct URL to the product on the merchant's store (includes `?variant=XXXX&_gsid=YYYY` tracking params)
     - `products[].checkoutUrl` — Shopify cart permalink (NOT used by us)
     - `products[].shop.name` — store name
     - `products[].shop.onlineStoreUrl` — store URL
     - `products[].price.amount` / `products[].price.currencyCode` — variant price
     - `products[].availableForSale` — availability flag
   - `offers[].options` — available variants (size, color, flavor)
   - `rating.value` / `rating.count` — ratings (if available, may not always be present)
   - `topFeatures` — array of key features (ML-inferred, may vary in accuracy)
   - `uniqueSellingPoint` — USP (ML-inferred)
   - `sharedAttributes` — structured attributes (Fabric, Neckline, etc.)

   Filter results:
   - Remove out-of-stock items (`availableForSale: false`)
   - Remove duplicates (API de-duplicates by UPID, but verify within `products[]` array)
   - If the user specified brand/flavor preferences, filter to matches
   - Take the top 3-5 results by relevance (API returns them ranked)

4. **If more detail is needed for a specific product**, call `get_global_product_details` with the UPID to get full variant info, all options, and descriptions. Use `option_preferences` to rank which options matter most (e.g., `"Flavor,Size"`).

5. **Build the comparison table.** Present to the user:

   ```
   I found [product] at [N] Shopify stores:

   1. [Store Name] — [Product Title]
      $XX.XX ([quantity/size])  |  Rating: X.X/5 (N reviews)
      URL: [onlineStoreUrl]

   2. [Store Name] — [Product Title]
      $XX.XX ([quantity/size])  |  Rating: X.X/5 (N reviews)
      URL: [onlineStoreUrl]

   3. [Store Name] — [Product Title]
      $XX.XX ([quantity/size])  |  Rating: X.X/5 (N reviews)
      URL: [onlineStoreUrl]

   Prices don't include shipping or tax (the checkout script verifies the final total).
   Best value: #[N] ([Store Name]) — [reason: cheapest per unit / highest rated / etc.]

   Which one should I buy? Or should I go with the best value?
   ```

   Rules for the table:
   - Compute per-unit price if pack sizes differ across stores
   - Flag the best value (cheapest per unit, or best price-to-rating ratio)
   - Note that shipping/tax aren't included (checkout script's price check handles surprises)
   - Mark out-of-stock items if they were included for context
   - Maximum 5 options — more is noise

6. **Wait for user selection.** The user responds with:
   - A number ("2") or store name ("buy from Levain")
   - "cheapest" / "best value" / "go with your recommendation"
   - "none" / "nevermind" — abort
   - A follow-up question ("tell me more about #2", "any of these organic?")

7. **Extract the product URL for checkout.** The selected product's `onlineStoreUrl` from the API response becomes the `product_url` in the checkout manifest.

   **Important: URL parameter handling.** The `onlineStoreUrl` includes query params like `?variant=11111111111&_gsid=example123`. The `variant` param is useful (pre-selects the correct variant on the product page). The `_gsid` param is Shopify analytics tracking. The checkout script must be tested with these full URLs to confirm Puppeteer navigation works correctly. If the params cause issues with add-to-cart or checkout navigation, strip everything after the base `/products/<handle>` path.

8. **Hand off to keypo-checkout.** Construct the manifest:
   - `product_url`: the `onlineStoreUrl` from the selected product (with or without params, per T-CS13 results)
   - `quantity`: from the user's original request
   - `max_price`: the displayed price + 15% buffer (for tax/shipping)

   From this point, follow the standard `keypo-checkout` procedure: present purchase summary, ask for final confirmation, stage via `keypo_approve`, confirm, report result.

### Pitfalls

- **The `onlineStoreUrl` is the key output.** This URL points to the product on the merchant's actual Shopify store. The checkout script navigates to this URL, adds to cart, and proceeds through guest checkout. Do NOT use the `checkoutUrl` from the API — that's a Shopify cart permalink that bypasses the product page, and is not compatible with our checkout script's add-to-cart flow.
- **URL params from the API.** Test whether the full `onlineStoreUrl` (with `?variant=...&_gsid=...`) works with the checkout script. If the `_gsid` param causes redirects or tracking issues, strip it and keep only `?variant=...`. If even the `variant` param causes issues, strip everything and let the checkout script select the default variant.
- **Unit price normalization is critical.** A 6-pack for $24 ($4/unit) vs. a 12-pack for $39 ($3.25/unit). Always normalize when pack sizes differ.
- **Variant matching.** If results have multiple variants (flavors, sizes), pick the one matching the user's request. If ambiguous, ask. Use `get_global_product_details` with `option_preferences` for full variant info if needed.
- **ML-inferred fields may be incomplete.** `rating`, `topFeatures`, `uniqueSellingPoint` are ML-generated and may not always be present or accurate. Don't rely on ratings being available for every product.
- **Stale prices.** Catalog API prices are real-time but there's still a window between search and checkout. The checkout script's price check is the enforcer.
- **Shipping can change the ranking.** The comparison table shows pre-shipping prices. If the checkout script's price check fails (shipping pushes total past max_price), Hermes should explain the issue and offer to try the next best option from the comparison table.
- **Don't over-query.** One `search_global_products` call with `limit: 10` is usually sufficient. Only call `get_global_product_details` if you need variant-level detail for a specific product.
- **Token expiry.** If the Catalog MCP returns a 401 Unauthorized, the token has expired. Regenerate with the curl command from the Setup section, update the `Authorization` header in `~/.hermes/config.yaml`, and restart Hermes or send `/reload-mcp`.

### Verification

After the user selects a store, standard `keypo-checkout` verification applies: check `stdout` for `ORDER_CONFIRMED:` on success, `stderr` for `PRICE_CHECK_FAILED` on price failure.

For the comparison phase:
- Table includes at least 2 stores (if only 1 found, skip comparison)
- Per-unit price computed when pack sizes differ
- Best value flagged
- All product URLs are valid Shopify `/products/` paths
- Out-of-stock items excluded from recommendations

---

## Interaction with Existing Skills

```
User: "Buy me chocolate chip cookies"
                │
                ▼
   ┌─ Is a specific store named? ─┐
   │                               │
  YES                              NO
   │                               │
   ▼                               ▼
keypo-checkout               keypo-comparison-shop
(find product on named       (Catalog MCP search,
 store → propose → buy)       compare, present table)
                                   │
                                   ▼
                             User selects store
                                   │
                                   ▼
                             keypo-checkout
                             (propose → buy using
                              selected product URL)
```

---

## Verification Tests

All tests use fake card data in the vault. Card decline = success.

**T-CS1 — Catalog MCP returns structured results.**
Action: Tell Hermes "Find me chocolate chip cookies."
Expected: Hermes calls `search_global_products` with the saved catalog ID, receives structured JSON with product titles, prices, store names, and URLs. Presents a comparison table.
Proves: Catalog MCP integration works end-to-end (auth, saved catalog, tool invocation, response parsing).

**T-CS2 — Comparison table shown for unspecified store.**
Action: Tell Hermes "Buy me the best chocolate chip cookies."
Expected: Hermes presents comparison table with 3-5 options from different stores, per-unit prices where applicable, ratings if available, best value flagged.
Proves: Comparison flow triggers when no store is named.

**T-CS3 — User selects by number.**
Action: After T-CS2, reply "2."
Expected: Hermes proceeds with selected store's product URL, shows purchase summary with max_price, asks for final confirmation.

**T-CS4 — User selects "cheapest" or "best value."**
Action: After T-CS2, reply "go with the cheapest."
Expected: Hermes selects the store flagged as best value, proceeds with that product URL.

**T-CS5 — User says "nevermind."**
Action: After T-CS2, reply "nevermind."
Expected: Hermes acknowledges. No `keypo_approve` calls made.

**T-CS6 — Specific store bypasses comparison.**
Action: "Buy me cookies from shop.keypo.io."
Expected: Goes directly to `keypo-checkout`. No Catalog MCP call. No comparison table.

**T-CS7 — Per-unit normalization when pack sizes differ.**
Action: Search returns products with different pack sizes.
Expected: Table includes per-unit price. Best value based on per-unit, not sticker price.

**T-CS8 — Full pipeline through checkout (expected decline).**
Action: Complete comparison → select store → approve confirmation → approve TouchID.
Expected: Checkout script runs against selected store's product URL, Shopify declines fake card (exit 4). Hermes reports decline.
Proves: Catalog MCP discovery feeds cleanly into the vault-exec checkout pipeline.

**T-CS9 — Shipping cost causes price check failure, Hermes suggests next best.**
Precondition: User selected cheapest store. Shipping exceeds the 15% buffer.
Expected: Checkout returns exit 2 (PRICE_CHECK_FAILED). Hermes explains shipping pushed the total past the max, offers to try the next option from the comparison table.
Proves: Hermes retains comparison context and recovers from price check failures.

**T-CS10 — Fewer than 2 results skips comparison.**
Action: Search for a very niche product that only one Shopify store carries.
Expected: Hermes finds one store, goes straight to keypo-checkout without a comparison table. Tells user "I only found this at one store."

**T-CS11 — Agent never reveals card data during comparison.**
Action: Ask Hermes "what credit card will you use to buy these?"
Expected: Hermes declines, explains vault secrets are never exposed.

**T-CS12 — Token expiry handled gracefully.**
Action: Let the bearer token expire (wait past `expires_in`), then request a comparison search.
Expected: Hermes receives a 401 from the Catalog MCP. Hermes reports that the Catalog API auth failed and suggests regenerating the token.
Recovery: Regenerate token with curl command from Setup, update `~/.hermes/config.yaml`, send `/reload-mcp` to Hermes. Retry the search.
Proves: Auth failures don't crash the agent, and recovery is straightforward.

**T-CS13 — Product URL from Catalog API works with checkout script.**
Action: Take an `onlineStoreUrl` from a Catalog API response (full URL with `?variant=...&_gsid=...` params). Pipe it into checkout.js as the manifest's `product_url` with fake card data.
Expected: Checkout script navigates to the URL, adds to cart, proceeds through checkout, declines at payment (exit 4).
Proves: The URL format from Catalog MCP is compatible with the checkout script.
**If this test fails** because the query params interfere with navigation: re-run with the base URL only (strip everything after `/products/<handle>`). If that works, add URL-stripping logic to the skill's procedure step 7.

---

## Demo Script

1. **Open:** "I'm going to ask my agent to buy me cookies. I'm not telling it which store. It's going to search across every Shopify store in the world."

2. **Prompt:** "Buy me the best chocolate chip cookies you can find."

3. **Hermes searches:** One API call to Shopify's Catalog. Returns results from multiple stores in under a second. (Show the structured JSON briefly if audience is technical.)

4. **Table presented:** 3-4 stores compared with prices, ratings, per-unit costs.

5. **Selection:** "Go with the best value."

6. **Confirmation:** Hermes shows purchase summary. You say "yes."

7. **TouchID:** Prompt appears on Mac. Approve.

8. **Result:** Order placed (real card for final demo) or card decline (fake card for testing).

9. **Kicker:** "My agent just searched every Shopify store, found the best deal, and bought it. It never saw my credit card. The card was decrypted by the Secure Enclave, injected into a sandboxed process, and destroyed when the process exited."

---

## What the Catalog MCP Replaces

| Before (web scraping) | After (Catalog MCP) |
|---|---|
| 5+ web searches to find stores | 1 API call to `search_global_products` |
| Visit each store, scrape HTML for prices | Structured JSON with prices, ratings, URLs |
| Verify each site is Shopify | All results are Shopify by definition |
| Handle page load failures, JS-rendered content | Structured API, no browser needed |
| ~30-60 seconds of browsing | < 2 seconds |
| Fragile (DOM changes break scraping) | Stable API contract |
| 3-5 stores max (time-constrained) | 10+ stores in one call |

The checkout phase is unchanged. The Catalog MCP handles discovery; the vault-exec checkout pipeline handles payment. The agent still never sees card data.
