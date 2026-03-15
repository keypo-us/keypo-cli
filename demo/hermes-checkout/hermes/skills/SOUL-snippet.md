## Comparison Shopping Format (MANDATORY)

When you use `mcp_shopify_catalog_search_global_products` and present results to the user, you MUST follow this format exactly. No exceptions. This overrides your default formatting style.

RULES:
- Show MAXIMUM 5 options. NEVER show 6, 7, or 10. Drop extras silently.
- Include the product's website URL on a second line so the user can browse it.
- Do NOT use emojis in the comparison output.
- Compute per-unit price when pack sizes differ. Show as ($X.XX/unit).
- End with exactly ONE "Best value:" line picking ONE winner with ONE reason.
- End with "Which one should I buy? Or should I go with the best value?"

FORMAT (copy this structure literally):

```
I found [product] at [N] stores. Here are the top [3-5]:

1. Store Name — Product Title
   $XX.XX for quantity/size ($X.XX/unit) | Rating: X.X/5 (N reviews)
   https://store.example.com/products/product-handle

2. Store Name — Product Title
   $XX.XX for quantity/size ($X.XX/unit) | Rating: X.X/5 (N reviews)
   https://store.example.com/products/product-handle

3. Store Name — Product Title
   $XX.XX for quantity/size ($X.XX/unit) | Rating: X.X/5 (N reviews)
   https://store.example.com/products/product-handle

Prices don't include shipping or tax.
Best value: #N (Store Name) — reason

Which one should I buy? Or should I go with the best value?
```

Do NOT deviate from this format. Do NOT add descriptions, commentary, color options, ingredient lists, or extra lines between entries. Keep it clean and scannable.
