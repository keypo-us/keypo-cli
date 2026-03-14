#!/usr/bin/env node
// checkout.js — Deterministic Shopify checkout script
// Reads manifest from stdin, fills checkout from env vars, places order.
// CRITICAL: Never log card data (CARD_NUMBER, CARD_CVV, CARD_EXP_MONTH, CARD_EXP_YEAR, CARD_NAME).

import puppeteer from 'puppeteer-extra';
import StealthPlugin from 'puppeteer-extra-plugin-stealth';
import AnonymizeUAPlugin from 'puppeteer-extra-plugin-anonymize-ua';
import UserAgent from 'user-agents';

puppeteer.use(StealthPlugin());
puppeteer.use(AnonymizeUAPlugin());

const sleep = ms => new Promise(r => setTimeout(r, ms));

// Exit codes
const EXIT_OK = 0;
const EXIT_PRICE = 2;
const EXIT_PRODUCT = 3;
const EXIT_CHECKOUT = 4;
const EXIT_CONFIG = 5;
const EXIT_NAV = 6;

// Status logging to stderr only
function status(msg) {
  process.stderr.write(`[checkout] ${msg}\n`);
}

function fatal(code, prefix, msg) {
  process.stderr.write(`${prefix}: ${msg}\n`);
  process.exit(code);
}

// --- Sensitive-data filter: never log these values ---
const SENSITIVE_VARS = ['CARD_NUMBER', 'CARD_CVV', 'CARD_EXP_MONTH', 'CARD_EXP_YEAR', 'CARD_NAME'];

// --- Step 1: Read manifest from stdin ---
async function readManifest() {
  return new Promise((resolve, reject) => {
    let data = '';
    const timeout = setTimeout(() => {
      // No data on stdin after 2 seconds — treat as empty
      if (!data) {
        reject(new Error('no manifest data on stdin'));
      }
    }, 2000);

    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => { data += chunk; });
    process.stdin.on('end', () => {
      clearTimeout(timeout);
      if (!data.trim()) {
        reject(new Error('empty stdin — no manifest provided'));
        return;
      }
      try {
        const manifest = JSON.parse(data);
        resolve(manifest);
      } catch (err) {
        reject(new Error(`invalid JSON: ${err.message}`));
      }
    });
    process.stdin.on('error', err => {
      clearTimeout(timeout);
      reject(err);
    });
    // If stdin is a pipe that's already closed (e.g., /dev/null), 'end' fires immediately.
    // Resume to ensure events fire.
    process.stdin.resume();
  });
}

function validateManifest(manifest) {
  const required = ['product_url', 'quantity', 'max_price'];
  const missing = required.filter(k => manifest[k] === undefined || manifest[k] === null);
  if (missing.length > 0) {
    fatal(EXIT_CONFIG, 'CONFIG_ERROR', `manifest missing required fields: ${missing.join(', ')}`);
  }
  if (typeof manifest.product_url !== 'string' || !manifest.product_url.startsWith('http')) {
    fatal(EXIT_CONFIG, 'CONFIG_ERROR', 'manifest product_url must be a valid URL');
  }
  if (typeof manifest.max_price !== 'number' || manifest.max_price <= 0) {
    fatal(EXIT_CONFIG, 'CONFIG_ERROR', 'manifest max_price must be a positive number');
  }
  if (typeof manifest.quantity !== 'number' || manifest.quantity < 1) {
    fatal(EXIT_CONFIG, 'CONFIG_ERROR', 'manifest quantity must be >= 1');
  }
}

// --- Step 2: Validate env vars ---
function validateEnv() {
  const required = [
    'CARD_NUMBER', 'CARD_EXP_MONTH', 'CARD_EXP_YEAR', 'CARD_CVV', 'CARD_NAME',
    'SHIP_FIRST_NAME', 'SHIP_LAST_NAME', 'SHIP_ADDRESS1',
    'SHIP_CITY', 'SHIP_STATE', 'SHIP_ZIP', 'SHIP_COUNTRY', 'SHIP_PHONE'
  ];
  for (const name of required) {
    if (!process.env[name]) {
      fatal(EXIT_CONFIG, 'CONFIG_ERROR', `missing env var ${name}`);
    }
  }
}

// --- Helper: type into Shopify card iframe ---
// Adapted from checkout-demo/bot/sites/shopify.js typeInCardIframe
async function typeInCardIframe(page, iframes, labelText, value) {
  // Primary: find by aria-label or placeholder
  for (const iframe of iframes) {
    const frame = await iframe.contentFrame();
    if (!frame) continue;
    try {
      const input = await frame.waitForSelector(
        `input[aria-label="${labelText}"], input[placeholder="${labelText}"]`,
        { timeout: 3000 }
      );
      if (input) {
        await input.type(value, { delay: 10 });
        return true;
      }
    } catch (_) {
      // Not in this iframe
    }
  }
  // Fallback: find visible input in each frame
  for (const iframe of iframes) {
    const frame = await iframe.contentFrame();
    if (!frame) continue;
    try {
      const found = await frame.evaluate(() => {
        const inputs = document.querySelectorAll('input');
        for (const inp of inputs) {
          const rect = inp.getBoundingClientRect();
          if (rect.width > 0 && rect.height > 0) return true;
        }
        return false;
      });
      if (found) {
        const visibleInput = await frame.$('input:not([type="hidden"])');
        if (visibleInput) {
          const box = await visibleInput.boundingBox();
          if (box && box.width > 0) {
            await visibleInput.type(value, { delay: 10 });
            return true;
          }
        }
      }
    } catch (_) {
      // continue
    }
  }
  status(`Could not find iframe field for: ${labelText}`);
  return false;
}

// --- Helper: extract price from checkout page ---
async function extractTotal(page) {
  // Modern Shopify checkout: look for the total amount in various selectors
  const totalText = await page.evaluate(() => {
    // Try multiple selectors for Shopify checkout total
    const selectors = [
      // Modern Shopify checkout (2024+)
      '[data-checkout-payment-due-target]',
      '.payment-due__price',
      '.total-line--total .total-line__price .order-summary__emphasis',
      // Newer Shopify checkout extensibility
      '[class*="total"] [class*="price"]',
      '[class*="due"] [class*="price"]',
      // Order summary total row
      'tfoot .total-line__price',
      // Generic fallback: find elements with dollar amounts in summary area
    ];
    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el) {
        const text = el.textContent.trim();
        if (text) return text;
      }
    }
    // Broader search: look for "Total" label and get its sibling price
    const allElements = document.querySelectorAll('*');
    for (const el of allElements) {
      if (el.children.length === 0 && el.textContent.trim() === 'Total') {
        // Look at parent's next sibling or parent's other children for a price
        const parent = el.closest('tr, div, [role="row"]');
        if (parent) {
          const priceEl = parent.querySelector('[class*="price"], [class*="amount"]');
          if (priceEl) return priceEl.textContent.trim();
          // Try last child with $ sign
          const texts = [...parent.querySelectorAll('*')].map(e => e.textContent.trim()).filter(t => t.startsWith('$'));
          if (texts.length) return texts[texts.length - 1];
        }
      }
    }
    // Last resort: find any visible element with a dollar amount in the summary/sidebar
    const sidebar = document.querySelector('[class*="sidebar"], [class*="summary"], [role="complementary"]');
    if (sidebar) {
      const matches = sidebar.textContent.match(/\$[\d,]+\.\d{2}/g);
      if (matches && matches.length) return matches[matches.length - 1];
    }
    // Absolute last resort
    const bodyMatches = document.body.textContent.match(/Total[\s\S]*?(\$[\d,]+\.\d{2})/);
    if (bodyMatches) return bodyMatches[1];
    return null;
  });

  if (!totalText) return null;
  // Parse "$XX.XX" or "XX.XX"
  const match = totalText.replace(/,/g, '').match(/([\d.]+)/);
  if (!match) return null;
  return parseFloat(match[1]);
}

// --- Helper: bypass Shopify store password gate ---
async function bypassPasswordGate(page, url) {
  if (!page.url().includes('/password')) return;
  status('Store password page detected, bypassing...');
  const storePassword = process.env.STORE_PASSWORD;
  if (!storePassword) {
    status('No STORE_PASSWORD env var set, cannot bypass password gate');
    return;
  }
  try {
    const buttons = await page.$$('button');
    for (const btn of buttons) {
      const text = await page.evaluate(el => el.textContent, btn);
      if (text.includes('Enter using password')) {
        await btn.click();
        break;
      }
    }
    await sleep(1000);
    const passwordInput = await page.waitForSelector(
      'dialog input[type="password"], input[type="password"]',
      { timeout: 5000 }
    );
    await passwordInput.type(storePassword, { delay: 10 });
    const submitButtons = await page.$$('dialog button');
    for (const btn of submitButtons) {
      const text = await page.evaluate(el => el.textContent.trim(), btn);
      if (text === 'Submit') {
        await Promise.all([
          page.waitForNavigation({ waitUntil: 'domcontentloaded' }),
          btn.click()
        ]);
        break;
      }
    }
    status('Password gate bypassed');
    await page.goto(url, { waitUntil: 'domcontentloaded' });
  } catch (err) {
    status(`Password bypass failed: ${err.message}`);
  }
}

// --- Main ---
async function main() {
  // Step 1: Read and validate manifest
  let manifest;
  try {
    manifest = await readManifest();
  } catch (err) {
    fatal(EXIT_CONFIG, 'CONFIG_ERROR', err.message);
  }
  validateManifest(manifest);

  const { product_url, quantity, max_price } = manifest;
  const domain = product_url.split('/').slice(0, 3).join('/');

  // Step 2: Validate env vars (before launching browser)
  validateEnv();

  status(`Product: ${product_url}`);
  status(`Quantity: ${quantity}, Max price: $${max_price.toFixed(2)}`);

  // Step 3: Launch Puppeteer with stealth
  const headless = process.env.HEADLESS !== 'false';
  const userAgent = new UserAgent({ deviceCategory: 'desktop' });
  let browser;
  try {
    browser = await puppeteer.launch({
      headless: headless ? 'new' : false,
      args: [
        '--no-sandbox',
        '--disable-setuid-sandbox',
        '--disable-dev-shm-usage',
        '--disable-blink-features=AutomationControlled',
        `--user-agent=${userAgent.toString()}`
      ],
      defaultViewport: { width: 1440, height: 900 }
    });
  } catch (err) {
    fatal(EXIT_CHECKOUT, 'CHECKOUT_ERROR', `failed to launch browser: ${err.message}`);
  }

  let page;
  try {
    page = await browser.newPage();
    await page.setUserAgent(userAgent.toString());

    // Step 4: Navigate to product page
    status('Navigating to product page...');
    let response;
    try {
      response = await page.goto(product_url, {
        waitUntil: 'domcontentloaded',
        timeout: 60000
      });
    } catch (err) {
      if (err.message.includes('timeout') || err.message.includes('Timeout')) {
        fatal(EXIT_NAV, 'NAV_ERROR', `navigation timeout: ${product_url}`);
      }
      fatal(EXIT_NAV, 'NAV_ERROR', `navigation failed: ${err.message}`);
    }

    // Handle password gate
    await bypassPasswordGate(page, product_url);

    // Check for 404
    const httpStatus = response ? response.status() : null;
    if (httpStatus === 404) {
      fatal(EXIT_PRODUCT, 'PRODUCT_ERROR', `product not found (404): ${product_url}`);
    }

    // Check for product availability via Shopify meta
    await sleep(2000);
    const productCheck = await page.evaluate(() => {
      try {
        // Shopify exposes product data via ShopifyAnalytics
        if (window.ShopifyAnalytics && window.ShopifyAnalytics.meta && window.ShopifyAnalytics.meta.product) {
          return { found: true };
        }
      } catch (_) {}
      // Check for 404 page indicators
      if (document.title.includes('404') || document.title.includes('Not Found')) {
        return { found: false, reason: 'page title indicates 404' };
      }
      if (document.querySelector('.errors, .template-404, [class*="404"]')) {
        return { found: false, reason: 'page contains 404 elements' };
      }
      // If URL was redirected away from /products/, product doesn't exist
      if (!window.location.pathname.includes('/products/')) {
        return { found: false, reason: `redirected away from product page to ${window.location.pathname}` };
      }
      return { found: true };
    });

    if (!productCheck.found) {
      fatal(EXIT_PRODUCT, 'PRODUCT_ERROR', `product not found: ${productCheck.reason || product_url}`);
    }

    // Step 5: Add to cart using fetch('/cart/add.js') pattern from shopify.js
    status('Adding to cart...');
    const addResult = await page.evaluate(async (qty) => {
      try {
        const meta = window.ShopifyAnalytics && window.ShopifyAnalytics.meta;
        if (!meta || !meta.product || !meta.product.variants || !meta.product.variants.length) {
          return { ok: false, error: 'no product variants found' };
        }
        const variantId = meta.product.variants[0].id;

        // Clear cart first
        await fetch('/cart/clear.js', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' }
        });

        const response = await fetch('/cart/add.js', {
          method: 'POST',
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            items: [{ id: variantId, quantity: qty }]
          })
        });

        if (response.status === 200) {
          return { ok: true };
        }
        const body = await response.text();
        return { ok: false, error: `add to cart failed (${response.status}): ${body}` };
      } catch (err) {
        return { ok: false, error: err.message };
      }
    }, quantity);

    if (!addResult.ok) {
      fatal(EXIT_PRODUCT, 'PRODUCT_ERROR', addResult.error);
    }
    status('Product added to cart');
    await sleep(1000);

    // Step 6: Navigate to /checkout
    status('Navigating to checkout...');
    try {
      await page.goto(`${domain}/checkout`, {
        waitUntil: 'domcontentloaded',
        timeout: 60000
      });
    } catch (err) {
      if (err.message.includes('timeout') || err.message.includes('Timeout')) {
        fatal(EXIT_NAV, 'NAV_ERROR', `checkout navigation timeout`);
      }
      fatal(EXIT_NAV, 'NAV_ERROR', `checkout navigation failed: ${err.message}`);
    }
    await sleep(3000);

    // Step 7: Price check 1 — cart total vs max_price
    status('Price check 1: verifying cart total...');
    const cartTotal = await extractTotal(page);
    if (cartTotal !== null) {
      status(`Cart total: $${cartTotal.toFixed(2)}`);
      if (cartTotal > max_price) {
        fatal(EXIT_PRICE, 'PRICE_CHECK_FAILED', `cart $${cartTotal.toFixed(2)} exceeds max $${max_price.toFixed(2)}`);
      }
      status('Price check 1 passed');
    } else {
      status('Warning: could not extract cart total for price check 1, continuing...');
    }

    // Step 8: Fill shipping info
    status('Filling shipping information...');

    // Fill email (required by Shopify checkout)
    const emailAddress = process.env.SHIP_EMAIL || `${process.env.SHIP_FIRST_NAME.toLowerCase()}@example.com`;
    try {
      const emailSelector = 'input[autocomplete="email"], input[type="email"], input[name="email"]';
      await page.waitForSelector(emailSelector, { timeout: 15000 });
      const emailInput = await page.$(emailSelector);
      if (emailInput) {
        await emailInput.click({ clickCount: 3 });
        await emailInput.type(emailAddress, { delay: 10 });
        await sleep(1000);
      }
    } catch (err) {
      status(`Email field: ${err.message}`);
    }

    // Dismiss Shop verification modal if it appears
    try {
      const shopModal = await page.waitForSelector(
        'button[aria-label="Close"], [role="dialog"] button:first-child',
        { timeout: 3000 }
      );
      if (shopModal) {
        status('Dismissing Shop modal...');
        await shopModal.click();
        await sleep(1000);
      }
    } catch (_) {
      // No modal
    }

    // Country
    try {
      const countrySelect = await page.$('select[autocomplete="country"], select[name*="country"], select[name*="countryCode"]');
      if (countrySelect) {
        await page.select('select[autocomplete="country"], select[name*="country"], select[name*="countryCode"]', process.env.SHIP_COUNTRY);
        await sleep(1000);
      }
    } catch (err) {
      status(`Country select: ${err.message}`);
    }

    // First name
    try {
      const firstNameInput = await page.$('input[autocomplete="given-name"], input[name*="firstName"]');
      if (firstNameInput) {
        await firstNameInput.click({ clickCount: 3 });
        await firstNameInput.type(process.env.SHIP_FIRST_NAME, { delay: 10 });
        await sleep(500);
      }
    } catch (err) {
      status(`First name: ${err.message}`);
    }

    // Last name
    try {
      const lastNameInput = await page.$('input[autocomplete="family-name"], input[name*="lastName"]');
      if (lastNameInput) {
        await lastNameInput.click({ clickCount: 3 });
        await lastNameInput.type(process.env.SHIP_LAST_NAME, { delay: 10 });
        await sleep(500);
      }
    } catch (err) {
      status(`Last name: ${err.message}`);
    }

    // Address line 1
    try {
      const addr1Input = await page.$('input[autocomplete="address-line1"], input[name*="address1"]');
      if (addr1Input) {
        await addr1Input.click({ clickCount: 3 });
        await addr1Input.type(process.env.SHIP_ADDRESS1, { delay: 10 });
        await sleep(2000);
        // Dismiss address autocomplete dropdown
        await page.keyboard.press('Escape');
        await sleep(500);
      }
    } catch (err) {
      status(`Address 1: ${err.message}`);
    }

    // Address line 2 (optional)
    const addr2 = process.env.SHIP_ADDRESS2 || '';
    if (addr2) {
      try {
        const addr2Input = await page.$('input[autocomplete="address-line2"], input[name*="address2"]');
        if (addr2Input) {
          await addr2Input.click({ clickCount: 3 });
          await addr2Input.type(addr2, { delay: 10 });
          await sleep(500);
        }
      } catch (err) {
        status(`Address 2: ${err.message}`);
      }
    }

    // City
    try {
      const cityInput = await page.$('input[autocomplete="address-level2"], input[name*="city"]');
      if (cityInput) {
        await cityInput.click({ clickCount: 3 });
        await cityInput.type(process.env.SHIP_CITY, { delay: 10 });
        await sleep(500);
      }
    } catch (err) {
      status(`City: ${err.message}`);
    }

    // State
    try {
      const stateSelect = await page.$('select[autocomplete="address-level1"], select[name*="zone"]');
      if (stateSelect) {
        await page.select('select[autocomplete="address-level1"], select[name*="zone"]', process.env.SHIP_STATE);
        await sleep(500);
      } else {
        // Some Shopify checkouts use a text input for state
        const stateInput = await page.$('input[autocomplete="address-level1"], input[name*="zone"]');
        if (stateInput) {
          await stateInput.click({ clickCount: 3 });
          await stateInput.type(process.env.SHIP_STATE, { delay: 10 });
          await sleep(500);
        }
      }
    } catch (err) {
      status(`State: ${err.message}`);
    }

    // ZIP
    try {
      const zipInput = await page.$('input[autocomplete="postal-code"], input[name*="postalCode"]');
      if (zipInput) {
        await zipInput.click({ clickCount: 3 });
        await zipInput.type(process.env.SHIP_ZIP, { delay: 10 });
        await sleep(500);
      }
    } catch (err) {
      status(`ZIP: ${err.message}`);
    }

    // Phone
    try {
      const phoneInput = await page.$('input[autocomplete="tel"], input[name*="phone"]');
      if (phoneInput) {
        await phoneInput.click({ clickCount: 3 });
        await phoneInput.type(process.env.SHIP_PHONE, { delay: 10 });
        await sleep(500);
      }
    } catch (err) {
      status(`Phone: ${err.message}`);
    }

    // Step 9: Select shipping method
    // On modern Shopify single-page checkout, shipping methods appear after address is filled.
    // We may need to click "Continue to shipping" on multi-page checkouts first.
    status('Selecting shipping method...');

    // Try clicking continue/submit button if this is a multi-step checkout
    try {
      const continueBtn = await page.evaluateHandle(() => {
        const buttons = document.querySelectorAll('button');
        for (const btn of buttons) {
          const text = btn.textContent.toLowerCase().trim();
          if (text.includes('continue to shipping') || text.includes('continue to delivery')) {
            return btn;
          }
        }
        return null;
      });
      if (continueBtn && continueBtn.asElement()) {
        await continueBtn.click();
        await sleep(3000);
      }
    } catch (_) {}

    // Wait for shipping methods to appear and select first one
    await sleep(3000);
    try {
      // Shopify shipping methods are usually radio buttons
      const shippingRadio = await page.$('input[type="radio"][name*="shipping"], input[type="radio"][name*="delivery"]');
      if (shippingRadio) {
        await shippingRadio.click();
        await sleep(1000);
      }
    } catch (_) {}

    // Try clicking "Continue to payment" if multi-step
    try {
      const paymentBtn = await page.evaluateHandle(() => {
        const buttons = document.querySelectorAll('button');
        for (const btn of buttons) {
          const text = btn.textContent.toLowerCase().trim();
          if (text.includes('continue to payment')) {
            return btn;
          }
        }
        return null;
      });
      if (paymentBtn && paymentBtn.asElement()) {
        await paymentBtn.click();
        await sleep(3000);
      }
    } catch (_) {}

    // Step 10: Price check 2 — total after shipping
    status('Price check 2: verifying total with shipping...');
    await sleep(2000);
    const totalWithShipping = await extractTotal(page);
    if (totalWithShipping !== null) {
      status(`Total with shipping: $${totalWithShipping.toFixed(2)}`);
      if (totalWithShipping > max_price) {
        fatal(EXIT_PRICE, 'PRICE_CHECK_FAILED', `total $${totalWithShipping.toFixed(2)} exceeds max $${max_price.toFixed(2)}`);
      }
      status('Price check 2 passed');
    } else {
      status('Warning: could not extract total for price check 2, continuing...');
    }

    // Step 11: Fill payment — use iframe card-filling pattern from shopify.js
    status('Filling payment information...');
    await page.waitForSelector('iframe', { timeout: 15000 });
    await sleep(2000);
    const iframes = await page.$$('iframe');

    // Card number
    const cardFilled = await typeInCardIframe(page, iframes, 'Card number', process.env.CARD_NUMBER);
    if (!cardFilled) {
      status('Warning: could not fill card number via iframe');
    }
    await sleep(1000);

    // Name on card
    await typeInCardIframe(page, iframes, 'Name on card', process.env.CARD_NAME);
    await sleep(1000);

    // Expiration date (MM / YY format — Shopify expects concatenated MMYY)
    const expiry = process.env.CARD_EXP_MONTH + process.env.CARD_EXP_YEAR;
    await typeInCardIframe(page, iframes, 'Expiration date (MM / YY)', expiry);
    await sleep(1000);

    // Security code / CVV
    await typeInCardIframe(page, iframes, 'Security code', process.env.CARD_CVV);
    await sleep(1000);

    // Step 12: Submit — click "Pay now"
    status('Clicking Pay now...');
    const payNowBtn = await page.evaluateHandle(() => {
      const buttons = document.querySelectorAll('button');
      for (const btn of buttons) {
        const text = btn.textContent.trim();
        if (text.includes('Pay now') || text.includes('Complete order')) {
          return btn;
        }
      }
      return null;
    });

    if (!payNowBtn || !payNowBtn.asElement()) {
      fatal(EXIT_CHECKOUT, 'CHECKOUT_ERROR', 'could not find Pay now button');
    }

    await payNowBtn.click();
    status('Waiting for order confirmation...');
    await sleep(10000);

    // Step 13: Check result
    const currentUrl = page.url();

    // Check for order confirmation page
    if (currentUrl.includes('thank-you') || currentUrl.includes('thank_you') || currentUrl.includes('orders/')) {
      // Extract order number
      const orderNumber = await page.evaluate(() => {
        // Try to find order number in the page
        const selectors = [
          '.os-order-number',
          '[class*="order-number"]',
          '[class*="order-confirmation"]',
        ];
        for (const sel of selectors) {
          const el = document.querySelector(sel);
          if (el) return el.textContent.trim().replace(/[^a-zA-Z0-9-#]/g, '');
        }
        // Try URL-based extraction
        const match = window.location.pathname.match(/orders\/([^/?]+)/);
        if (match) return match[1];
        // Fallback: use the confirmation URL itself
        return window.location.href;
      });

      process.stdout.write(`ORDER_CONFIRMED:${orderNumber}\n`);
      await browser.close();
      process.exit(EXIT_OK);
    }

    // Fallback: check if cart is empty (order went through)
    try {
      await page.goto(`${domain}/checkout`, { waitUntil: 'domcontentloaded', timeout: 15000 });
      if (page.url().includes('/cart')) {
        // Cart is empty, order likely completed
        process.stdout.write(`ORDER_CONFIRMED:unknown\n`);
        await browser.close();
        process.exit(EXIT_OK);
      }
    } catch (_) {}

    // Check for error messages on the page (card decline, etc.)
    const errorText = await page.evaluate(() => {
      const errorSelectors = [
        '[class*="error"] [class*="message"]',
        '[class*="notice--error"]',
        '.banner--error',
        '[role="alert"]',
        '[class*="field__message--error"]',
        '.notice--error',
        // Modern Shopify checkout errors
        '[class*="Error"]',
        '[data-error]',
      ];
      for (const sel of errorSelectors) {
        const els = document.querySelectorAll(sel);
        for (const el of els) {
          const text = el.textContent.trim();
          if (text) return text;
        }
      }
      return null;
    });

    if (errorText) {
      fatal(EXIT_CHECKOUT, 'CHECKOUT_ERROR', `payment failed: ${errorText}`);
    }

    // If we get here, something unexpected happened
    fatal(EXIT_CHECKOUT, 'CHECKOUT_ERROR', `unexpected state after payment submission (url: ${currentUrl})`);

  } catch (err) {
    // Catch-all: avoid leaking sensitive data in error messages
    let safeMessage = err.message || String(err);
    for (const varName of SENSITIVE_VARS) {
      const val = process.env[varName];
      if (val && safeMessage.includes(val)) {
        safeMessage = safeMessage.replaceAll(val, '[REDACTED]');
      }
    }
    fatal(EXIT_CHECKOUT, 'CHECKOUT_ERROR', safeMessage);
  } finally {
    if (browser) {
      try { await browser.close(); } catch (_) {}
    }
  }
}

main();
