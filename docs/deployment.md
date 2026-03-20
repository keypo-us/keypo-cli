---
title: Deployment and Secrets
owner: "@davidblumenfeld"
last_verified: 2026-03-05
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
| `release-signer.yml` | `signer-v*` tag | Code-sign, notarize, create GitHub release |

### Release Process (keypo-signer)

1. Tag the commit: `git tag signer-v1.0.0 && git push --tags`
2. `release-signer.yml` runs: builds release binary, code-signs with Developer ID, notarizes with Apple, creates GitHub release with the binary attached.
3. Update `homebrew/Formula/keypo-signer.rb` with the new version, SHA256, and download URL.

## Homebrew Formula

The Homebrew formula is at `homebrew/Formula/keypo-signer.rb`. After a release:

1. Update `version`, `url`, and `sha256` in the formula.
2. Test locally: `brew install --build-from-source ./homebrew/Formula/keypo-signer.rb`
3. Commit and push. Users install via `brew tap keypo-us/tap && brew install keypo-signer`.
