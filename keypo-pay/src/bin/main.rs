use alloy::primitives::{Address, Bytes, U256};
use clap::{Parser, Subcommand};
use keypo_pay::access_key::{self, KeyAuthorization, SpendingLimit};
use keypo_pay::address::derive_tempo_address;
use keypo_pay::config;
use keypo_pay::rlp::TempoCall;
use keypo_pay::signer::{KeypoSigner, P256Signer};

#[derive(Parser)]
#[command(
    name = "keypo-pay",
    about = "Keypo Tempo wallet CLI",
    long_about = "Keypo Tempo wallet CLI — manage Tempo accounts with P-256 (Secure Enclave) signing.\n\n\
        Uses root-key-plus-access-keys architecture for agent-initiated payments.\n\
        Requires keypo-signer for key management: brew install keypo-us/tap/keypo-signer",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// RPC URL override (takes precedence over config and env vars)
    #[arg(long, global = true)]
    rpc: Option<String>,

    /// Enable verbose debug output
    #[arg(long, global = true)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Manage wallet (create, info)
    #[command(subcommand)]
    Wallet(WalletAction),

    /// Send a Tempo transaction (low-level, defaults to root key)
    #[command(subcommand)]
    Tx(TxAction),

    /// Manage access keys (create, authorize, revoke, list)
    #[command(subcommand, name = "access-key")]
    AccessKey(AccessKeyAction),
}

#[derive(Subcommand, Clone)]
enum AccessKeyAction {
    /// Create a new access key locally (does not authorize on-chain)
    Create {
        /// Name for the access key (e.g., "agent-1")
        #[arg(long)]
        name: String,
    },

    /// Authorize an access key on-chain with spending limits
    Authorize {
        /// Name of the access key to authorize
        #[arg(long)]
        name: String,

        /// Token name or address for spending limit (can be repeated)
        #[arg(long, required = true)]
        token: Vec<String>,

        /// Spending limit amount per token (must match --token count)
        #[arg(long, required = true)]
        limit: Vec<String>,

        /// Expiry as unix timestamp or duration (e.g., 3600 for 1 hour)
        #[arg(long)]
        expiry: Option<String>,
    },

    /// List all local access keys with on-chain status
    List,

    /// Show detailed info for an access key
    Info {
        /// Name of the access key
        #[arg(long)]
        name: String,
    },

    /// Revoke an access key on-chain
    Revoke {
        /// Name of the access key to revoke
        #[arg(long)]
        name: String,
    },

    /// Update spending limit for an access key
    UpdateLimit {
        /// Name of the access key
        #[arg(long)]
        name: String,

        /// Token name or address
        #[arg(long)]
        token: String,

        /// New spending limit
        #[arg(long)]
        limit: String,
    },

    /// Delete a local access key entry (does not revoke on-chain)
    Delete {
        /// Name of the access key to delete
        #[arg(long)]
        name: String,
    },
}

#[derive(Subcommand, Clone)]
enum TxAction {
    /// Send a transaction
    #[command(
        long_about = "Build, sign, and submit a Tempo transaction.\n\n\
            Defaults to root key signing. Use --key to sign with a named access key.",
        after_long_help = "\
EXAMPLES:
  keypo-pay tx send --to 0xRecipient --token pathusd --amount 0.01
  keypo-pay tx send --to 0xRecipient --token pathusd --amount 0.01 --key agent-1"
    )]
    Send {
        /// Recipient address
        #[arg(long)]
        to: String,

        /// Token name or address
        #[arg(long)]
        token: String,

        /// Amount in human-readable units (e.g., 0.01)
        #[arg(long)]
        amount: String,

        /// Named access key to sign with (Keychain signature)
        #[arg(long)]
        key: Option<String>,
    },
}

#[derive(Subcommand, Clone)]
enum WalletAction {
    /// Create a new wallet (root key only)
    #[command(
        long_about = "Create a new keypo-pay wallet.\n\n\
            Generates a root P-256 key in the Secure Enclave and derives the Tempo account address.\n\
            Use --test to create with open policy (no biometric prompt) for automated testing.",
        after_long_help = "\
EXAMPLES:
  keypo-pay wallet create
  keypo-pay wallet create --test

OUTPUT:
  Wallet created!
  Address: 0x1234...abcd
  Root key: com.keypo.signer.tempo-root"
    )]
    Create {
        /// Use open policy for root key (automated testing)
        #[arg(long)]
        test: bool,
    },

    /// Show wallet info
    #[command(
        long_about = "Display wallet address, root key ID, chain ID, and access key status.",
        after_long_help = "\
EXAMPLES:
  keypo-pay wallet info

OUTPUT:
  Address:   0x1234...abcd
  Root key:  com.keypo.signer.tempo-root
  Chain ID:  12345
  RPC:       https://rpc.moderato.tempo.xyz"
    )]
    Info,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let filter = tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        if cli.verbose {
            tracing_subscriber::EnvFilter::new("keypo_pay=debug")
        } else {
            tracing_subscriber::EnvFilter::new("keypo_pay=warn")
        }
    });
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .try_init()
        .ok();

    let result = match cli.command {
        Commands::Wallet(action) => match action {
            WalletAction::Create { test } => run_wallet_create(test).await,
            WalletAction::Info => run_wallet_info(cli.rpc.as_deref()).await,
        },
        Commands::Tx(action) => match action {
            TxAction::Send {
                to,
                token,
                amount,
                key,
            } => run_tx_send(cli.rpc.as_deref(), &to, &token, &amount, key.as_deref()).await,
        },
        Commands::AccessKey(action) => run_access_key(cli.rpc.as_deref(), action).await,
    };

    if let Err(e) = result {
        eprintln!("Error: {e}");
        if let Some(ke) = e.downcast_ref::<keypo_pay::Error>() {
            if let Some(hint) = ke.suggestion() {
                eprintln!("  Hint: {hint}");
            }
        }
        std::process::exit(1);
    }
}

async fn run_wallet_create(test: bool) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet_path = config::wallet_config_path()?;

    // Idempotency guard
    if wallet_path.exists() {
        return Err(keypo_pay::Error::WalletExists(wallet_path.display().to_string()).into());
    }

    let signer = KeypoSigner::new();
    let policy = if test { "open" } else { "biometric" };
    let label = "tempo-root";

    // Create root key
    let pub_key = signer.create_key(label, policy)?;
    let address = derive_tempo_address(&pub_key);

    // Build and save wallet config
    let wallet = config::WalletConfig {
        chain_id: config::TESTNET_CHAIN_ID,
        rpc_url: config::TESTNET_RPC_URL.to_string(),
        root_key_id: format!("com.keypo.signer.{}", label),
        address: format!("{address}"),
        default_token: Some("pathusd".to_string()),
        block_explorer_url: None,
    };

    config::save_wallet_config(&wallet)?;

    // Save default tokens
    let tokens = config::default_testnet_tokens();
    config::save_tokens(&tokens)?;

    // Create empty access keys file
    let access_keys = config::AccessKeysFile::default();
    config::save_access_keys(&access_keys)?;

    println!("Wallet created!");
    println!("  Address:  {address}");
    println!("  Root key: com.keypo.signer.{label}");
    println!("  Chain ID: {}", wallet.chain_id);
    println!("  RPC:      {}", wallet.rpc_url);

    Ok(())
}

async fn run_wallet_info(
    rpc_override: Option<&str>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet = config::load_wallet_config()?;
    let access_keys = config::load_access_keys()?;

    let rpc = config::resolve_rpc(rpc_override, &wallet);

    println!("Address:   {}", wallet.address);
    println!("Root key:  {}", wallet.root_key_id);
    println!("Chain ID:  {}", wallet.chain_id);
    println!("RPC:       {rpc}");

    if access_keys.keys.is_empty() {
        println!("Access keys: (none)");
    } else {
        println!("Access keys:");
        for key in &access_keys.keys {
            println!("  {} — {} ({})", key.name, key.address, key.key_id);
        }
    }

    Ok(())
}

async fn run_access_key(
    rpc_override: Option<&str>,
    action: AccessKeyAction,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    match action {
        AccessKeyAction::Create { name } => run_access_key_create(&name).await,
        AccessKeyAction::Authorize {
            name,
            token,
            limit,
            expiry,
        } => run_access_key_authorize(rpc_override, &name, &token, &limit, expiry.as_deref()).await,
        AccessKeyAction::List => run_access_key_list(rpc_override).await,
        AccessKeyAction::Info { name } => run_access_key_info(rpc_override, &name).await,
        AccessKeyAction::Revoke { name } => run_access_key_revoke(rpc_override, &name).await,
        AccessKeyAction::UpdateLimit { name, token, limit } => {
            run_access_key_update_limit(rpc_override, &name, &token, &limit).await
        }
        AccessKeyAction::Delete { name } => run_access_key_delete(&name).await,
    }
}

async fn run_access_key_create(
    name: &str,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    // Verify wallet exists
    let _wallet = config::load_wallet_config()?;

    // Check for duplicate names
    let mut access_keys = config::load_access_keys()?;
    if access_keys.keys.iter().any(|k| k.name == name) {
        return Err(keypo_pay::Error::DuplicateAccessKey(name.to_string()).into());
    }

    // Create key with open policy (access keys are always open)
    let signer = KeypoSigner::new();
    let label = format!("tempo-ak-{name}");
    let pub_key = signer.create_key(&label, "open")?;
    let address = derive_tempo_address(&pub_key);

    // Store locally
    access_keys.keys.push(config::AccessKeyEntry {
        name: name.to_string(),
        key_id: format!("com.keypo.signer.{label}"),
        address: format!("{address}"),
    });
    config::save_access_keys(&access_keys)?;

    println!("Access key created!");
    println!("  Name:    {name}");
    println!("  Address: {address}");
    println!("  Key ID:  com.keypo.signer.{label}");
    println!("  Status:  not-yet-authorized (run 'access-key authorize' to activate on-chain)");

    Ok(())
}

async fn run_access_key_authorize(
    rpc_override: Option<&str>,
    name: &str,
    tokens: &[String],
    limits: &[String],
    expiry: Option<&str>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    if tokens.len() != limits.len() {
        return Err("--token and --limit must be provided in matching pairs".into());
    }

    let wallet = config::load_wallet_config()?;
    let token_book = config::load_tokens()?;
    let access_keys = config::load_access_keys()?;
    let rpc_url = config::resolve_rpc(rpc_override, &wallet);

    // Find the access key
    let entry = access_keys
        .keys
        .iter()
        .find(|k| k.name == name)
        .ok_or_else(|| keypo_pay::Error::AccessKeyNotFound(name.to_string()))?;

    let access_key_address: Address = entry
        .address
        .parse()
        .map_err(|e| format!("invalid access key address: {e}"))?;
    let wallet_address: Address = wallet
        .address
        .parse()
        .map_err(|e| format!("invalid wallet address: {e}"))?;

    // Query decimals for each token and build spending limits
    let client = reqwest::Client::new();
    let mut spending_limits = Vec::new();
    for (token_str, limit_str) in tokens.iter().zip(limits.iter()) {
        let token_addr_str = config::resolve_token(token_str, &token_book.tokens)?;
        let token_addr: Address = token_addr_str
            .parse()
            .map_err(|e| format!("invalid token address: {e}"))?;

        let decimals_data = keypo_pay::transaction::encode_decimals();
        let decimals_result =
            keypo_pay::rpc::eth_call(&client, &rpc_url, token_addr, &decimals_data).await?;
        let decimals = if decimals_result.len() >= 32 {
            decimals_result[31]
        } else {
            18
        };

        let amount_f64: f64 = limit_str
            .parse()
            .map_err(|e| format!("invalid limit '{limit_str}': {e}"))?;
        let multiplier = 10f64.powi(decimals as i32);
        let amount = U256::from((amount_f64 * multiplier) as u128);

        spending_limits.push(SpendingLimit {
            token: token_addr,
            amount,
        });
    }

    // Parse expiry
    let expiry_ts = match expiry {
        Some(s) => {
            let val: u64 = s.parse().map_err(|e| format!("invalid expiry: {e}"))?;
            // If it looks like a duration (< 1 billion), treat as seconds from now
            if val < 1_000_000_000 {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs();
                Some(now + val)
            } else {
                Some(val)
            }
        }
        None => None,
    };

    // Build KeyAuthorization
    let auth = KeyAuthorization {
        chain_id: wallet.chain_id,
        key_type: 1, // P-256
        key_id: access_key_address,
        expiry: expiry_ts,
        limits: spending_limits,
    };

    // Sign authorization with root key
    let signer = KeypoSigner::new();
    let root_label = wallet
        .root_key_id
        .strip_prefix("com.keypo.signer.")
        .unwrap_or(&wallet.root_key_id);
    // Sign and encode authorization
    let signed_auth = access_key::sign_and_encode_authorization(&auth, &signer, root_label)?;

    // Send a transaction signed by the root key, carrying the key_authorization field.
    // The root key signs the transaction that includes the authorization.
    let root_label = wallet
        .root_key_id
        .strip_prefix("com.keypo.signer.")
        .unwrap_or(&wallet.root_key_id);

    // The transaction needs at least one call — use a zero-value self-transfer
    let call = TempoCall {
        to: wallet_address,
        value: U256::ZERO,
        data: Bytes::new(),
    };

    let result = keypo_pay::transaction::send_tempo_tx(
        &rpc_url,
        &wallet,
        vec![call],
        &signer,
        root_label,
        None, // root key signs (P-256 signature)
        Some(signed_auth),
    )
    .await?;

    println!("Access key authorized!");
    println!("  Name:    {name}");
    println!("  Address: {access_key_address}");
    println!("  Tx hash: {}", result.tx_hash);
    println!("  Block:   {}", result.block_number);
    if let Some(exp) = expiry_ts {
        println!("  Expiry:  {exp}");
    }
    for (token_str, limit_str) in tokens.iter().zip(limits.iter()) {
        println!("  Limit:   {limit_str} {token_str}");
    }

    Ok(())
}

async fn run_access_key_list(
    rpc_override: Option<&str>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet = config::load_wallet_config()?;
    let access_keys = config::load_access_keys()?;
    let rpc_url = config::resolve_rpc(rpc_override, &wallet);
    let wallet_address: Address = wallet.address.parse().map_err(|e| format!("{e}"))?;
    let client = reqwest::Client::new();

    if access_keys.keys.is_empty() {
        println!("No access keys. Run 'keypo-pay access-key create --name <name>' to create one.");
        return Ok(());
    }

    println!("{:<15} {:<44} Status", "Name", "Address");
    println!("{}", "-".repeat(75));

    for key in &access_keys.keys {
        let key_addr: Address = key.address.parse().unwrap_or(Address::ZERO);
        let status = match access_key::query_key_status(&client, &rpc_url, wallet_address, key_addr)
            .await
        {
            Ok(Some(ks)) => {
                if ks.expiry > 0 {
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_secs();
                    if ks.expiry < now {
                        "expired".to_string()
                    } else {
                        format!("authorized (expires {})", ks.expiry)
                    }
                } else {
                    "authorized".to_string()
                }
            }
            Ok(None) => "not-yet-authorized".to_string(),
            Err(_) => "unknown (query failed)".to_string(),
        };
        println!("{:<15} {:<44} {}", key.name, key.address, status);
    }

    Ok(())
}

async fn run_access_key_info(
    rpc_override: Option<&str>,
    name: &str,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet = config::load_wallet_config()?;
    let access_keys = config::load_access_keys()?;
    let token_book = config::load_tokens()?;
    let rpc_url = config::resolve_rpc(rpc_override, &wallet);
    let wallet_address: Address = wallet.address.parse().map_err(|e| format!("{e}"))?;
    let client = reqwest::Client::new();

    let entry = access_keys
        .keys
        .iter()
        .find(|k| k.name == name)
        .ok_or_else(|| keypo_pay::Error::AccessKeyNotFound(name.to_string()))?;

    let key_addr: Address = entry.address.parse().map_err(|e| format!("{e}"))?;

    println!("Name:    {}", entry.name);
    println!("Address: {}", entry.address);
    println!("Key ID:  {}", entry.key_id);

    match access_key::query_key_status(&client, &rpc_url, wallet_address, key_addr).await {
        Ok(Some(ks)) => {
            println!("Status:  authorized (sigType={})", ks.signature_type);
            if ks.expiry > 0 {
                println!("Expiry:  {}", ks.expiry);
            } else {
                println!("Expiry:  none");
            }
            // Query remaining limits for known tokens
            for token in &token_book.tokens {
                let token_addr: Address = token.address.parse().unwrap_or(Address::ZERO);
                match access_key::query_remaining_limit(
                    &client,
                    &rpc_url,
                    wallet_address,
                    key_addr,
                    token_addr,
                )
                .await
                {
                    Ok(limit) if limit > U256::ZERO => {
                        // Query decimals for display
                        let decimals_data = keypo_pay::transaction::encode_decimals();
                        let decimals = keypo_pay::rpc::eth_call(
                            &client,
                            &rpc_url,
                            token_addr,
                            &decimals_data,
                        )
                        .await
                        .map(|r| if r.len() >= 32 { r[31] } else { 6 })
                        .unwrap_or(6);
                        let divisor = 10f64.powi(decimals as i32);
                        let display: f64 = limit.to::<u128>() as f64 / divisor;
                        println!("Limit:   {:.6} {} remaining", display, token.name);
                    }
                    _ => {}
                }
            }
        }
        Ok(None) => {
            println!("Status:  not-yet-authorized");
        }
        Err(e) => {
            println!("Status:  unknown (query failed: {e})");
        }
    }

    Ok(())
}

async fn run_access_key_revoke(
    rpc_override: Option<&str>,
    name: &str,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet = config::load_wallet_config()?;
    let access_keys = config::load_access_keys()?;
    let rpc_url = config::resolve_rpc(rpc_override, &wallet);

    let entry = access_keys
        .keys
        .iter()
        .find(|k| k.name == name)
        .ok_or_else(|| keypo_pay::Error::AccessKeyNotFound(name.to_string()))?;

    let key_addr: Address = entry.address.parse().map_err(|e| format!("{e}"))?;

    // Build revokeKey call to AccountKeychain precompile
    let calldata = access_key::encode_revoke_key(key_addr);
    let call = TempoCall {
        to: access_key::ACCOUNT_KEYCHAIN,
        value: U256::ZERO,
        data: calldata,
    };

    // Sign with root key
    let signer = KeypoSigner::new();
    let root_label = wallet
        .root_key_id
        .strip_prefix("com.keypo.signer.")
        .unwrap_or(&wallet.root_key_id);

    let result = keypo_pay::transaction::send_tempo_tx(
        &rpc_url,
        &wallet,
        vec![call],
        &signer,
        root_label,
        None,
        None,
    )
    .await?;

    println!("Access key revoked!");
    println!("  Name:    {name}");
    println!("  Tx hash: {}", result.tx_hash);
    println!("  Block:   {}", result.block_number);

    Ok(())
}

async fn run_access_key_update_limit(
    rpc_override: Option<&str>,
    name: &str,
    token: &str,
    limit: &str,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet = config::load_wallet_config()?;
    let access_keys = config::load_access_keys()?;
    let token_book = config::load_tokens()?;
    let rpc_url = config::resolve_rpc(rpc_override, &wallet);

    let entry = access_keys
        .keys
        .iter()
        .find(|k| k.name == name)
        .ok_or_else(|| keypo_pay::Error::AccessKeyNotFound(name.to_string()))?;

    let key_addr: Address = entry.address.parse().map_err(|e| format!("{e}"))?;
    let token_addr_str = config::resolve_token(token, &token_book.tokens)?;
    let token_addr: Address = token_addr_str.parse().map_err(|e| format!("{e}"))?;

    // Query decimals
    let client = reqwest::Client::new();
    let decimals_data = keypo_pay::transaction::encode_decimals();
    let decimals_result =
        keypo_pay::rpc::eth_call(&client, &rpc_url, token_addr, &decimals_data).await?;
    let decimals = if decimals_result.len() >= 32 {
        decimals_result[31]
    } else {
        6
    };

    let amount_f64: f64 = limit.parse().map_err(|e| format!("invalid limit: {e}"))?;
    let multiplier = 10f64.powi(decimals as i32);
    let new_limit = U256::from((amount_f64 * multiplier) as u128);

    let calldata = access_key::encode_update_spending_limit(key_addr, token_addr, new_limit);
    let call = TempoCall {
        to: access_key::ACCOUNT_KEYCHAIN,
        value: U256::ZERO,
        data: calldata,
    };

    let signer = KeypoSigner::new();
    let root_label = wallet
        .root_key_id
        .strip_prefix("com.keypo.signer.")
        .unwrap_or(&wallet.root_key_id);

    let result = keypo_pay::transaction::send_tempo_tx(
        &rpc_url,
        &wallet,
        vec![call],
        &signer,
        root_label,
        None,
        None,
    )
    .await?;

    println!("Spending limit updated!");
    println!("  Name:    {name}");
    println!("  Token:   {token}");
    println!("  Limit:   {limit}");
    println!("  Tx hash: {}", result.tx_hash);

    Ok(())
}

async fn run_access_key_delete(
    name: &str,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet = config::load_wallet_config()?;
    let mut access_keys = config::load_access_keys()?;
    let rpc_url = &wallet.rpc_url;
    let wallet_address: Address = wallet.address.parse().map_err(|e| format!("{e}"))?;

    let entry = access_keys
        .keys
        .iter()
        .find(|k| k.name == name)
        .ok_or_else(|| keypo_pay::Error::AccessKeyNotFound(name.to_string()))?
        .clone();

    // Check if still authorized on-chain and warn
    let key_addr: Address = entry.address.parse().unwrap_or(Address::ZERO);
    let client = reqwest::Client::new();
    if let Ok(Some(_)) =
        access_key::query_key_status(&client, rpc_url, wallet_address, key_addr).await
    {
        eprintln!(
            "Warning: access key '{}' is still authorized on-chain. \
             Run 'access-key revoke --name {}' first to revoke it.",
            name, name
        );
    }

    access_keys.keys.retain(|k| k.name != name);
    config::save_access_keys(&access_keys)?;

    println!("Access key '{}' deleted from local config.", name);

    Ok(())
}

async fn run_tx_send(
    rpc_override: Option<&str>,
    to: &str,
    token: &str,
    amount: &str,
    key_name: Option<&str>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let wallet = config::load_wallet_config()?;
    let tokens = config::load_tokens()?;
    let rpc_url = config::resolve_rpc(rpc_override, &wallet);

    // Resolve token address
    let token_addr_str = config::resolve_token(token, &tokens.tokens)?;
    let token_addr: Address = token_addr_str
        .parse()
        .map_err(|e| format!("invalid token address: {e}"))?;

    // Query token decimals
    let client = reqwest::Client::new();
    let decimals_data = keypo_pay::transaction::encode_decimals();
    let decimals_result = keypo_pay::rpc::eth_call(&client, &rpc_url, token_addr, &decimals_data).await
        .map_err(|e| format!("failed to query decimals: {e}"))?;
    let decimals = if decimals_result.len() >= 32 {
        decimals_result[31] // last byte of the 32-byte uint256
    } else {
        18 // fallback
    };
    tracing::debug!("token decimals: {decimals}");

    // Parse amount with correct decimals
    let amount_f64: f64 = amount
        .parse()
        .map_err(|e| format!("invalid amount '{amount}': {e}"))?;
    let multiplier = 10f64.powi(decimals as i32);
    let amount_wei = U256::from((amount_f64 * multiplier) as u128);

    // Resolve recipient
    let to_addr: Address = to
        .parse()
        .map_err(|e| format!("invalid --to address: {e}"))?;

    // Build TIP-20 transfer call
    let calldata = keypo_pay::transaction::encode_tip20_transfer(to_addr, amount_wei);
    let call = TempoCall {
        to: token_addr,
        value: U256::ZERO,
        data: calldata,
    };

    let signer = KeypoSigner::new();

    // Determine signing key and signature type
    let (signing_label, root_address) = if let Some(name) = key_name {
        // Access key signing (Keychain signature)
        let access_keys = config::load_access_keys()?;
        let entry = access_keys
            .keys
            .iter()
            .find(|k| k.name == name)
            .ok_or_else(|| keypo_pay::Error::AccessKeyNotFound(name.to_string()))?;
        let wallet_addr: Address = wallet.address.parse()
            .map_err(|e| format!("invalid wallet address: {e}"))?;
        (entry.key_id.split('.').next_back().unwrap_or(&entry.key_id).to_string(), Some(wallet_addr))
    } else {
        // Root key signing (P-256 signature)
        let label = wallet
            .root_key_id
            .strip_prefix("com.keypo.signer.")
            .unwrap_or(&wallet.root_key_id);
        (label.to_string(), None)
    };

    let result = keypo_pay::transaction::send_tempo_tx(
        &rpc_url,
        &wallet,
        vec![call],
        &signer,
        &signing_label,
        root_address,
        None,
    )
    .await?;

    println!("Transaction sent!");
    println!("  Tx hash:  {}", result.tx_hash);
    println!("  Block:    {}", result.block_number);
    println!("  Gas used: {}", result.gas_used);
    println!("  Success:  {}", result.success);

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn wallet_create_parses() {
        let cli = Cli::try_parse_from(["keypo-pay", "wallet", "create"]).unwrap();
        match cli.command {
            Commands::Wallet(WalletAction::Create { test }) => {
                assert!(!test);
            }
            _ => panic!("expected Wallet Create"),
        }
    }

    #[test]
    fn wallet_create_test_flag() {
        let cli = Cli::try_parse_from(["keypo-pay", "wallet", "create", "--test"]).unwrap();
        match cli.command {
            Commands::Wallet(WalletAction::Create { test }) => {
                assert!(test);
            }
            _ => panic!("expected Wallet Create"),
        }
    }

    #[test]
    fn wallet_info_parses() {
        let cli = Cli::try_parse_from(["keypo-pay", "wallet", "info"]).unwrap();
        assert!(matches!(cli.command, Commands::Wallet(WalletAction::Info)));
    }

    #[test]
    fn global_rpc_flag() {
        let cli =
            Cli::try_parse_from(["keypo-pay", "--rpc", "https://custom.rpc", "wallet", "info"])
                .unwrap();
        assert_eq!(cli.rpc, Some("https://custom.rpc".into()));
    }

    #[test]
    fn verbose_flag() {
        let cli =
            Cli::try_parse_from(["keypo-pay", "--verbose", "wallet", "info"]).unwrap();
        assert!(cli.verbose);
    }

    #[test]
    fn tx_send_parses() {
        let cli = Cli::try_parse_from([
            "keypo-pay",
            "tx",
            "send",
            "--to",
            "0xdead",
            "--token",
            "pathusd",
            "--amount",
            "0.01",
        ])
        .unwrap();
        match cli.command {
            Commands::Tx(TxAction::Send {
                to,
                token,
                amount,
                key,
            }) => {
                assert_eq!(to, "0xdead");
                assert_eq!(token, "pathusd");
                assert_eq!(amount, "0.01");
                assert!(key.is_none());
            }
            _ => panic!("expected Tx Send"),
        }
    }

    #[test]
    fn tx_send_with_key() {
        let cli = Cli::try_parse_from([
            "keypo-pay",
            "tx",
            "send",
            "--to",
            "0xdead",
            "--token",
            "pathusd",
            "--amount",
            "0.01",
            "--key",
            "agent-1",
        ])
        .unwrap();
        match cli.command {
            Commands::Tx(TxAction::Send { key, .. }) => {
                assert_eq!(key, Some("agent-1".into()));
            }
            _ => panic!("expected Tx Send"),
        }
    }

    #[test]
    fn access_key_create_parses() {
        let cli = Cli::try_parse_from([
            "keypo-pay", "access-key", "create", "--name", "agent-1",
        ]).unwrap();
        match cli.command {
            Commands::AccessKey(AccessKeyAction::Create { name }) => {
                assert_eq!(name, "agent-1");
            }
            _ => panic!("expected AccessKey Create"),
        }
    }

    #[test]
    fn access_key_authorize_parses() {
        let cli = Cli::try_parse_from([
            "keypo-pay", "access-key", "authorize",
            "--name", "agent-1",
            "--token", "pathusd", "--limit", "0.10",
        ]).unwrap();
        match cli.command {
            Commands::AccessKey(AccessKeyAction::Authorize { name, token, limit, expiry }) => {
                assert_eq!(name, "agent-1");
                assert_eq!(token, vec!["pathusd"]);
                assert_eq!(limit, vec!["0.10"]);
                assert!(expiry.is_none());
            }
            _ => panic!("expected AccessKey Authorize"),
        }
    }

    #[test]
    fn access_key_authorize_multi_token() {
        let cli = Cli::try_parse_from([
            "keypo-pay", "access-key", "authorize",
            "--name", "agent-1",
            "--token", "pathusd", "--limit", "0.10",
            "--token", "alphausd", "--limit", "0.05",
        ]).unwrap();
        match cli.command {
            Commands::AccessKey(AccessKeyAction::Authorize { token, limit, .. }) => {
                assert_eq!(token.len(), 2);
                assert_eq!(limit.len(), 2);
            }
            _ => panic!("expected AccessKey Authorize"),
        }
    }

    #[test]
    fn access_key_list_parses() {
        let cli = Cli::try_parse_from(["keypo-pay", "access-key", "list"]).unwrap();
        assert!(matches!(cli.command, Commands::AccessKey(AccessKeyAction::List)));
    }

    #[test]
    fn access_key_revoke_parses() {
        let cli = Cli::try_parse_from([
            "keypo-pay", "access-key", "revoke", "--name", "agent-1",
        ]).unwrap();
        match cli.command {
            Commands::AccessKey(AccessKeyAction::Revoke { name }) => {
                assert_eq!(name, "agent-1");
            }
            _ => panic!("expected AccessKey Revoke"),
        }
    }

    #[test]
    fn access_key_delete_parses() {
        let cli = Cli::try_parse_from([
            "keypo-pay", "access-key", "delete", "--name", "agent-1",
        ]).unwrap();
        match cli.command {
            Commands::AccessKey(AccessKeyAction::Delete { name }) => {
                assert_eq!(name, "agent-1");
            }
            _ => panic!("expected AccessKey Delete"),
        }
    }
}
