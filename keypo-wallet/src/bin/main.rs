use std::path::Path;
use std::time::Duration;

use alloy::primitives::{Address, Bytes, U256};
use clap::{Parser, Subcommand};
use keypo_wallet::account::{self, FundingStrategy, SetupConfig, SETUP_FUNDING_AMOUNT};
use keypo_wallet::AccountImplementation;
use keypo_wallet::impls::KeypoAccountImpl;
use keypo_wallet::signer::KeypoSigner;
use keypo_wallet::state::StateStore;
use keypo_wallet::types::Call;

#[derive(Parser)]
#[command(name = "keypo-wallet", about = "Keypo smart wallet CLI")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Set up a smart account on a chain
    Setup {
        /// Key label for the signing key
        #[arg(long)]
        key: String,

        /// Key access policy
        #[arg(long, default_value = "biometric")]
        key_policy: String,

        /// RPC URL for the chain
        #[arg(long)]
        rpc: Option<String>,

        /// Bundler URL
        #[arg(long)]
        bundler: Option<String>,

        /// Chain ID
        #[arg(long)]
        chain_id: Option<u64>,

        /// Paymaster URL
        #[arg(long)]
        paymaster: Option<String>,

        /// Implementation contract address
        #[arg(long)]
        implementation: Option<String>,

        /// Implementation name
        #[arg(long, default_value = "KeypoAccount")]
        impl_name: String,
    },

    /// Send a transaction
    Send {
        /// Key label for the signing key
        #[arg(long)]
        key: String,

        /// Recipient address
        #[arg(long)]
        to: String,

        /// Value in wei (default "0")
        #[arg(long, default_value = "0")]
        value: String,

        /// Calldata (hex-encoded)
        #[arg(long)]
        data: Option<String>,

        /// Chain ID
        #[arg(long)]
        chain_id: Option<u64>,

        /// Bundler RPC URL (overrides stored deployment)
        #[arg(long)]
        bundler: Option<String>,

        /// Paymaster URL (overrides stored deployment)
        #[arg(long)]
        paymaster: Option<String>,

        /// Paymaster sponsorship policy ID (e.g. sp_clever_unus)
        #[arg(long)]
        paymaster_policy: Option<String>,

        /// Standard RPC URL (overrides stored deployment, used for nonce/gas queries)
        #[arg(long)]
        rpc: Option<String>,
    },

    /// Send a batch of calls
    Batch {
        /// Key label for the signing key
        #[arg(long)]
        key: String,

        /// Path to JSON file with calls
        #[arg(long)]
        calls: String,

        /// Chain ID
        #[arg(long)]
        chain_id: Option<u64>,

        /// Bundler RPC URL (overrides stored deployment)
        #[arg(long)]
        bundler: Option<String>,

        /// Paymaster URL (overrides stored deployment)
        #[arg(long)]
        paymaster: Option<String>,

        /// Paymaster sponsorship policy ID (e.g. sp_clever_unus)
        #[arg(long)]
        paymaster_policy: Option<String>,

        /// Standard RPC URL (overrides stored deployment, used for nonce/gas queries)
        #[arg(long)]
        rpc: Option<String>,
    },

    /// Show account info
    Info {
        /// Key label for the signing key
        #[arg(long)]
        key: String,

        /// Chain ID
        #[arg(long)]
        chain_id: Option<u64>,
    },

    /// Check account balance
    Balance {
        /// Key label for the signing key
        #[arg(long)]
        key: String,

        /// Chain ID
        #[arg(long)]
        chain_id: Option<u64>,

        /// Token contract address (omit for native balance)
        #[arg(long)]
        token: Option<String>,

        /// Path to query JSON file
        #[arg(long)]
        query: Option<String>,

        /// RPC URL override
        #[arg(long)]
        rpc: Option<String>,

        /// Output format (table/json/csv)
        #[arg(long)]
        format: Option<String>,
    },
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().try_init().ok();

    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Setup {
            key,
            key_policy,
            rpc,
            bundler,
            chain_id,
            paymaster,
            implementation,
            impl_name,
        } => {
            run_setup(
                key,
                key_policy,
                rpc,
                bundler,
                chain_id,
                paymaster,
                implementation,
                impl_name,
            )
            .await
        }
        Commands::Send {
            key,
            to,
            value,
            data,
            chain_id,
            bundler,
            paymaster,
            paymaster_policy,
            rpc,
        } => {
            run_send(key, to, value, data, chain_id, bundler, paymaster, paymaster_policy, rpc).await
        }
        Commands::Batch {
            key,
            calls,
            chain_id,
            bundler,
            paymaster,
            paymaster_policy,
            rpc,
        } => {
            run_batch(key, calls, chain_id, bundler, paymaster, paymaster_policy, rpc).await
        }
        Commands::Info { key, chain_id } => run_info(key, chain_id).await,
        Commands::Balance {
            key,
            chain_id,
            token,
            query,
            rpc,
            format,
        } => run_balance(key, chain_id, token, query, rpc, format).await,
    };

    if let Err(e) = result {
        eprintln!("Error: {e}");
        std::process::exit(1);
    }
}

async fn run_setup(
    key: String,
    key_policy: String,
    rpc: Option<String>,
    bundler: Option<String>,
    chain_id: Option<u64>,
    paymaster: Option<String>,
    implementation: Option<String>,
    impl_name: String,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let rpc_url = rpc.ok_or("--rpc is required for setup")?;

    // Resolve implementation address and chain_id
    let (impl_address, resolved_chain_id, imp) = if let Some(ref addr_str) = implementation {
        // Explicit implementation address provided
        let addr: Address = addr_str.parse().map_err(|e| format!("invalid --implementation address: {e}"))?;
        let imp = KeypoAccountImpl::new();
        (addr, chain_id, imp)
    } else {
        // Need chain_id to look up deployment
        let cid = if let Some(id) = chain_id {
            id
        } else {
            // Auto-detect chain_id from RPC
            use alloy::providers::{Provider, ProviderBuilder};
            let url: url::Url = rpc_url.parse().map_err(|e: url::ParseError| format!("invalid RPC URL: {e}"))?;
            let provider = ProviderBuilder::new().connect_http(url);
            provider.get_chain_id().await.map_err(|e| format!("failed to get chain ID: {e}"))?
        };

        // Load deployments from deployments/ directory
        let imp = load_deployments_impl();
        let addr = imp.implementation_address(cid).ok_or_else(|| {
            format!(
                "No deployment found for chain {cid}. Use --implementation to specify the contract address."
            )
        })?;
        (addr, Some(cid), imp)
    };

    let signer = KeypoSigner::new();
    let mut state = StateStore::open()?;

    let config = SetupConfig {
        key_label: key,
        key_policy,
        rpc_url: rpc_url.clone(),
        bundler_url: bundler,
        paymaster_url: paymaster,
        implementation_address: impl_address,
        implementation_name: impl_name,
        chain_id: resolved_chain_id,
    };

    // Determine funding strategy
    let funding = if let Ok(funder_key) = std::env::var("TEST_FUNDER_PRIVATE_KEY") {
        FundingStrategy::FundFrom {
            funder_private_key: funder_key,
            amount: SETUP_FUNDING_AMOUNT,
            rpc_url,
        }
    } else {
        FundingStrategy::WaitForFunding {
            poll_interval: Duration::from_secs(5),
            max_wait: Duration::from_secs(300),
        }
    };

    let result = account::setup(&config, &imp, &signer, &mut state, funding).await?;

    println!("Account setup complete!");
    println!("  Address:  {}", result.account_address);
    println!("  Tx hash:  {}", result.tx_hash);
    println!("  Chain ID: {}", result.chain_id);

    Ok(())
}

/// Resolves account and chain deployment, applying CLI overrides for bundler/paymaster/rpc.
fn resolve_account_and_chain(
    state: &StateStore,
    key: &str,
    chain_id: Option<u64>,
    bundler_override: Option<String>,
    paymaster_override: Option<String>,
    rpc_override: Option<String>,
) -> std::result::Result<
    (keypo_wallet::types::AccountRecord, keypo_wallet::types::ChainDeployment),
    Box<dyn std::error::Error>,
> {
    let (account, chain) = if let Some(cid) = chain_id {
        let (acct, chain) = state
            .find_account(key, cid)
            .ok_or_else(|| format!("no account found for key '{key}' on chain {cid}"))?;
        (acct.clone(), chain.clone())
    } else {
        let acct = state
            .find_accounts_for_key(key)
            .ok_or_else(|| format!("no account found for key '{key}'"))?;
        let chain = acct
            .chains
            .first()
            .ok_or_else(|| format!("key '{key}' has no chain deployments"))?;
        (acct.clone(), chain.clone())
    };

    // Apply CLI overrides
    let mut chain = chain;
    if let Some(b) = bundler_override {
        chain.bundler_url = Some(b);
    }
    if let Some(p) = paymaster_override {
        chain.paymaster_url = Some(p);
    }
    if let Some(r) = rpc_override {
        chain.rpc_url = r;
    }

    Ok((account, chain))
}

async fn run_send(
    key: String,
    to: String,
    value: String,
    data: Option<String>,
    chain_id: Option<u64>,
    bundler: Option<String>,
    paymaster: Option<String>,
    paymaster_policy: Option<String>,
    rpc: Option<String>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let state = StateStore::open()?;
    let (account, chain) = resolve_account_and_chain(&state, &key, chain_id, bundler, paymaster, rpc)?;

    let signer = KeypoSigner::new();
    let imp = load_deployments_impl();

    // Parse call fields
    let to_addr: Address = to.parse().map_err(|e| format!("invalid --to address: {e}"))?;
    let call_value: U256 = value.parse().map_err(|e| format!("invalid --value: {e}"))?;
    let call_data = if let Some(ref d) = data {
        let stripped = d.strip_prefix("0x").or_else(|| d.strip_prefix("0X")).unwrap_or(d);
        Bytes::from(hex::decode(stripped).map_err(|e| format!("invalid --data hex: {e}"))?)
    } else {
        Bytes::new()
    };

    let call = Call {
        to: to_addr,
        value: call_value,
        data: call_data,
    };

    let pm_context = paymaster_policy.map(|id| serde_json::json!({"sponsorshipPolicyId": id}));
    let result = keypo_wallet::transaction::execute_with_context(&account, &chain, &[call], &imp, &signer, pm_context).await?;

    println!("Transaction sent!");
    println!("  UserOp hash: {}", result.user_op_hash);
    println!("  Tx hash:     {}", result.tx_hash);
    println!("  Success:     {}", result.success);

    Ok(())
}

async fn run_batch(
    key: String,
    calls_path: String,
    chain_id: Option<u64>,
    bundler: Option<String>,
    paymaster: Option<String>,
    paymaster_policy: Option<String>,
    rpc: Option<String>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let state = StateStore::open()?;
    let (account, chain) = resolve_account_and_chain(&state, &key, chain_id, bundler, paymaster, rpc)?;

    let signer = KeypoSigner::new();
    let imp = load_deployments_impl();

    // Read and parse calls JSON file
    let calls_json = std::fs::read_to_string(&calls_path)
        .map_err(|e| format!("failed to read calls file '{calls_path}': {e}"))?;
    let calls: Vec<Call> = serde_json::from_str(&calls_json)
        .map_err(|e| format!("failed to parse calls JSON: {e}"))?;

    let pm_context = paymaster_policy.map(|id| serde_json::json!({"sponsorshipPolicyId": id}));
    let result = keypo_wallet::transaction::execute_with_context(&account, &chain, &calls, &imp, &signer, pm_context).await?;

    println!("Batch transaction sent!");
    println!("  UserOp hash: {}", result.user_op_hash);
    println!("  Tx hash:     {}", result.tx_hash);
    println!("  Success:     {}", result.success);

    Ok(())
}

async fn run_info(
    key: String,
    chain_id: Option<u64>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let state = StateStore::open()?;
    let account = state
        .find_accounts_for_key(&key)
        .ok_or_else(|| format!("no account found for key '{key}'"))?;

    let output = keypo_wallet::query::format_info(account, chain_id);
    print!("{output}");
    Ok(())
}

async fn run_balance(
    key: String,
    chain_id: Option<u64>,
    token: Option<String>,
    query_path: Option<String>,
    rpc_override: Option<String>,
    format_override: Option<String>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    use alloy::providers::ProviderBuilder;
    use keypo_wallet::query;
    use keypo_wallet::types::{BalanceQuery, TokenBalance};

    let state = StateStore::open()?;
    let account = state
        .find_accounts_for_key(&key)
        .ok_or_else(|| format!("no account found for key '{key}'"))?
        .clone();

    // Parse query file if provided
    let balance_query: Option<BalanceQuery> = match query_path {
        Some(ref path) => {
            let contents = std::fs::read_to_string(path)
                .map_err(|_| format!("query file not found: '{path}'"))?;
            let q: BalanceQuery = serde_json::from_str(&contents)
                .map_err(|e| format!("failed to parse query JSON: {e}"))?;
            Some(q)
        }
        None => None,
    };

    // Resolve chains
    let chains =
        query::resolve_chains(&account, chain_id, balance_query.as_ref())?;

    // Resolve tokens
    let tokens = query::resolve_tokens(
        token.as_deref(),
        balance_query.as_ref(),
    )?;

    // Determine output format: CLI --format > query.format > "table"
    let fmt = format_override
        .or_else(|| balance_query.as_ref().map(|q| q.format.clone()))
        .unwrap_or_else(|| "table".to_string());
    if !["table", "json", "csv"].contains(&fmt.as_str()) {
        return Err(format!("unsupported format: '{fmt}'. Expected: table, json, csv").into());
    }

    // Determine sort_by and min_balance from query
    let sort_by = balance_query.as_ref().and_then(|q| q.sort_by.clone());
    let min_balance = balance_query
        .as_ref()
        .and_then(|q| q.tokens.as_ref())
        .and_then(|tf| tf.min_balance.clone());

    // Query balances
    let mut balances: Vec<TokenBalance> = Vec::new();
    let mut had_rpc_error = false;

    for chain in &chains {
        let rpc_url = rpc_override.as_deref().unwrap_or(&chain.rpc_url);
        let url: url::Url = match rpc_url.parse() {
            Ok(u) => u,
            Err(e) => {
                eprintln!(
                    "Warning: failed to query {}: invalid RPC URL: {e}",
                    query::display_chain(chain.chain_id)
                );
                had_rpc_error = true;
                continue;
            }
        };
        let provider = ProviderBuilder::new().connect_http(url);

        for token_str in &tokens {
            if query::is_native_token(token_str) {
                match query::query_native_balance(&provider, account.address).await {
                    Ok(balance) => {
                        balances.push(TokenBalance {
                            chain_id: chain.chain_id,
                            token: "ETH".into(),
                            symbol: None,
                            balance,
                            decimals: 18,
                        });
                    }
                    Err(e) => {
                        eprintln!(
                            "Warning: failed to query {}: {e}",
                            query::display_chain(chain.chain_id)
                        );
                        had_rpc_error = true;
                    }
                }
            } else {
                let token_addr: Address = token_str.parse().map_err(|e| {
                    format!("invalid token address '{token_str}': {e}")
                })?;
                match query::query_erc20_balance(&provider, token_addr, account.address).await {
                    Ok(balance) => {
                        let decimals =
                            query::query_erc20_decimals(&provider, token_addr).await;
                        let symbol =
                            query::query_erc20_symbol(&provider, token_addr).await;
                        balances.push(TokenBalance {
                            chain_id: chain.chain_id,
                            token: token_str.clone(),
                            symbol,
                            balance,
                            decimals,
                        });
                    }
                    Err(e) => {
                        eprintln!(
                            "Warning: failed to query {}: {e}",
                            query::display_chain(chain.chain_id)
                        );
                        had_rpc_error = true;
                    }
                }
            }
        }
    }

    if balances.is_empty() && had_rpc_error {
        return Err("failed to query all chains".into());
    }

    // Sort and filter
    query::sort_balances(&mut balances, sort_by.as_deref());
    query::apply_min_balance_filter(&mut balances, min_balance.as_deref());

    // Format output
    let output = match fmt.as_str() {
        "json" => query::format_balance_json(&account, &balances),
        "csv" => query::format_balance_csv(&account, &balances),
        _ => query::format_balance_table(&account, &balances),
    };
    print!("{output}");

    Ok(())
}

fn load_deployments_impl() -> KeypoAccountImpl {
    // Try CARGO_MANIFEST_DIR (works for cargo run), fall back to relative path
    let deployments_dir = option_env!("CARGO_MANIFEST_DIR")
        .map(|dir| Path::new(dir).join("..").join("deployments"))
        .unwrap_or_else(|| Path::new("deployments").to_path_buf());

    match KeypoAccountImpl::from_deployments_dir(&deployments_dir) {
        Ok(imp) => imp,
        Err(_) => KeypoAccountImpl::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn setup_all_args() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "setup",
            "--key",
            "my-key",
            "--key-policy",
            "open",
            "--rpc",
            "https://rpc.example.com",
            "--bundler",
            "https://bundler.example.com",
            "--chain-id",
            "84532",
            "--paymaster",
            "https://paymaster.example.com",
            "--implementation",
            "0x1234",
            "--impl-name",
            "KeypoAccount",
        ])
        .unwrap();

        match cli.command {
            Commands::Setup {
                key,
                key_policy,
                chain_id,
                ..
            } => {
                assert_eq!(key, "my-key");
                assert_eq!(key_policy, "open");
                assert_eq!(chain_id, Some(84532));
            }
            _ => panic!("expected Setup"),
        }
    }

    #[test]
    fn setup_defaults() {
        let cli = Cli::try_parse_from(["keypo-wallet", "setup", "--key", "test"]).unwrap();

        match cli.command {
            Commands::Setup {
                key_policy,
                impl_name,
                ..
            } => {
                assert_eq!(key_policy, "biometric");
                assert_eq!(impl_name, "KeypoAccount");
            }
            _ => panic!("expected Setup"),
        }
    }

    #[test]
    fn send_all_args() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "send",
            "--key",
            "my-key",
            "--to",
            "0xdead",
            "--value",
            "1000000000000000000",
            "--data",
            "0x1234",
            "--chain-id",
            "1",
            "--bundler",
            "https://bundler.example.com",
            "--paymaster",
            "https://paymaster.example.com",
            "--rpc",
            "https://rpc.example.com",
        ])
        .unwrap();

        match cli.command {
            Commands::Send {
                key,
                to,
                value,
                bundler,
                paymaster,
                rpc,
                ..
            } => {
                assert_eq!(key, "my-key");
                assert_eq!(to, "0xdead");
                assert_eq!(value, "1000000000000000000");
                assert_eq!(bundler, Some("https://bundler.example.com".into()));
                assert_eq!(paymaster, Some("https://paymaster.example.com".into()));
                assert_eq!(rpc, Some("https://rpc.example.com".into()));
            }
            _ => panic!("expected Send"),
        }
    }

    #[test]
    fn batch_args() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "batch",
            "--key",
            "my-key",
            "--calls",
            "calls.json",
            "--chain-id",
            "84532",
            "--bundler",
            "https://bundler.example.com",
            "--paymaster",
            "https://paymaster.example.com",
            "--rpc",
            "https://rpc.example.com",
        ])
        .unwrap();

        match cli.command {
            Commands::Batch {
                key,
                calls,
                chain_id,
                bundler,
                paymaster,
                rpc,
                ..
            } => {
                assert_eq!(key, "my-key");
                assert_eq!(calls, "calls.json");
                assert_eq!(chain_id, Some(84532));
                assert_eq!(bundler, Some("https://bundler.example.com".into()));
                assert_eq!(paymaster, Some("https://paymaster.example.com".into()));
                assert_eq!(rpc, Some("https://rpc.example.com".into()));
            }
            _ => panic!("expected Batch"),
        }
    }

    #[test]
    fn info_args() {
        let cli =
            Cli::try_parse_from(["keypo-wallet", "info", "--key", "my-key", "--chain-id", "1"])
                .unwrap();

        match cli.command {
            Commands::Info { key, chain_id } => {
                assert_eq!(key, "my-key");
                assert_eq!(chain_id, Some(1));
            }
            _ => panic!("expected Info"),
        }
    }

    #[test]
    fn balance_args() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "balance",
            "--key",
            "my-key",
            "--chain-id",
            "84532",
            "--token",
            "0xUSDC",
            "--query",
            "query.json",
        ])
        .unwrap();

        match cli.command {
            Commands::Balance {
                key,
                token,
                query,
                ..
            } => {
                assert_eq!(key, "my-key");
                assert_eq!(token, Some("0xUSDC".into()));
                assert_eq!(query, Some("query.json".into()));
            }
            _ => panic!("expected Balance"),
        }
    }

    #[test]
    fn balance_args_with_rpc_and_format() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "balance",
            "--key",
            "my-key",
            "--chain-id",
            "84532",
            "--rpc",
            "https://custom-rpc.example.com",
            "--format",
            "json",
        ])
        .unwrap();

        match cli.command {
            Commands::Balance {
                key,
                chain_id,
                rpc,
                format,
                ..
            } => {
                assert_eq!(key, "my-key");
                assert_eq!(chain_id, Some(84532));
                assert_eq!(rpc, Some("https://custom-rpc.example.com".into()));
                assert_eq!(format, Some("json".into()));
            }
            _ => panic!("expected Balance"),
        }
    }

    #[test]
    fn missing_required_key_fails() {
        let result = Cli::try_parse_from(["keypo-wallet", "setup"]);
        assert!(result.is_err());
    }

    #[test]
    fn batch_call_deserialization() {
        let json = r#"[
            {"to": "0x1111111111111111111111111111111111111111", "value": "0x0", "data": "0x"},
            {"to": "0x2222222222222222222222222222222222222222", "value": "0x38d7ea4c68000", "data": "0x1234"}
        ]"#;
        let calls: Vec<Call> = serde_json::from_str(json).unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].value, U256::ZERO);
        assert_eq!(calls[1].value, U256::from(0x38d7ea4c68000u64));
        assert_eq!(calls[1].data, Bytes::from(vec![0x12, 0x34]));
    }
}
