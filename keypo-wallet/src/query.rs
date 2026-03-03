use std::collections::BTreeMap;

use alloy::primitives::{Address, Bytes, U256};
use alloy::providers::Provider;
use alloy::sol;
use alloy::sol_types::{SolCall, SolValue};
use serde::Serialize;

use crate::error::{Error, Result};
use crate::types::{AccountRecord, BalanceQuery, ChainDeployment, TokenBalance};

// ---------------------------------------------------------------------------
// Static chain name lookup
// ---------------------------------------------------------------------------

pub fn chain_name(chain_id: u64) -> Option<&'static str> {
    match chain_id {
        1 => Some("Ethereum"),
        10 => Some("Optimism"),
        8453 => Some("Base"),
        42161 => Some("Arbitrum"),
        11155111 => Some("Sepolia"),
        84532 => Some("Base Sepolia"),
        11155420 => Some("OP Sepolia"),
        421614 => Some("Arbitrum Sepolia"),
        _ => None,
    }
}

pub fn display_chain(chain_id: u64) -> String {
    match chain_name(chain_id) {
        Some(name) => format!("{name} ({chain_id})"),
        None => format!("Chain {chain_id}"),
    }
}

// ---------------------------------------------------------------------------
// Address helpers
// ---------------------------------------------------------------------------

pub fn short_address(addr: Address) -> String {
    let s = format!("{addr}");
    // "0xAbCd...1234" — first 6 chars + last 4 chars
    format!("{}...{}", &s[..6], &s[s.len() - 4..])
}

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

pub fn is_native_token(token: &str) -> bool {
    token.eq_ignore_ascii_case("ETH")
}

// ---------------------------------------------------------------------------
// Balance formatting
// ---------------------------------------------------------------------------

pub fn format_balance(balance: U256, decimals: u8) -> String {
    if balance.is_zero() {
        return "0.000000".to_string();
    }

    let decimals = decimals as usize;
    if decimals == 0 {
        return format!("{balance}.000000");
    }

    let divisor = U256::from(10).pow(U256::from(decimals));
    let whole = balance / divisor;
    let frac = balance % divisor;

    let frac_str = format!("{frac}");
    // Zero-pad to `decimals` digits
    let frac_padded = format!("{:0>width$}", frac_str, width = decimals);

    let displayed = if decimals > 6 {
        frac_padded[..6].to_string()
    } else {
        format!("{:0<6}", frac_padded)
    };

    if whole.is_zero() && displayed == "000000" {
        return "< 0.000001".to_string();
    }

    format!("{whole}.{displayed}")
}

// ---------------------------------------------------------------------------
// Decimal string ↔ raw units
// ---------------------------------------------------------------------------

pub fn parse_decimal_to_raw(s: &str, decimals: u8) -> Option<U256> {
    let decimals = decimals as usize;
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() > 2 {
        return None;
    }

    let integer_str = parts[0];
    let integer_part: U256 = integer_str.parse().ok()?;

    let multiplier = U256::from(10).pow(U256::from(decimals));

    if parts.len() == 1 || parts[1].is_empty() {
        return Some(integer_part * multiplier);
    }

    let frac_str = parts[1];
    // Pad or truncate fractional part to `decimals` digits
    let adjusted = if frac_str.len() > decimals {
        &frac_str[..decimals]
    } else {
        // Need to right-pad with zeros — use a temporary string
        &format!("{:0<width$}", frac_str, width = decimals)
    };

    if decimals == 0 {
        return Some(integer_part);
    }

    let fractional_part: U256 = adjusted.parse().ok()?;
    Some(integer_part * multiplier + fractional_part)
}

// ---------------------------------------------------------------------------
// Token resolution
// ---------------------------------------------------------------------------

pub fn resolve_tokens(
    cli_token: Option<&str>,
    query: Option<&BalanceQuery>,
) -> Result<Vec<String>> {
    let mut tokens = match (cli_token, query) {
        (Some(t), _) => {
            // CLI --token overrides everything
            vec![t.to_string()]
        }
        (None, Some(q)) => {
            if let Some(ref tf) = q.tokens {
                if !tf.include.is_empty() {
                    tf.include.clone()
                } else {
                    vec!["ETH".to_string()]
                }
            } else {
                vec!["ETH".to_string()]
            }
        }
        (None, None) => vec!["ETH".to_string()],
    };

    // Normalize ETH variants
    for t in &mut tokens {
        if is_native_token(t) {
            *t = "ETH".to_string();
        }
    }

    // Validate and normalize non-ETH tokens as addresses
    for t in &mut tokens {
        if !is_native_token(t) {
            let addr: Address = t.parse().map_err(|_| {
                Error::Other(format!(
                    "invalid token address: '{t}'. Symbol-based lookup is not yet supported — use the contract address instead."
                ))
            })?;
            *t = addr.to_checksum(None);
        }
    }

    // Dedup
    tokens.sort();
    tokens.dedup();

    // Apply exclude filter from query
    if let Some(q) = query {
        if let Some(ref tf) = q.tokens {
            if !tf.exclude.is_empty() {
                tokens.retain(|t| {
                    !tf.exclude.iter().any(|ex| {
                        if is_native_token(ex) && is_native_token(t) {
                            true
                        } else if let (Ok(addr_t), Ok(addr_ex)) =
                            (t.parse::<Address>(), ex.parse::<Address>())
                        {
                            addr_t == addr_ex
                        } else {
                            false
                        }
                    })
                });
            }
        }
    }

    Ok(tokens)
}

// ---------------------------------------------------------------------------
// Chain resolution
// ---------------------------------------------------------------------------

pub fn resolve_chains<'a>(
    account: &'a AccountRecord,
    cli_chain_id: Option<u64>,
    query: Option<&BalanceQuery>,
) -> Result<Vec<&'a ChainDeployment>> {
    let filter_ids: Option<Vec<u64>> = if let Some(cid) = cli_chain_id {
        Some(vec![cid])
    } else {
        query
            .filter(|q| !q.chains.is_empty())
            .map(|q| q.chains.clone())
    };

    let chains: Vec<&ChainDeployment> = match filter_ids {
        Some(ids) => account
            .chains
            .iter()
            .filter(|c| ids.contains(&c.chain_id))
            .collect(),
        None => account.chains.iter().collect(),
    };

    if chains.is_empty() {
        let available: Vec<String> = account
            .chains
            .iter()
            .map(|c| display_chain(c.chain_id))
            .collect();
        return Err(Error::Other(format!(
            "no matching chains for key '{}'. Available: {}",
            account.key_label,
            available.join(", ")
        )));
    }

    Ok(chains)
}

// ---------------------------------------------------------------------------
// Min balance filter
// ---------------------------------------------------------------------------

pub fn apply_min_balance_filter(balances: &mut Vec<TokenBalance>, min_balance: Option<&str>) {
    let Some(threshold_str) = min_balance else {
        return;
    };
    balances.retain(|tb| {
        match parse_decimal_to_raw(threshold_str, tb.decimals) {
            Some(threshold) => tb.balance >= threshold,
            None => true, // unparseable → keep (conservative)
        }
    });
}

// ---------------------------------------------------------------------------
// Display label
// ---------------------------------------------------------------------------

pub fn display_label(tb: &TokenBalance) -> String {
    if is_native_token(&tb.token) {
        "ETH".to_string()
    } else if let Some(ref sym) = tb.symbol {
        sym.clone()
    } else {
        tb.token
            .parse::<Address>()
            .map(short_address)
            .unwrap_or_else(|_| tb.token.clone())
    }
}

// ---------------------------------------------------------------------------
// Sorting
// ---------------------------------------------------------------------------

pub fn sort_balances(balances: &mut [TokenBalance], sort_by: Option<&str>) {
    match sort_by {
        Some("balance") => {
            balances.sort_by(|a, b| b.balance.cmp(&a.balance));
        }
        Some("token") => {
            balances.sort_by_key(display_label);
        }
        Some("chain") => {
            balances.sort_by_key(|tb| tb.chain_id);
        }
        Some("value_usd") => {
            eprintln!("Warning: value_usd sort requires price feeds (not implemented). Falling back to balance sort.");
            balances.sort_by(|a, b| b.balance.cmp(&a.balance));
        }
        _ => {} // None or unrecognized → no sort (chain order)
    }
}

// ---------------------------------------------------------------------------
// Info formatting
// ---------------------------------------------------------------------------

pub fn format_info(account: &AccountRecord, chain_filter: Option<u64>) -> String {
    let mut out = String::new();
    out.push_str(&format!("{} ({}):\n", account.key_label, account.key_policy));
    out.push_str(&format!("  Address: {}\n", short_address(account.address)));
    out.push_str("  Chains:\n");

    let chains: Vec<&ChainDeployment> = match chain_filter {
        Some(cid) => account.chains.iter().filter(|c| c.chain_id == cid).collect(),
        None => account.chains.iter().collect(),
    };

    for chain in chains {
        out.push_str(&format!("    {}:\n", display_chain(chain.chain_id)));
        out.push_str(&format!(
            "      Impl:     {} @ {}\n",
            chain.implementation_name,
            short_address(chain.implementation)
        ));
        out.push_str(&format!("      Deployed: {}\n", chain.deployed_at));
    }

    out
}

// ---------------------------------------------------------------------------
// Balance output: table
// ---------------------------------------------------------------------------

pub fn format_balance_table(account: &AccountRecord, balances: &[TokenBalance]) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "{} ({}):\n",
        account.key_label,
        short_address(account.address)
    ));

    // Group by chain_id
    let mut groups: BTreeMap<u64, Vec<&TokenBalance>> = BTreeMap::new();
    for tb in balances {
        groups.entry(tb.chain_id).or_default().push(tb);
    }

    for (chain_id, tbs) in &groups {
        out.push_str(&format!("  {}:\n", display_chain(*chain_id)));

        // Compute max label length for alignment
        let max_label_len = tbs.iter().map(|tb| display_label(tb).len()).max().unwrap_or(0);

        for tb in tbs {
            let label = display_label(tb);
            let padded = format!("{label}:");
            out.push_str(&format!(
                "    {:width$} {}\n",
                padded,
                format_balance(tb.balance, tb.decimals),
                width = max_label_len + 1
            ));
        }
    }

    out
}

// ---------------------------------------------------------------------------
// Balance output: JSON
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct BalanceOutput {
    account: String,
    key: String,
    balances: Vec<BalanceEntry>,
}

#[derive(Serialize, serde::Deserialize)]
struct BalanceEntry {
    chain_id: u64,
    chain: String,
    token: String,
    balance: String,
    raw: String,
}

pub fn format_balance_json(account: &AccountRecord, balances: &[TokenBalance]) -> String {
    let entries: Vec<BalanceEntry> = balances
        .iter()
        .map(|tb| BalanceEntry {
            chain_id: tb.chain_id,
            chain: chain_name(tb.chain_id)
                .unwrap_or("Unknown")
                .to_string(),
            token: display_label(tb),
            balance: format_balance(tb.balance, tb.decimals),
            raw: tb.balance.to_string(),
        })
        .collect();

    let output = BalanceOutput {
        account: format!("{}", account.address),
        key: account.key_label.clone(),
        balances: entries,
    };

    serde_json::to_string_pretty(&output).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Balance output: CSV
// ---------------------------------------------------------------------------

pub fn format_balance_csv(account: &AccountRecord, balances: &[TokenBalance]) -> String {
    let _ = account; // account info not included in CSV rows
    let mut out = String::from("chain_id,chain,token,balance,raw\n");
    for tb in balances {
        let chain = chain_name(tb.chain_id).unwrap_or("Unknown");
        let token = display_label(tb);
        let balance = format_balance(tb.balance, tb.decimals);
        let raw = tb.balance.to_string();
        out.push_str(&format!(
            "{},\"{}\",\"{}\",\"{}\",\"{}\"\n",
            tb.chain_id, chain, token, balance, raw
        ));
    }
    out
}

// ---------------------------------------------------------------------------
// RPC query functions
// ---------------------------------------------------------------------------

sol! {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string);
}

pub async fn query_native_balance(
    provider: &impl Provider,
    address: Address,
) -> Result<U256> {
    provider
        .get_balance(address)
        .await
        .map_err(|e| Error::Provider(format!("get_balance failed: {e}")))
}

pub async fn query_erc20_balance(
    provider: &impl Provider,
    token_addr: Address,
    account_addr: Address,
) -> Result<U256> {
    let call_data = balanceOfCall {
        account: account_addr,
    };
    let encoded = SolCall::abi_encode(&call_data);

    let result = provider
        .call(
            alloy::rpc::types::TransactionRequest::default()
                .to(token_addr)
                .input(alloy::rpc::types::TransactionInput::new(Bytes::from(
                    encoded,
                ))),
        )
        .await
        .map_err(|e| Error::Provider(format!("balanceOf call failed: {e}")))?;

    U256::abi_decode(&result)
        .map_err(|e| Error::Provider(format!("balanceOf decode failed: {e}")))
}

pub async fn query_erc20_decimals(
    provider: &impl Provider,
    token_addr: Address,
) -> u8 {
    let call_data = decimalsCall {};
    let encoded = SolCall::abi_encode(&call_data);

    let result = provider
        .call(
            alloy::rpc::types::TransactionRequest::default()
                .to(token_addr)
                .input(alloy::rpc::types::TransactionInput::new(Bytes::from(
                    encoded,
                ))),
        )
        .await;

    match result {
        Ok(bytes) => {
            decimalsCall::abi_decode_returns(&bytes).unwrap_or(18)
        }
        Err(_) => 18,
    }
}

pub async fn query_erc20_symbol(
    provider: &impl Provider,
    token_addr: Address,
) -> Option<String> {
    let call_data = symbolCall {};
    let encoded = SolCall::abi_encode(&call_data);

    let result = provider
        .call(
            alloy::rpc::types::TransactionRequest::default()
                .to(token_addr)
                .input(alloy::rpc::types::TransactionInput::new(Bytes::from(
                    encoded,
                ))),
        )
        .await
        .ok()?;

    symbolCall::abi_decode_returns(&result).ok()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::address;

    const TEST_TOKEN_A: &str = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; // USDC on Base
    const TEST_TOKEN_B: &str = "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb"; // DAI on Base

    fn test_account() -> AccountRecord {
        use crate::types::{ChainDeployment, P256PublicKey};
        use alloy::primitives::B256;

        AccountRecord {
            address: address!("0x9876543210987654321098765432109876545432"),
            key_label: "testnet-key".into(),
            key_policy: "biometric".into(),
            public_key: P256PublicKey {
                qx: B256::repeat_byte(0x01),
                qy: B256::repeat_byte(0x02),
            },
            chains: vec![
                ChainDeployment {
                    chain_id: 84532,
                    implementation: address!("0x1234567890123456789012345678901234565678"),
                    implementation_name: "KeypoAccount".into(),
                    entry_point: address!("0x0000000071727De22E5E9d8BAf0edAc6f37da032"),
                    bundler_url: Some("https://bundler.example.com".into()),
                    paymaster_url: None,
                    rpc_url: "https://sepolia.base.org".into(),
                    deployed_at: "2026-03-01T12:00:00Z".into(),
                },
                ChainDeployment {
                    chain_id: 1,
                    implementation: address!("0x1234567890123456789012345678901234565678"),
                    implementation_name: "KeypoAccount".into(),
                    entry_point: address!("0x0000000071727De22E5E9d8BAf0edAc6f37da032"),
                    bundler_url: Some("https://bundler2.example.com".into()),
                    paymaster_url: None,
                    rpc_url: "https://eth.example.com".into(),
                    deployed_at: "2026-03-02T12:00:00Z".into(),
                },
            ],
            created_at: "2026-03-01T00:00:00Z".into(),
        }
    }

    // -- chain_name / display_chain --

    #[test]
    fn test_chain_name_known() {
        assert_eq!(chain_name(84532), Some("Base Sepolia"));
    }

    #[test]
    fn test_chain_name_unknown() {
        assert_eq!(chain_name(99999), None);
    }

    #[test]
    fn test_display_chain_known() {
        assert_eq!(display_chain(84532), "Base Sepolia (84532)");
    }

    #[test]
    fn test_display_chain_unknown() {
        assert_eq!(display_chain(99999), "Chain 99999");
    }

    // -- short_address --

    #[test]
    fn test_short_address() {
        let addr = address!("0xAbCdEf0123456789AbCdEf0123456789AbCd1234");
        let result = short_address(addr);
        // Verify format: first 6 chars + "..." + last 4 chars
        assert!(result.starts_with("0x"));
        assert!(result.contains("..."));
        assert!(result.ends_with("1234"));
        assert_eq!(result.len(), 13); // 6 + 3 + 4
    }

    // -- format_balance --

    #[test]
    fn test_format_balance_zero() {
        assert_eq!(format_balance(U256::ZERO, 18), "0.000000");
    }

    #[test]
    fn test_format_balance_one_eth() {
        let one_eth = U256::from(1_000_000_000_000_000_000u64);
        assert_eq!(format_balance(one_eth, 18), "1.000000");
    }

    #[test]
    fn test_format_balance_fractional() {
        let val = U256::from(8_900_000_000_000_000u64);
        assert_eq!(format_balance(val, 18), "0.008900");
    }

    #[test]
    fn test_format_balance_usdc() {
        let val = U256::from(100_000_000u64);
        assert_eq!(format_balance(val, 6), "100.000000");
    }

    #[test]
    fn test_format_balance_tiny() {
        assert_eq!(format_balance(U256::from(1), 18), "< 0.000001");
    }

    #[test]
    fn test_format_balance_low_decimals() {
        // 100 raw, decimals=2 → 1.00 → displayed as "1.000000"
        assert_eq!(format_balance(U256::from(100), 2), "1.000000");
    }

    #[test]
    fn test_format_balance_large() {
        // 10^30, decimals=18 → 10^12 = 1_000_000_000_000
        let val = U256::from(10u64).pow(U256::from(30));
        assert_eq!(format_balance(val, 18), "1000000000000.000000");
    }

    #[test]
    fn test_format_balance_decimals_zero() {
        assert_eq!(format_balance(U256::from(42), 0), "42.000000");
    }

    // -- is_native_token --

    #[test]
    fn test_is_native_token_variants() {
        assert!(is_native_token("ETH"));
        assert!(is_native_token("eth"));
        assert!(is_native_token("Eth"));
        assert!(!is_native_token(TEST_TOKEN_A));
    }

    // -- resolve_tokens --

    #[test]
    fn test_resolve_tokens_default() {
        let result = resolve_tokens(None, None).unwrap();
        assert_eq!(result, vec!["ETH"]);
    }

    #[test]
    fn test_resolve_tokens_cli_token() {
        let result = resolve_tokens(Some(TEST_TOKEN_A), None).unwrap();
        assert_eq!(result, vec![TEST_TOKEN_A]);
    }

    #[test]
    fn test_resolve_tokens_query_include() {
        let query = BalanceQuery {
            tokens: Some(crate::types::TokenFilter {
                include: vec!["ETH".into(), TEST_TOKEN_A.into()],
                ..Default::default()
            }),
            ..Default::default()
        };
        let result = resolve_tokens(None, Some(&query)).unwrap();
        assert_eq!(result, vec![TEST_TOKEN_A, "ETH"]);
    }

    #[test]
    fn test_resolve_tokens_cli_overrides_query() {
        let query = BalanceQuery {
            tokens: Some(crate::types::TokenFilter {
                include: vec!["ETH".into(), TEST_TOKEN_A.into()],
                ..Default::default()
            }),
            ..Default::default()
        };
        let result = resolve_tokens(Some(TEST_TOKEN_B), Some(&query)).unwrap();
        assert_eq!(result, vec![TEST_TOKEN_B]);
    }

    #[test]
    fn test_resolve_tokens_exclude_eth() {
        let query = BalanceQuery {
            tokens: Some(crate::types::TokenFilter {
                include: vec!["ETH".into(), TEST_TOKEN_A.into()],
                exclude: vec!["ETH".into()],
                ..Default::default()
            }),
            ..Default::default()
        };
        let result = resolve_tokens(None, Some(&query)).unwrap();
        assert_eq!(result, vec![TEST_TOKEN_A]);
    }

    #[test]
    fn test_resolve_tokens_dedup() {
        let query = BalanceQuery {
            tokens: Some(crate::types::TokenFilter {
                include: vec!["ETH".into(), "eth".into()],
                ..Default::default()
            }),
            ..Default::default()
        };
        let result = resolve_tokens(None, Some(&query)).unwrap();
        assert_eq!(result, vec!["ETH"]);
    }

    #[test]
    fn test_resolve_tokens_address_case_dedup() {
        let lower = TEST_TOKEN_A.to_lowercase();
        let query = BalanceQuery {
            tokens: Some(crate::types::TokenFilter {
                include: vec![TEST_TOKEN_A.into(), lower],
                ..Default::default()
            }),
            ..Default::default()
        };
        let result = resolve_tokens(None, Some(&query)).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], TEST_TOKEN_A);
    }

    #[test]
    fn test_resolve_tokens_invalid_symbol() {
        let result = resolve_tokens(Some("USDC"), None);
        assert!(result.is_err());
        let err = format!("{}", result.unwrap_err());
        assert!(err.contains("invalid token address"));
        assert!(err.contains("Symbol-based lookup is not yet supported"));
    }

    // -- resolve_chains --

    #[test]
    fn test_resolve_chains_all() {
        let account = test_account();
        let chains = resolve_chains(&account, None, None).unwrap();
        assert_eq!(chains.len(), 2);
    }

    #[test]
    fn test_resolve_chains_cli_filter() {
        let account = test_account();
        let chains = resolve_chains(&account, Some(84532), None).unwrap();
        assert_eq!(chains.len(), 1);
        assert_eq!(chains[0].chain_id, 84532);
    }

    // -- format_info --

    #[test]
    fn test_format_info_single_chain() {
        let account = test_account();
        let info = format_info(&account, Some(84532));
        assert!(info.contains("testnet-key (biometric):"));
        assert!(info.contains("Address: 0x9876...5432"));
        assert!(info.contains("Base Sepolia (84532):"));
        assert!(info.contains("KeypoAccount @ 0x1234...5678"));
        assert!(info.contains("Deployed: 2026-03-01T12:00:00Z"));
        // Should not contain the other chain
        assert!(!info.contains("Ethereum (1):"));
    }

    // -- parse_decimal_to_raw --

    #[test]
    fn test_parse_decimal_to_raw_eth() {
        let raw = parse_decimal_to_raw("0.001", 18).unwrap();
        assert_eq!(raw, U256::from(1_000_000_000_000_000u64));
    }

    #[test]
    fn test_parse_decimal_to_raw_usdc() {
        let raw = parse_decimal_to_raw("100", 6).unwrap();
        assert_eq!(raw, U256::from(100_000_000u64));
    }

    #[test]
    fn test_parse_decimal_to_raw_invalid() {
        assert!(parse_decimal_to_raw("abc", 18).is_none());
    }

    // -- min_balance_filter --

    #[test]
    fn test_min_balance_filter_removes_below() {
        let mut balances = vec![TokenBalance {
            chain_id: 84532,
            token: "ETH".into(),
            symbol: None,
            balance: U256::from(500_000_000_000_000_000u64), // 0.5 ETH
            decimals: 18,
        }];
        apply_min_balance_filter(&mut balances, Some("1.0"));
        assert!(balances.is_empty());
    }

    #[test]
    fn test_min_balance_filter_unparseable_keeps() {
        let mut balances = vec![TokenBalance {
            chain_id: 84532,
            token: "ETH".into(),
            symbol: None,
            balance: U256::from(1),
            decimals: 18,
        }];
        apply_min_balance_filter(&mut balances, Some("xyz"));
        assert_eq!(balances.len(), 1);
    }

    // -- sort_balances --

    #[test]
    fn test_sort_by_balance_descending() {
        let mut balances = vec![
            TokenBalance {
                chain_id: 84532,
                token: "ETH".into(),
                symbol: None,
                balance: U256::from(100),
                decimals: 18,
            },
            TokenBalance {
                chain_id: 84532,
                token: TEST_TOKEN_A.into(),
                symbol: Some("USDC".into()),
                balance: U256::from(200),
                decimals: 6,
            },
        ];
        sort_balances(&mut balances, Some("balance"));
        assert_eq!(balances[0].balance, U256::from(200));
        assert_eq!(balances[1].balance, U256::from(100));
    }

    #[test]
    fn test_sort_by_chain_ascending() {
        let mut balances = vec![
            TokenBalance {
                chain_id: 84532,
                token: "ETH".into(),
                symbol: None,
                balance: U256::from(100),
                decimals: 18,
            },
            TokenBalance {
                chain_id: 1,
                token: "ETH".into(),
                symbol: None,
                balance: U256::from(200),
                decimals: 18,
            },
        ];
        sort_balances(&mut balances, Some("chain"));
        assert_eq!(balances[0].chain_id, 1);
        assert_eq!(balances[1].chain_id, 84532);
    }

    // -- format_balance_table --

    #[test]
    fn test_format_balance_table_alignment() {
        let account = test_account();
        let balances = vec![
            TokenBalance {
                chain_id: 84532,
                token: "ETH".into(),
                symbol: None,
                balance: U256::from(8_900_000_000_000_000u64),
                decimals: 18,
            },
            TokenBalance {
                chain_id: 84532,
                token: TEST_TOKEN_A.into(),
                symbol: Some("USDC".into()),
                balance: U256::from(100_000_000u64),
                decimals: 6,
            },
        ];
        let table = format_balance_table(&account, &balances);
        assert!(table.contains("testnet-key (0x9876...5432):"));
        assert!(table.contains("Base Sepolia (84532):"));
        // Check both tokens appear
        assert!(table.contains("ETH:"));
        assert!(table.contains("USDC:"));
        assert!(table.contains("0.008900"));
        assert!(table.contains("100.000000"));
        // Verify alignment: ETH label is shorter than USDC, so ETH: should be padded
        let lines: Vec<&str> = table.lines().collect();
        let eth_line = lines.iter().find(|l| l.contains("ETH:")).unwrap();
        let usdc_line = lines.iter().find(|l| l.contains("USDC:")).unwrap();
        // Both balance values should start at the same column
        let eth_pos = eth_line.find("0.008900").unwrap();
        let usdc_pos = usdc_line.find("100.000000").unwrap();
        assert_eq!(eth_pos, usdc_pos);
    }

    // -- format_balance_json --

    #[test]
    fn test_format_balance_json_structure() {
        let account = test_account();
        let balances = vec![TokenBalance {
            chain_id: 84532,
            token: "ETH".into(),
            symbol: None,
            balance: U256::from(8_900_000_000_000_000u64),
            decimals: 18,
        }];
        let json_str = format_balance_json(&account, &balances);
        let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["key"], "testnet-key");
        assert!(parsed["account"].as_str().unwrap().starts_with("0x"));
        let bal = &parsed["balances"][0];
        assert_eq!(bal["chain_id"], 84532);
        assert_eq!(bal["chain"], "Base Sepolia");
        assert_eq!(bal["token"], "ETH");
        assert_eq!(bal["balance"], "0.008900");
        assert_eq!(bal["raw"], "8900000000000000");
    }

    // -- format_balance_csv --

    #[test]
    fn test_format_balance_csv_quoting() {
        let account = test_account();
        let balances = vec![TokenBalance {
            chain_id: 84532,
            token: "ETH".into(),
            symbol: None,
            balance: U256::from(8_900_000_000_000_000u64),
            decimals: 18,
        }];
        let csv = format_balance_csv(&account, &balances);
        let lines: Vec<&str> = csv.lines().collect();
        assert_eq!(lines[0], "chain_id,chain,token,balance,raw");
        assert_eq!(
            lines[1],
            "84532,\"Base Sepolia\",\"ETH\",\"0.008900\",\"8900000000000000\""
        );
    }
}
