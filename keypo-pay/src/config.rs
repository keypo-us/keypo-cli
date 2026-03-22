use std::path::{Path, PathBuf};

use alloy::primitives::Address;
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};

// ---------------------------------------------------------------------------
// Testnet defaults
// ---------------------------------------------------------------------------

pub const TESTNET_RPC_URL: &str = "https://rpc.moderato.tempo.xyz";
pub const TESTNET_CHAIN_ID: u64 = 42431; // Tempo moderato testnet (0xa5bf)
pub const TESTNET_EXPLORER_URL: &str = "https://explore.moderato.tempo.xyz";

pub const TESTNET_TOKENS: &[(&str, &str)] = &[
    ("pathusd", "0x20c0000000000000000000000000000000000000"),
    ("alphausd", "0x20c0000000000000000000000000000000000001"),
    ("betausd", "0x20c0000000000000000000000000000000000002"),
    ("thetausd", "0x20c0000000000000000000000000000000000003"),
];

// ---------------------------------------------------------------------------
// Config types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WalletConfig {
    pub chain_id: u64,
    pub rpc_url: String,
    pub root_key_id: String,
    pub address: String, // hex address stored as string for TOML compatibility
    #[serde(default)]
    pub default_token: Option<String>,
    #[serde(default)]
    pub block_explorer_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccessKeyEntry {
    pub name: String,
    pub key_id: String,
    pub address: String, // hex address stored as string for TOML compatibility
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TokenEntry {
    pub name: String,
    pub address: String, // hex address stored as string for TOML compatibility
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AccessKeysFile {
    #[serde(default)]
    pub keys: Vec<AccessKeyEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TokensFile {
    #[serde(default)]
    pub tokens: Vec<TokenEntry>,
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

pub fn tempo_config_dir() -> Result<PathBuf> {
    let home = dirs::home_dir()
        .ok_or_else(|| Error::Other("could not determine home directory".into()))?;
    Ok(home.join(".keypo").join("tempo"))
}

pub fn wallet_config_path() -> Result<PathBuf> {
    Ok(tempo_config_dir()?.join("wallet.toml"))
}

pub fn access_keys_path() -> Result<PathBuf> {
    Ok(tempo_config_dir()?.join("access-keys.toml"))
}

pub fn tokens_path() -> Result<PathBuf> {
    Ok(tempo_config_dir()?.join("tokens.toml"))
}

// ---------------------------------------------------------------------------
// Load
// ---------------------------------------------------------------------------

pub fn load_wallet_config() -> Result<WalletConfig> {
    load_wallet_config_at(&wallet_config_path()?)
}

pub fn load_wallet_config_at(path: &Path) -> Result<WalletConfig> {
    if !path.exists() {
        return Err(Error::NoWallet);
    }
    let raw = std::fs::read_to_string(path)?;
    toml::from_str(&raw).map_err(|e| Error::ConfigParse(format!("invalid wallet.toml: {e}")))
}

pub fn load_access_keys() -> Result<AccessKeysFile> {
    load_access_keys_at(&access_keys_path()?)
}

pub fn load_access_keys_at(path: &Path) -> Result<AccessKeysFile> {
    if !path.exists() {
        return Ok(AccessKeysFile::default());
    }
    let raw = std::fs::read_to_string(path)?;
    toml::from_str(&raw)
        .map_err(|e| Error::ConfigParse(format!("invalid access-keys.toml: {e}")))
}

pub fn load_tokens() -> Result<TokensFile> {
    load_tokens_at(&tokens_path()?)
}

pub fn load_tokens_at(path: &Path) -> Result<TokensFile> {
    if !path.exists() {
        return Ok(TokensFile::default());
    }
    let raw = std::fs::read_to_string(path)?;
    toml::from_str(&raw).map_err(|e| Error::ConfigParse(format!("invalid tokens.toml: {e}")))
}

// ---------------------------------------------------------------------------
// Save (atomic write: tmp + rename)
// ---------------------------------------------------------------------------

fn ensure_dir(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.exists() {
            std::fs::create_dir_all(parent)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
            }
        }
    }
    Ok(())
}

fn atomic_write(path: &Path, content: &str) -> Result<()> {
    ensure_dir(path)?;
    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, content)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

pub fn save_wallet_config(config: &WalletConfig) -> Result<()> {
    save_wallet_config_at(config, &wallet_config_path()?)
}

pub fn save_wallet_config_at(config: &WalletConfig, path: &Path) -> Result<()> {
    let toml_str =
        toml::to_string_pretty(config).map_err(|e| Error::Other(format!("TOML serialize: {e}")))?;
    atomic_write(path, &toml_str)
}

pub fn save_access_keys(file: &AccessKeysFile) -> Result<()> {
    save_access_keys_at(file, &access_keys_path()?)
}

pub fn save_access_keys_at(file: &AccessKeysFile, path: &Path) -> Result<()> {
    let toml_str =
        toml::to_string_pretty(file).map_err(|e| Error::Other(format!("TOML serialize: {e}")))?;
    atomic_write(path, &toml_str)
}

pub fn save_tokens(file: &TokensFile) -> Result<()> {
    save_tokens_at(file, &tokens_path()?)
}

pub fn save_tokens_at(file: &TokensFile, path: &Path) -> Result<()> {
    let toml_str =
        toml::to_string_pretty(file).map_err(|e| Error::Other(format!("TOML serialize: {e}")))?;
    atomic_write(path, &toml_str)
}

// ---------------------------------------------------------------------------
// Token resolution
// ---------------------------------------------------------------------------

/// Resolves a token name or hex address to a hex address string.
pub fn resolve_token(name_or_address: &str, tokens: &[TokenEntry]) -> Result<String> {
    // If it looks like a hex address, return as-is
    if name_or_address.starts_with("0x") || name_or_address.starts_with("0X") {
        return Ok(name_or_address.to_string());
    }
    // Look up by name (case-insensitive)
    let lower = name_or_address.to_lowercase();
    tokens
        .iter()
        .find(|t| t.name.to_lowercase() == lower)
        .map(|t| t.address.clone())
        .ok_or_else(|| Error::TokenNotFound(name_or_address.to_string()))
}

// ---------------------------------------------------------------------------
// Default token population
// ---------------------------------------------------------------------------

pub fn default_testnet_tokens() -> TokensFile {
    TokensFile {
        tokens: TESTNET_TOKENS
            .iter()
            .map(|(name, addr)| TokenEntry {
                name: name.to_string(),
                address: addr.to_string(),
            })
            .collect(),
    }
}

// ---------------------------------------------------------------------------
// Value resolution (4-tier: CLI > env > config > error)
// ---------------------------------------------------------------------------

pub fn resolve_value(cli: Option<&str>, env_var: &str, config_val: Option<&str>) -> Option<String> {
    if let Some(v) = cli {
        tracing::debug!("{env_var} resolved from CLI flag");
        return Some(v.to_string());
    }
    if let Ok(v) = std::env::var(env_var) {
        if !v.is_empty() {
            tracing::debug!("{env_var} resolved from env var");
            return Some(v);
        }
    }
    if let Some(v) = config_val {
        tracing::debug!("{env_var} resolved from config file");
        return Some(v.to_string());
    }
    None
}

pub fn resolve_rpc(cli: Option<&str>, wallet: &WalletConfig) -> String {
    resolve_value(cli, "KEYPO_PAY_RPC_URL", Some(&wallet.rpc_url))
        .unwrap_or_else(|| wallet.rpc_url.clone())
}

/// Validates a URL string.
pub fn validate_url(u: &str, field: &str) -> Result<()> {
    let parsed: url::Url = u
        .parse()
        .map_err(|e: url::ParseError| Error::ConfigParse(format!("{field}: invalid URL: {e}")))?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err(Error::ConfigParse(format!(
            "{field}: URL scheme must be http or https, got '{}'",
            parsed.scheme()
        )));
    }
    Ok(())
}

/// Parses a hex address string into an alloy Address.
pub fn parse_address(s: &str) -> Result<Address> {
    s.parse::<Address>()
        .map_err(|e| Error::ConfigParse(format!("invalid address '{}': {}", s, e)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn wallet_config_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("wallet.toml");

        let config = WalletConfig {
            chain_id: 12345,
            rpc_url: "https://rpc.example.com".into(),
            root_key_id: "com.keypo.signer.root-key".into(),
            address: "0x1234567890abcdef1234567890abcdef12345678".into(),
            default_token: Some("pathusd".into()),
            block_explorer_url: None,
        };

        save_wallet_config_at(&config, &path).unwrap();
        let loaded = load_wallet_config_at(&path).unwrap();
        assert_eq!(loaded.chain_id, 12345);
        assert_eq!(loaded.rpc_url, "https://rpc.example.com");
        assert_eq!(loaded.root_key_id, "com.keypo.signer.root-key");
        assert_eq!(loaded.default_token, Some("pathusd".into()));
    }

    #[test]
    fn load_wallet_config_missing_returns_no_wallet() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("wallet.toml");
        let result = load_wallet_config_at(&path);
        assert!(matches!(result.unwrap_err(), Error::NoWallet));
    }

    #[test]
    fn access_keys_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("access-keys.toml");

        let file = AccessKeysFile {
            keys: vec![AccessKeyEntry {
                name: "agent-1".into(),
                key_id: "com.keypo.signer.agent-1".into(),
                address: "0xdeadbeef00000000000000000000000000000001".into(),
            }],
        };

        save_access_keys_at(&file, &path).unwrap();
        let loaded = load_access_keys_at(&path).unwrap();
        assert_eq!(loaded.keys.len(), 1);
        assert_eq!(loaded.keys[0].name, "agent-1");
    }

    #[test]
    fn access_keys_missing_returns_empty() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("access-keys.toml");
        let file = load_access_keys_at(&path).unwrap();
        assert!(file.keys.is_empty());
    }

    #[test]
    fn tokens_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("tokens.toml");

        let file = TokensFile {
            tokens: vec![TokenEntry {
                name: "pathusd".into(),
                address: "0x20c0000000000000000000000000000000000000".into(),
            }],
        };

        save_tokens_at(&file, &path).unwrap();
        let loaded = load_tokens_at(&path).unwrap();
        assert_eq!(loaded.tokens.len(), 1);
        assert_eq!(loaded.tokens[0].name, "pathusd");
    }

    #[test]
    fn default_testnet_tokens_has_four_entries() {
        let tokens = default_testnet_tokens();
        assert_eq!(tokens.tokens.len(), 4);
        assert_eq!(tokens.tokens[0].name, "pathusd");
        assert_eq!(tokens.tokens[1].name, "alphausd");
        assert_eq!(tokens.tokens[2].name, "betausd");
        assert_eq!(tokens.tokens[3].name, "thetausd");
    }

    #[test]
    fn resolve_token_by_name() {
        let tokens = default_testnet_tokens();
        let addr = resolve_token("pathusd", &tokens.tokens).unwrap();
        assert_eq!(addr, "0x20c0000000000000000000000000000000000000");
    }

    #[test]
    fn resolve_token_by_name_case_insensitive() {
        let tokens = default_testnet_tokens();
        let addr = resolve_token("PathUSD", &tokens.tokens).unwrap();
        assert_eq!(addr, "0x20c0000000000000000000000000000000000000");
    }

    #[test]
    fn resolve_token_by_address_passthrough() {
        let tokens = default_testnet_tokens();
        let addr = resolve_token("0xdeadbeef", &tokens.tokens).unwrap();
        assert_eq!(addr, "0xdeadbeef");
    }

    #[test]
    fn resolve_token_unknown_name_errors() {
        let tokens = default_testnet_tokens();
        let result = resolve_token("unknown", &tokens.tokens);
        assert!(matches!(result.unwrap_err(), Error::TokenNotFound(_)));
    }

    #[test]
    fn resolve_value_cli_wins() {
        let result = resolve_value(Some("from-cli"), "KEYPO_PAY_TEST_UNUSED", Some("from-config"));
        assert_eq!(result, Some("from-cli".into()));
    }

    #[test]
    fn resolve_value_config_fallback() {
        std::env::remove_var("KEYPO_PAY_TEST_RESOLVE_NONE");
        let result = resolve_value(None, "KEYPO_PAY_TEST_RESOLVE_NONE", Some("from-config"));
        assert_eq!(result, Some("from-config".into()));
    }

    #[test]
    fn resolve_value_all_none() {
        std::env::remove_var("KEYPO_PAY_TEST_RESOLVE_ALL_NONE");
        let result = resolve_value(None, "KEYPO_PAY_TEST_RESOLVE_ALL_NONE", None);
        assert!(result.is_none());
    }

    #[test]
    fn validate_url_valid() {
        assert!(validate_url("https://rpc.example.com", "test").is_ok());
        assert!(validate_url("http://localhost:8545", "test").is_ok());
    }

    #[test]
    fn validate_url_invalid() {
        assert!(validate_url("not-a-url", "test").is_err());
        assert!(validate_url("ftp://example.com", "test").is_err());
    }

    #[test]
    fn idempotency_guard() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("wallet.toml");

        let config = WalletConfig {
            chain_id: 1,
            rpc_url: "https://rpc.example.com".into(),
            root_key_id: "key-1".into(),
            address: "0x0000000000000000000000000000000000000001".into(),
            default_token: None,
            block_explorer_url: None,
        };

        save_wallet_config_at(&config, &path).unwrap();
        // Second save should still work (overwrite)
        save_wallet_config_at(&config, &path).unwrap();
        // But wallet_exists check works
        assert!(path.exists());
    }
}
