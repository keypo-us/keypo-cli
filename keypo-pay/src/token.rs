use alloy::primitives::{Address, U256};

use crate::config::TokenEntry;
use crate::error::{Error, Result};
use crate::rpc;

/// Queries the balance of a TIP-20 token for an account.
pub async fn query_balance(
    client: &reqwest::Client,
    rpc_url: &str,
    token: Address,
    account: Address,
) -> Result<U256> {
    let calldata = crate::transaction::encode_balance_of(account);
    let result = rpc::eth_call(client, rpc_url, token, &calldata).await?;
    if result.len() < 32 {
        return Ok(U256::ZERO);
    }
    Ok(U256::from_be_slice(&result[..32]))
}

/// Queries the decimals of a TIP-20 token.
pub async fn query_decimals(
    client: &reqwest::Client,
    rpc_url: &str,
    token: Address,
) -> Result<u8> {
    let calldata = crate::transaction::encode_decimals();
    let result = rpc::eth_call(client, rpc_url, token, &calldata).await?;
    if result.len() >= 32 {
        Ok(result[31])
    } else {
        Ok(18) // fallback
    }
}

/// Parses a human-readable token amount string into the smallest unit (wei-equivalent).
pub fn parse_token_amount(amount: &str, decimals: u8) -> Result<U256> {
    let amount_f64: f64 = amount
        .parse()
        .map_err(|e| Error::Other(format!("invalid amount '{}': {}", amount, e)))?;
    let multiplier = 10f64.powi(decimals as i32);
    Ok(U256::from((amount_f64 * multiplier) as u128))
}

/// Formats a token amount from smallest unit to human-readable string.
pub fn format_token_amount(amount: U256, decimals: u8) -> String {
    let divisor = 10f64.powi(decimals as i32);
    let value: f64 = amount.to::<u128>() as f64 / divisor;
    format!("{:.prec$}", value, prec = decimals as usize)
}

/// Resolves a token name or hex address to an Address.
pub fn resolve_token_address(
    name_or_address: &str,
    token_book: &[TokenEntry],
) -> Result<Address> {
    let addr_str = crate::config::resolve_token(name_or_address, token_book)?;
    addr_str
        .parse::<Address>()
        .map_err(|e| Error::Other(format!("invalid token address '{}': {}", addr_str, e)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_amount_6_decimals() {
        let amount = parse_token_amount("0.01", 6).unwrap();
        assert_eq!(amount, U256::from(10_000u64)); // 0.01 * 1e6 = 10000
    }

    #[test]
    fn parse_amount_18_decimals() {
        let amount = parse_token_amount("1.0", 18).unwrap();
        assert_eq!(amount, U256::from(1_000_000_000_000_000_000u128));
    }

    #[test]
    fn parse_amount_zero() {
        let amount = parse_token_amount("0", 6).unwrap();
        assert_eq!(amount, U256::ZERO);
    }

    #[test]
    fn parse_amount_invalid() {
        assert!(parse_token_amount("abc", 6).is_err());
    }

    #[test]
    fn format_amount_6_decimals() {
        let s = format_token_amount(U256::from(10_000u64), 6);
        assert_eq!(s, "0.010000");
    }

    #[test]
    fn format_amount_zero() {
        let s = format_token_amount(U256::ZERO, 6);
        assert_eq!(s, "0.000000");
    }

    #[test]
    fn format_amount_large() {
        let s = format_token_amount(U256::from(1_000_000u64), 6);
        assert_eq!(s, "1.000000");
    }
}
