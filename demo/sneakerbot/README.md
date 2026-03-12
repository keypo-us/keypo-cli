# SneakerBot + Keypo Vault Demo

Demonstrates an AI coding agent (Claude Code) orchestrating a Shopify purchase
via SneakerBot while credit card secrets are injected at runtime through
`keypo-signer vault exec`. The agent never sees or handles card data — Touch ID
acts as the human-in-the-loop approval gate.

## Architecture

```
Claude Code  ──▶  run-with-vault.sh  ──▶  keypo-signer vault exec
                                              │
                                     ┌────────┴────────┐
                                     │  open tier       │  (no auth)
                                     │  PORT, DB_*, … │
                                     ├─────────────────┤
                                     │  biometric tier  │  (Touch ID)
                                     │  CARD_NUMBER, …  │
                                     └────────┬────────┘
                                              │
                                              ▼
                                    node start-task.js
                                    (Puppeteer → Shopify checkout)
```

The agent calls `run-with-vault.sh <TASK_ID>`, which invokes `vault exec --env`
with a template listing the required env var names. The vault decrypts open-tier
secrets silently and prompts Touch ID for biometric-tier secrets. All values are
injected into the child process environment — never written to disk or returned
to the agent.

## Prerequisites

- **macOS** with Apple Silicon (Secure Enclave required)
- **keypo-signer** installed and vault initialized (`keypo-signer vault list`)
- **Node 18** (`nvm use 18`)
- **PostgreSQL** running locally (Homebrew or Docker)

## Quick Start

### 1. Database

Using Homebrew PostgreSQL:

```bash
brew services start postgresql@14
createdb sneakerbot_demo
psql sneakerbot_demo -c "CREATE USER sneakerbot WITH PASSWORD 'localdev';"
psql sneakerbot_demo -c "GRANT ALL ON DATABASE sneakerbot_demo TO sneakerbot;"
psql sneakerbot_demo -c "GRANT ALL ON SCHEMA public TO sneakerbot;"
```

Or using Docker:

```bash
docker compose up -d
```

### 2. Install SneakerBot dependencies

```bash
cd bot
nvm use 18
npm install
```

### 3. Run migrations and seed data

```bash
NODE_ENV=local npx knex migrate:latest
NODE_ENV=local npx knex seed:run
```

### 4. Import secrets to vault

Non-sensitive config (open tier — no auth required):

```bash
keypo-signer vault import demo/sneakerbot/bot/.env.open --policy open
```

Card secrets (biometric tier — Touch ID required):

```bash
keypo-signer vault import demo/sneakerbot/bot/.env.card --policy biometric
```

> **Note:** `.env.open` and `.env.card` are one-time import files you create
> locally with real values. They are gitignored and should be deleted after
> import.

### 5. Start the API server

```bash
cd bot
NODE_ENV=local node ./scripts/start-api-server.js
```

### 6. Create a task and run

```bash
# Check addresses
curl -s http://localhost:8080/v1/addresses | jq .

# Create a purchase task
curl -s -X POST http://localhost:8080/v1/tasks \
  -H 'Content-Type: application/json' \
  -d '{
    "site_id": 3,
    "url": "https://keypo-store-2.myshopify.com/products/keypo-logo-art?variant=44740698996759",
    "shipping_address_id": 1,
    "billing_address_id": 1,
    "notification_email_address": "mrsneaker1950@gmail.com"
  }'

# Run the task (Touch ID will be required)
./run-with-vault.sh <TASK_ID>
```

## Files

| File | Purpose |
|---|---|
| `run-with-vault.sh` | Wrapper: `vault exec --env` → `start-task.js` |
| `.env.vault-template` | Key-name manifest for `vault exec --env` |
| `docker-compose.yml` | Postgres-only compose (alternative to Homebrew) |
| `seed-data/` | Address and site reference data |
| `SKILL.md` | Claude Code agent skill definition |
| `bot/` | SneakerBot fork (git submodule → `keypo-us/SneakerBot`) |

## Security Model

- Card secrets (CARD_NUMBER, NAME_ON_CARD, EXPIRATION_MONTH, EXPIRATION_YEAR,
  SECURITY_CODE) live in the **biometric** vault tier — Touch ID is required
  every time they are accessed.
- Config secrets (PORT, DB_*, NODE_ENV, STORE_PASSWORD) live in the **open**
  vault tier — no authentication needed.
- The `.env.vault-template` lists key names only; values are blank for card
  fields and are never populated in the file.
- `vault exec` injects secrets into the child process environment. They are
  never written to disk, logged, or returned to the calling agent.
- The agent skill (`SKILL.md`) explicitly forbids `vault get`, writing secrets
  to files, or inspecting the child process environment.
