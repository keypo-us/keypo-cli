use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error("keypo-signer not found: {0}")]
    SignerNotFound(String),

    #[error("keypo-signer command failed: {0}")]
    SignerCommand(String),

    #[error("keypo-signer output error: {0}")]
    SignerOutput(String),

    #[error("OpenClaw config not found: {0}")]
    ConfigNotFound(String),

    #[error("failed to parse config: {0}")]
    ConfigParse(String),

    #[error("failed to write config: {0}")]
    ConfigWrite(String),

    #[error("vault not initialized")]
    VaultNotInitialized,

    #[error("invalid secret name '{0}': names must match [A-Za-z_][A-Za-z0-9_]{{0,127}}")]
    InvalidName(String),

    #[error("secret '{0}' not found in vault")]
    #[allow(dead_code)]
    SecretNotFound(String),

    #[error("secret '{0}' already exists in the vault")]
    #[allow(dead_code)]
    SecretExists(String),

    #[error("conflict: {0}")]
    Conflict(String),

    #[error("protocol error: {0}")]
    #[allow(clippy::enum_variant_names)]
    Protocol(String),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("{0}")]
    Other(String),
}

impl Error {
    /// Returns an actionable hint for common error scenarios.
    pub fn suggestion(&self) -> Option<&'static str> {
        match self {
            Error::SignerNotFound(_) => {
                Some("Install with: brew install keypo-us/tap/keypo-signer")
            }
            Error::VaultNotInitialized => Some("Run: keypo-openclaw init"),
            Error::SecretExists(_) => Some("Use --update to change its value"),
            Error::SecretNotFound(_) => Some("Remove --update to create a new secret"),
            Error::ConfigNotFound(msg) if msg.contains("openclaw.json") => {
                Some("Is OpenClaw installed? Config expected at ~/.openclaw/openclaw.json")
            }
            Error::ConfigNotFound(msg) if msg.contains("auth-profiles") => {
                Some("Check that the agent exists and has an auth-profiles.json file")
            }
            _ => None,
        }
    }
}
