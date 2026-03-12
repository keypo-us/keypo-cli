# Keypo Checkout Demo

Ask Claude Code to buy something from a Shopify store. Your credit card details
stay locked in the Keypo vault — the agent never sees them. When it's time to
pay, Touch ID appears on your Mac and you approve the transaction with your
fingerprint.

## How It Works

You say something like **"Buy the Keypo Logo Art"** in Claude Code. The agent
creates a checkout task, then runs a wrapper script that calls
`keypo-signer vault exec`. The vault decrypts your card details (Touch ID
required), injects them into a headless browser process, and completes the
Shopify checkout. You get an order confirmation email from Shopify.

```
┌─────────────────────────────────────────────┐
│  Claude Code (agent)                        │
│                                             │
│  "Buy the Keypo Logo Art"                   │
│       │                                     │
│       ▼                                     │
│  ./run-with-vault.sh <TASK_ID>              │
│       │                                     │
│  (waits for exit code + reads stdout)       │
│  (sees only status messages, never secrets) │
└───────┬─────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────┐
│  Child process (invisible to agent)         │
│                                             │
│  keypo-signer vault exec                    │
│       │                                     │
│       ├── open tier (no auth)               │
│       │   PORT, DB_*, STORE_PASSWORD        │
│       │                                     │
│       ├── biometric tier (Touch ID)         │
│       │   CARD_NUMBER, NAME_ON_CARD, …      │
│       │                                     │
│       ▼                                     │
│  Secrets injected into process.env          │
│       │                                     │
│       ▼                                     │
│  node start-task.js                         │
│  └── Puppeteer (headless browser)           │
│      └── Shopify checkout                   │
│          └── Types card into payment fields │
└─────────────────────────────────────────────┘
```

Everything below the dotted line happens in a child process that Claude Code
cannot inspect. The agent sees the process's stdout (status messages like
"Entering card details") and its exit code — nothing else. The secret values
exist only in the child process's environment and in the browser's memory.

## Setup

### Prerequisites

- **macOS** with Apple Silicon (Secure Enclave required)
- **keypo-signer** installed and vault initialized (`keypo-signer vault list`)
- **Node 18** (`nvm use 18`)
- **PostgreSQL** running locally (Homebrew or Docker)

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

### 2. Install dependencies

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

### 4. Import your secrets to the vault

Create two temporary files with your real values:

**.env.open** — non-sensitive config (open tier, no auth required):
```
PORT=8080
DB_USERNAME=sneakerbot
DB_PASSWORD=localdev
DB_NAME=sneakerbot_demo
DB_PORT=5432
DB_HOST=localhost
NODE_ENV=local
STORE_PASSWORD=your-store-password
```

**.env.card** — card secrets (biometric tier, Touch ID required):
```
CARD_NUMBER=your-card-number
NAME_ON_CARD=your-name
EXPIRATION_MONTH=MM
EXPIRATION_YEAR=YY
SECURITY_CODE=your-cvv
```

Import them:

```bash
keypo-signer vault import .env.open --policy open
keypo-signer vault import .env.card --policy biometric
```

Then delete the files — the secrets are now in the vault:

```bash
rm .env.open .env.card
```

### 5. Lock down the code

This prevents the agent from modifying the checkout scripts to exfiltrate
your card details. See [Tamper protection](#tamper-protection) for why this
matters.

```bash
sudo chown -R root:wheel run-with-vault.sh bot/
sudo chmod -R a+rX,go-w run-with-vault.sh bot/
```

### 6. Try it

Start the API server:

```bash
cd bot
NODE_ENV=local node ./scripts/start-api-server.js
```

Then open Claude Code in the project directory and ask it to buy something:

```
> Buy the Keypo Logo Art
```

Touch ID will appear — authenticate, and the agent completes the purchase.
You'll get an order confirmation email from Shopify.

## Usage

Once set up, the typical flow is:

1. Start Postgres and the API server (if not already running)
2. Open Claude Code in this directory
3. Ask it to buy a product (e.g., "Buy the Keypo Logo Art")
4. Approve with Touch ID when prompted
5. Check your email for the order confirmation

To shut everything down:

```bash
# Stop the API server
lsof -ti:8080 | xargs kill

# Stop Postgres (Homebrew)
brew services stop postgresql@14

# Or stop Postgres (Docker)
docker compose down
```

## Security Model

Your card details are protected by three layers:

1. **Biometric vault** — card secrets are encrypted with a Secure Enclave key
   that requires Touch ID to access. The agent cannot decrypt them without your
   fingerprint.

2. **Process isolation** — `vault exec` injects secrets into the child process
   environment only. They are never written to disk, logged, or returned to the
   agent. The agent sees stdout from the checkout process, which only contains
   status messages ("Entering card details"), not the values themselves.

3. **Tamper protection** — the wrapper script and bot code are root-owned, so
   the agent cannot modify them. See below.

### Tamper protection

An AI agent with file-write access could theoretically modify the checkout
scripts to exfiltrate secrets from `process.env` at runtime. There are three
files in the trust chain that must be protected:

1. **`run-with-vault.sh`** — pins the child command to `node ./scripts/start-task.js`.
   Without this, the agent could call `vault exec` with an arbitrary command
   like `env` or `bash -c 'echo $CARD_NUMBER'` and read secrets from stdout.
2. **`bot/scripts/start-task.js`** — the entry point that runs inside `vault exec`
   with secrets in `process.env`. If modified, it could log secrets before
   executing checkout logic.
3. **`bot/`** (all JS files) — any file in the execution chain (`cluster.js`,
   `shopify.js`, etc.) has access to `process.env` and could be modified to
   exfiltrate values.

Lock all three down by setting root ownership:

```bash
sudo chown -R root:wheel run-with-vault.sh bot/
sudo chmod -R a+rX,go-w run-with-vault.sh bot/
```

This works because Claude Code runs as your user and cannot modify root-owned
files. The agent can still *execute* `run-with-vault.sh` (it's world-readable
and executable), but cannot alter the wrapper, the entry point, or any code in
the execution chain.

When you need to update the bot code, temporarily reclaim ownership:

```bash
sudo chown -R $(whoami) run-with-vault.sh bot/
# ... make changes ...
sudo chown -R root:wheel run-with-vault.sh bot/
sudo chmod -R a+rX,go-w run-with-vault.sh bot/
```

## Files

| File | Purpose |
|---|---|
| `run-with-vault.sh` | Wrapper: `vault exec --env` → checkout process |
| `.env.vault-template` | Key-name manifest for `vault exec --env` |
| `SKILL.md` | Claude Code agent skill definition |
| `docker-compose.yml` | Postgres-only compose (alternative to Homebrew) |
| `seed-data/` | Address and site reference data |
| `bot/` | Checkout bot (fork of [SneakerBot](https://github.com/samc621/SneakerBot)) |

## Credits

The checkout automation is built on [SneakerBot](https://github.com/samc621/SneakerBot)
by [Samuel Corso](https://github.com/samc621), modified for modern Shopify
single-page checkout and headless operation.
