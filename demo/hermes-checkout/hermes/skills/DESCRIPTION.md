Skills for Keypo hardware-secured vault and checkout flows. Enables purchasing products from Shopify stores with biometric approval — card data never leaves the Secure Enclave.

## Comparison Shopping Output Format (MANDATORY)

When presenting product search results from the Catalog API (`mcp_shopify_catalog_search_global_products`), you MUST follow these rules exactly:

- Show MAXIMUM 5 options. Never more. Drop the rest.
- Do NOT show URLs, store domains, or links in the table. Keep them internally for checkout.
- Do NOT use emojis in the comparison table.
- End with EXACTLY ONE "Best value: #N (Store Name) — reason" line. Pick ONE winner.
- End with "Which one should I buy? Or should I go with the best value?"
- Compute per-unit price ($X.XX/unit) when pack sizes differ across options.
- Do NOT split into "best value" and "best quality." One recommendation only.

Format each option as:
```
N. Store Name — Product Title
   $XX.XX for quantity/size ($X.XX/unit) | Rating: X.X/5 (N reviews)
```
