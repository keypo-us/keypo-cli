---
title: Deployment and Secrets
owner: "@davidblumenfeld"
last_verified: 2026-03-23
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
| `release-openclaw.yml` | `openclaw-v*` tag | Build, test, code-sign, notarize, GitHub release, Homebrew tap update (keypo-openclaw only) |
| `docs.yml` | Push/PR touching `docs/**`, `CLAUDE.md`, `**/README.md` | Documentation freshness checks (links, metadata, staleness) |

### Release Process: keypo-signer + keypo-wallet

These share a version and release together via the `v*` tag pattern.

1. Bump version in both `keypo-wallet/Cargo.toml` and `keypo-signer/Sources/KeypoCore/Models.swift`.
2. Commit: `git commit -m "v0.4.3: description of changes"`.
3. Tag and push: `git tag v0.4.3 && git push origin main --tags`.
4. `release.yml` runs automatically:
   - Verifies tag version matches both `Cargo.toml` and `Models.swift`
   - Runs Swift tests (excluding vault integration tests) and Rust tests
   - Builds release binaries for both CLIs (arm64)
   - Code-signs both binaries with Developer ID certificate
   - Notarizes with Apple (up to 600s timeout)
   - Creates `tar.gz` archive containing both binaries + SHA256
   - Creates GitHub Release with the archive attached
   - Triggers `update-formula.yml` in `keypo-us/homebrew-tap` with version and SHA256

### Release Process: keypo-openclaw

keypo-openclaw has an independent version and release cycle via the `openclaw-v*` tag pattern.

1. Bump version in `keypo-openclaw/Cargo.toml`.
2. Commit: `git commit -m "openclaw v0.1.0: description of changes"`.
3. Tag and push: `git tag openclaw-v0.1.0 && git push origin main --tags`.
4. `release-openclaw.yml` runs automatically:
   - Verifies tag version matches `keypo-openclaw/Cargo.toml`
   - Runs Rust tests and clippy
   - Builds release binary (arm64)
   - Code-signs with Developer ID certificate
   - Notarizes with Apple
   - Creates `keypo-openclaw-{version}-macos-arm64.tar.gz` + SHA256
   - Creates GitHub Release with the archive attached
   - Triggers `update-openclaw-formula.yml` in `keypo-us/homebrew-tap` with version and SHA256

## Homebrew Formulas

Three formulas in `homebrew/Formula/`:

| Formula | Installs | Dependencies | Conflicts with |
|---|---|---|---|
| `keypo-wallet.rb` | `keypo-wallet` + `keypo-signer` binaries | — | `keypo-signer` |
| `keypo-signer.rb` | `keypo-signer` binary only | — | `keypo-wallet` |
| `keypo-openclaw.rb` | `keypo-openclaw` binary | `keypo-signer` | — |

The recommended install for wallet users is `keypo-wallet` (includes both). The `keypo-signer` formula exists for users who only need vault and key management. `keypo-openclaw` is for OpenClaw users and automatically installs `keypo-signer` as a dependency.

Formula updates are triggered automatically by the release workflows via the `HOMEBREW_TAP_TOKEN` secret. The tap repo (`keypo-us/homebrew-tap`) has two update workflows:
- `update-formula.yml` — updates `keypo-wallet.rb` (triggered by `release.yml`)
- `update-openclaw-formula.yml` — updates `keypo-openclaw.rb` (triggered by `release-openclaw.yml`)

Users install via:

```bash
brew install keypo-us/tap/keypo-wallet    # wallet + signer
brew install keypo-us/tap/keypo-signer    # signer only
brew install keypo-us/tap/keypo-openclaw  # openclaw integration (installs signer as dependency)
```
