# Deployment Records

This directory contains per-chain JSON files recording smart account contract deployments.

## Format

Each file is named `<chain-name>.json` (e.g., `base-sepolia.json`) and contains:

```json
{
  "chainId": 84532,
  "chainName": "base-sepolia",
  "implementation": {
    "address": "0x...",
    "deployTxHash": "0x...",
    "codeHash": "0x...",
    "deployedAt": "2026-03-01T00:00:00Z"
  },
  "deployer": "0x..."
}
```

| Field | Description |
|-------|-------------|
| `chainId` | EIP-155 chain ID |
| `chainName` | Human-readable chain identifier |
| `implementation.address` | Deployed contract address |
| `implementation.deployTxHash` | Transaction hash of the deployment |
| `implementation.codeHash` | keccak256 of the deployed bytecode (for verification) |
| `implementation.deployedAt` | ISO 8601 deployment timestamp |
| `deployer` | Address that submitted the deployment transaction |

## Usage

- **keypo-account deployment scripts** write these files after successful deployments
- **keypo-wallet Rust crate** reads these files to discover implementation addresses per chain
- Files are committed to version control as the canonical record of deployments
