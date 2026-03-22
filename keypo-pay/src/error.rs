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

    #[error("config I/O error: {0}")]
    ConfigIO(#[from] std::io::Error),

    #[error("config file malformed: {0}")]
    ConfigParse(String),

    #[error("missing required config: {0}")]
    ConfigMissing(String),

    #[error("wallet already exists at {0}")]
    WalletExists(String),

    #[error("no wallet found")]
    NoWallet,

    #[error("access key '{0}' already exists")]
    DuplicateAccessKey(String),

    #[error("access key '{0}' not found")]
    AccessKeyNotFound(String),

    #[error("token '{0}' not found in address book")]
    TokenNotFound(String),

    #[error("transaction failed: {0}")]
    TransactionFailed(String),

    #[error("RPC error: {0}")]
    Rpc(String),

    #[error("{0}")]
    Other(String),
}

impl Error {
    /// Returns an actionable hint for common error scenarios.
    pub fn suggestion(&self) -> Option<&'static str> {
        match self {
            Error::SignerNotFound(_) => {
                Some("Install via: brew install keypo-us/tap/keypo-signer")
            }
            Error::SignerCommand(msg) if msg.contains("exited with") => {
                Some("Check that the key label exists: keypo-signer list --format json")
            }
            Error::NoWallet => Some("Run 'keypo-pay wallet create' to create a wallet."),
            Error::ConfigMissing(_) => Some(
                "Run 'keypo-pay wallet create' to initialize, or pass the value as a CLI flag.",
            ),
            Error::WalletExists(_) => {
                Some("Delete the existing wallet config first if you want to recreate.")
            }
            Error::AccessKeyNotFound(_) => {
                Some("Run 'keypo-pay access-key list' to see available keys.")
            }
            Error::TokenNotFound(_) => {
                Some("Run 'keypo-pay token list' to see known tokens, or use a hex address.")
            }
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
    fn suggestion_no_wallet() {
        let err = Error::NoWallet;
        assert!(err.suggestion().unwrap().contains("wallet create"));
    }

    #[test]
    fn suggestion_none_for_other() {
        let err = Error::Other("something".into());
        assert!(err.suggestion().is_none());
    }
}
