use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("signer not found: {0}")]
    SignerNotFound(String),

    #[error("signer command failed: {0}")]
    SignerCommand(String),

    #[error("signer output error: {0}")]
    SignerOutput(String),

    #[error("state I/O error: {0}")]
    StateIO(#[from] std::io::Error),

    #[error("state format error: {0}")]
    StateFormat(#[from] serde_json::Error),

    #[error("ABI encoding error: {0}")]
    AbiEncoding(String),

    #[error("provider error: {0}")]
    Provider(String),

    #[error("bundler error: {0}")]
    Bundler(String),

    #[error("paymaster error: {0}")]
    Paymaster(String),

    #[error("account not found: {0}")]
    AccountNotFound(String),

    #[error("chain not deployed: {0}")]
    ChainNotDeployed(u64),

    #[error("duplicate deployment: key {key_label} already deployed on chain {chain_id}")]
    DuplicateDeployment { key_label: String, chain_id: u64 },

    #[error("funding timeout: waited {0}s for {1}")]
    FundingTimeout(u64, alloy::primitives::Address),

    #[error("implementation not deployed at {0}")]
    ImplementationNotDeployed(alloy::primitives::Address),

    #[error("delegation failed: expected {expected}, got {got}")]
    DelegationFailed { expected: String, got: String },

    #[error("transaction failed: {0}")]
    TransactionFailed(String),

    #[error("multi-chain setup not supported: key '{0}' already has an account")]
    MultiChainNotSupported(String),

    #[error("receipt timeout: waited {0}s for UserOp {1}")]
    ReceiptTimeout(u64, String),

    #[error("{0}")]
    Other(String),
}

impl Error {
    /// Returns an actionable hint for common error scenarios.
    pub fn suggestion(&self) -> Option<&'static str> {
        match self {
            Error::SignerNotFound(_) => Some("Install via: brew install keypo-us/tap/keypo-signer"),
            Error::SignerCommand(msg) if msg.contains("exited with") => {
                Some("Check that the key label exists: keypo-signer list --format json")
            }
            Error::AccountNotFound(_) => {
                Some("Run 'keypo-wallet setup' first to create an account")
            }
            Error::ChainNotDeployed(_) => {
                Some("Run 'keypo-wallet info' to see deployed chains for this key.")
            }
            Error::FundingTimeout(..) => {
                Some("Send ETH to the address and retry, or use --paymaster for gas sponsorship")
            }
            Error::ImplementationNotDeployed(_) => {
                Some("Check the contract address or use --implementation to specify")
            }
            Error::ReceiptTimeout(..) => {
                Some("The transaction may still be pending. Check the block explorer.")
            }
            Error::Bundler(msg) if msg.contains("AA21") => {
                Some("Insufficient funds for gas. Fund the account or use --paymaster.")
            }
            Error::Bundler(msg) if msg.contains("AA25") => {
                Some("Invalid nonce. The account may have a pending UserOp.")
            }
            Error::Bundler(msg) if msg.contains("AA33") || msg.contains("AA34") => Some(
                "Paymaster rejected the operation. Check --paymaster URL and --paymaster-policy.",
            ),
            Error::Paymaster(_) => Some("Check your --paymaster URL and --paymaster-policy ID."),
            Error::DuplicateDeployment { .. } => Some(
                "This key already has an account on this chain. Use 'keypo-wallet info' to see it.",
            ),
            Error::MultiChainNotSupported(_) => Some("Multi-chain setup is not yet supported."),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suggestion_signer_not_found() {
        let err = Error::SignerNotFound("keypo-signer".into());
        assert!(err.suggestion().unwrap().contains("brew install"));
    }

    #[test]
    fn suggestion_bundler_aa21() {
        let err = Error::Bundler("AA21 didn't pay prefund".into());
        assert!(err.suggestion().unwrap().contains("Fund the account"));
    }

    #[test]
    fn suggestion_account_not_found() {
        let err = Error::AccountNotFound("my-key".into());
        assert!(err.suggestion().unwrap().contains("setup"));
    }

    #[test]
    fn suggestion_none_for_other() {
        let err = Error::Other("something".into());
        assert!(err.suggestion().is_none());
    }
}
