use crate::error::{Error, Result};
use regex::Regex;
use std::sync::LazyLock;

static VAULT_NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z_][A-Za-z0-9_]{0,127}$").unwrap());

/// Validates a vault secret name against keypo-signer's naming rules.
///
/// Names must start with a letter or underscore, followed by up to 127
/// alphanumeric characters or underscores. Convention is SCREAMING_SNAKE_CASE.
pub fn validate_vault_name(name: &str) -> Result<()> {
    if VAULT_NAME_RE.is_match(name) {
        Ok(())
    } else {
        Err(Error::InvalidName(name.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_names() {
        let names = [
            "TELEGRAM_BOT_TOKEN",
            "ANTHROPIC_API_KEY",
            "A",
            "_PRIVATE",
            "a_lowercase",
            "MiXeD_CaSe_123",
            "_",
        ];
        for name in names {
            assert!(validate_vault_name(name).is_ok(), "expected valid: {name}");
        }
    }

    #[test]
    fn invalid_leading_digit() {
        assert!(validate_vault_name("1BAD").is_err());
    }

    #[test]
    fn invalid_special_chars() {
        assert!(validate_vault_name("BAD-NAME").is_err());
        assert!(validate_vault_name("BAD.NAME").is_err());
        assert!(validate_vault_name("BAD NAME").is_err());
    }

    #[test]
    fn invalid_empty() {
        assert!(validate_vault_name("").is_err());
    }

    #[test]
    fn invalid_too_long() {
        let name = "A".repeat(129);
        assert!(validate_vault_name(&name).is_err());
    }

    #[test]
    fn valid_max_length() {
        let name = "A".repeat(128);
        assert!(validate_vault_name(&name).is_ok());
    }
}
