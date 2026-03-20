---
title: Deployment and Secrets
owner: "@davidblumenfeld"
last_verified: 2026-03-19
status: current
---

# Deployment and Secrets

## Contract Deployment

### KeypoAccount

- **Address**: `0x6d1566f9aAcf9c06969D7BF846FA090703A38E43`
- **Method**: CREATE2 (deterministic across chains)
- **Chain**: Base Sepolia (chain ID 84532)
- **Verification**: Basescan verified

The address is deterministic -- the same bytecode + salt produces the same address on any EVM chain.

### Deployment Process

```bash
# Set up environment
export PATH="$HOME/.foundry/bin:$PATH"
cd keypo-account

# Deploy
forge script script/Deploy.s.sol --rpc-url https://sepolia.base.org \
  --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY

# The script writes deployment records to ../deployments/<chain-name>.json
```

Deployment records are committed to `deployments/` as the canonical record. See [deployments/README.md](../deployments/README.md) for the JSON format.

### Basescan Verification

If verification fails during deployment, verify manually:

```bash
forge verify-contract <address> src/KeypoAccount.sol:KeypoAccount \
  --chain base-sepolia --etherscan-api-key $BASESCAN_API_KEY
```

## Secrets Inventory

### Shared Secrets (`.env` + GitHub Actions)

| Secret | Purpose |
|---|---|
| `PIMLICO_API_KEY` | Pimlico bundler + paymaster API key |
| `BASE_SEPOLIA_RPC_URL` | Base Sepolia RPC endpoint (Pimlico bundler URL) |
| `BASESCAN_API_KEY` | Basescan API key for contract verification |
| `DEPLOYER_PRIVATE_KEY` | Funded account for `forge script` deployments |
| `TEST_FUNDER_PRIVATE_KEY` | Pre-funded account for automated integration tests |
| `PAYMASTER_URL` | ERC-7677 paymaster endpoint |

### Apple / Release Secrets (GitHub Actions only)

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded Developer ID certificate |
| `DEVELOPER_ID_CERT_PASSWORD` | Certificate password |
| `CI_KEYCHAIN_PASSWORD` | Temporary keychain password for CI |
| `DEVELOPER_ID_CERT_NAME` | Certificate identity string |
| `NOTARIZATION_APPLE_ID` | Apple ID for notarization |
| `NOTARIZATION_TEAM_ID` | Apple Developer Team ID |
| `NOTARIZATION_APP_PASSWORD` | App-specific password for notarization |
| `HOMEBREW_TAP_TOKEN` | GitHub token for Homebrew formula updates |

### Optional

| Secret | Purpose |
|---|---|
| `PIMLICO_SPONSORSHIP_POLICY_ID` | Paymaster sponsorship policy (optional, Pimlico auto-sponsors on testnet) |

## CI/CD Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `rust.yml` | Push/PR touching `keypo-wallet/` | Fmt, check, test, clippy |
| `swift.yml` | Push/PR touching `keypo-signer/` | Build + test on macOS |
| `foundry.yml` | Push/PR touching `keypo-account/` | Build + test with Foundry |
| `release.yml` | `v*` tag | Version check, tests, build, code-sign, notarize, GitHub release, Homebrew tap update |
| `docs.yml` | Push/PR touching `docs/**`, `CLAUDE.md`, `**/README.md` | Documentation freshness checks (links, metadata, staleness) |

### Release Process

1. Bump version in both `keypo-wallet/Cargo.toml` and `keypo-signer/Sources/KeypoCore/Models.swift`.
2. Tag the commit: `git tag v0.4.0 && git push --tags`.
3. `release.yml` runs:
   - Verifies tag version matches both `Cargo.toml` and `Models.swift`
   - Runs Swift tests (excluding vault integration tests) and Rust tests
   - Builds release binaries for both CLIs (arm64)
   - Code-signs both binaries with Developer ID certificate
   - Notarizes with Apple (up to 600s timeout)
   - Creates `tar.gz` archive containing both binaries + SHA256
   - Creates GitHub Release with the archive attached
   - Triggers `update-formula.yml` in `keypo-us/homebrew-tap` with version and SHA256

## Homebrew Formulas

Two formulas in `homebrew/Formula/`:

| Formula | Installs | Conflicts with |
|---|---|---|
| `keypo-wallet.rb` | Both `keypo-wallet` and `keypo-signer` binaries | `keypo-signer` |
| `keypo-signer.rb` | `keypo-signer` binary only | `keypo-wallet` |

The recommended install is `keypo-wallet` (includes both). The `keypo-signer` formula exists for users who only need vault and key management without wallet features.

Formula updates are triggered automatically by `release.yml` via the `HOMEBREW_TAP_TOKEN` secret. Users install via:

```bash
brew install keypo-us/tap/keypo-wallet    # both binaries
brew install keypo-us/tap/keypo-signer    # signer only
```
