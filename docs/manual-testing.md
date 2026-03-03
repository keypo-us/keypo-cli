# Manual Testing Checklist

End-to-end tests that require a macOS machine with Secure Enclave access and Base Sepolia ETH.

## Prerequisites

- macOS with Touch ID / Secure Enclave
- `keypo-signer` installed (`brew install keypo-us/tap/keypo-signer`)
- `keypo-wallet` built (`cd keypo-wallet && cargo build`)
- `.env` populated with `PIMLICO_API_KEY`, `BASE_SEPOLIA_RPC_URL`, `PAYMASTER_URL`
- Base Sepolia ETH available (faucet or existing funded account)

## 1. Full Setup + Send

```bash
# Create a new key
keypo-signer create --label test-manual --policy biometric

# Set up account on Base Sepolia
keypo-wallet setup --key test-manual --rpc https://sepolia.base.org

# Verify account info
keypo-wallet info --key test-manual

# Send a self-transfer (0 ETH)
keypo-wallet send --key test-manual \
  --to <ACCOUNT_ADDRESS> \
  --value 0 \
  --bundler $BASE_SEPOLIA_RPC_URL \
  --paymaster $PAYMASTER_URL
```

- [ ] Setup completes with address, tx hash, chain ID
- [ ] Info shows correct address and chain deployment
- [ ] Send returns UserOp hash, tx hash, success=true

## 2. Paymaster-Sponsored Transaction

```bash
keypo-wallet send --key test-manual \
  --to 0x0000000000000000000000000000000000000001 \
  --value 0 \
  --bundler $BASE_SEPOLIA_RPC_URL \
  --paymaster $PAYMASTER_URL \
  --paymaster-policy $PIMLICO_SPONSORSHIP_POLICY_ID
```

- [ ] Transaction succeeds without account holding ETH for gas
- [ ] Block explorer shows paymaster paid gas

## 3. Batch Transaction

Create `test-batch.json`:
```json
[
  {"to": "0x0000000000000000000000000000000000000001", "value": "0x0", "data": "0x"},
  {"to": "0x0000000000000000000000000000000000000002", "value": "0x0", "data": "0x"}
]
```

```bash
keypo-wallet batch --key test-manual \
  --calls test-batch.json \
  --bundler $BASE_SEPOLIA_RPC_URL \
  --paymaster $PAYMASTER_URL
```

- [ ] Batch transaction succeeds
- [ ] Both calls executed in a single on-chain transaction

## 4. Balance Queries

```bash
# Table format (default)
keypo-wallet balance --key test-manual

# JSON format
keypo-wallet balance --key test-manual --format json

# CSV format
keypo-wallet balance --key test-manual --format csv

# With RPC override
keypo-wallet balance --key test-manual --rpc https://sepolia.base.org
```

- [ ] Table output shows aligned columns with chain, token, balance
- [ ] JSON output is valid JSON with account address and balances array
- [ ] CSV output has proper header row and quoted fields

## 5. Error Scenarios

```bash
# Wrong key label
keypo-wallet info --key nonexistent-key
# Expected: "Error: no account found..." with hint to run setup

# Missing keypo-signer binary (temporarily rename it)
keypo-wallet setup --key test --rpc https://sepolia.base.org
# Expected: "Error: signer not found..." with Homebrew install hint

# Bad address
keypo-wallet send --key test-manual --to not-an-address --bundler $BASE_SEPOLIA_RPC_URL
# Expected: "Error: invalid --to address..."

# Verbose output
keypo-wallet --verbose balance --key test-manual --rpc https://sepolia.base.org
# Expected: DEBUG-level log lines visible
```

- [ ] Error messages include actionable hints where applicable
- [ ] `--verbose` shows debug output scoped to `keypo_wallet`
