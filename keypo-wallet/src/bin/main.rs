use std::path::Path;
use std::time::Duration;

use alloy::primitives::{Address, Bytes, U256};
use clap::{Parser, Subcommand};
use keypo_wallet::account::{self, FundingStrategy, SetupConfig, SETUP_FUNDING_AMOUNT};
use keypo_wallet::config;
use keypo_wallet::impls::KeypoAccountImpl;
use keypo_wallet::signer::KeypoSigner;
use keypo_wallet::state::StateStore;
use keypo_wallet::types::Call;
use keypo_wallet::AccountImplementation;

#[derive(Parser)]
#[command(
    name = "keypo-wallet",
    about = "Keypo smart wallet CLI",
    long_about = "Keypo smart wallet CLI — manage ERC-4337 smart accounts with P-256 (Secure Enclave) signing.\n\n\
        Requires keypo-signer for key management: brew install keypo-us/tap/keypo-signer",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Enable verbose debug output
    #[arg(long, global = true)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialize config file
    #[command(
        long_about = "Initialize ~/.keypo/config.toml with RPC and bundler URLs.\n\n\
            Prompts interactively for URLs, or use --rpc/--bundler flags for non-interactive mode.",
        after_long_help = "\
EXAMPLES:
  # Interactive (prompts for each URL):
  keypo-wallet init

  # Non-interactive:
  keypo-wallet init --rpc https://sepolia.base.org --bundler https://api.pimlico.io/v2/84532/rpc?apikey=KEY

  # With optional paymaster:
  keypo-wallet init --rpc https://sepolia.base.org --bundler https://bundler.url --paymaster https://pm.url

OUTPUT:
  Config saved to ~/.keypo/config.toml

CONFIG RESOLUTION (all commands):
  CLI flag > env var > config file > error
  Env vars: KEYPO_RPC_URL, KEYPO_BUNDLER_URL, KEYPO_PAYMASTER_URL, KEYPO_PAYMASTER_POLICY_ID"
    )]
    Init {
        /// RPC URL (skip interactive prompt)
        #[arg(long)]
        rpc: Option<String>,

        /// Bundler URL (skip interactive prompt)
        #[arg(long)]
        bundler: Option<String>,

        /// Paymaster URL (optional)
        #[arg(long)]
        paymaster: Option<String>,
    },

    /// Manage config file
    #[command(
        subcommand,
        long_about = "View or modify ~/.keypo/config.toml settings."
    )]
    Config(ConfigAction),

    /// Set up a smart account on a chain
    #[command(
        long_about = "Set up a smart account on a chain.\n\n\
            Signs an EIP-7702 delegation to the KeypoAccount implementation, then sends an \
            initialization transaction to register the P-256 public key as the account owner.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet setup --key my-wallet --key-policy biometric
  keypo-wallet setup --key bot-wallet --key-policy open --rpc https://sepolia.base.org

OUTPUT:
  Address:  0x1234...abcd
  Tx hash:  0xabcd...1234
  Chain ID: 84532

NOTES:
  - Requires ETH for gas. The CLI prints the address and waits for you to fund it (~$1).
  - If TEST_FUNDER_PRIVATE_KEY is set, the CLI auto-funds the account.
  - Key policies: open, passcode, biometric."
    )]
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
    #[command(
        long_about = "Send a transaction via the ERC-4337 bundler.\n\n\
            Builds a UserOp, signs it with the P-256 key via keypo-signer, and submits it \
            to the bundler. Use --paymaster for gas sponsorship.",
        after_long_help = "\
EXAMPLES:
  # Send 0.001 ETH:
  keypo-wallet send --key my-wallet --to 0xRecipient --value 1000000000000000

  # Contract call with hex data:
  keypo-wallet send --key my-wallet --to 0xContract --data 0xa9059cbb000...

  # Pay gas from wallet (skip paymaster):
  keypo-wallet send --key my-wallet --to 0xRecipient --value 0 --no-paymaster

OUTPUT:
  UserOp hash: 0xabcd...1234
  Tx hash:     0xabcd...5678
  Success:     true

VALUE FORMATS:
  --value: decimal wei (e.g. 1000000000000000 = 0.001 ETH)
  --data:  0x-prefixed hex calldata
  --to:    0x-prefixed 20-byte address"
    )]
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

        /// Skip paymaster even if configured
        #[arg(long)]
        no_paymaster: bool,
    },

    /// Send a batch of calls
    #[command(
        long_about = "Send a batch of calls in a single UserOp.\n\n\
            Reads a JSON file containing an array of {to, value, data} objects and executes \
            them atomically via ERC-7821 batch mode. Pass '--calls -' to read from stdin.",
        after_long_help = "\
EXAMPLES:
  # From file:
  keypo-wallet batch --key my-wallet --calls batch.json

  # From stdin:
  cat batch.json | keypo-wallet batch --key my-wallet --calls -

CALLS JSON SCHEMA:
  [{\"to\": \"0xAddr\", \"value\": \"0x0\", \"data\": \"0x\"}]
  Values are 0x-prefixed hex (e.g. \"0x38d7ea4c68000\" = 0.001 ETH).

OUTPUT:
  UserOp hash: 0xabcd...1234
  Tx hash:     0xabcd...5678
  Success:     true"
    )]
    Batch {
        /// Key label for the signing key
        #[arg(long)]
        key: String,

        /// Path to JSON file with calls, or - for stdin
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

        /// Skip paymaster even if configured
        #[arg(long)]
        no_paymaster: bool,
    },

    /// Show account info
    #[command(
        long_about = "Show account info from local state (no RPC calls).\n\n\
            Displays the account address, key label, and chain deployments stored in \
            ~/.keypo/accounts.json.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet info --key my-wallet

OUTPUT:
  Label:   my-wallet
  Address: 0x1234...abcd
  Chains:  84532

NOTE: This reads local state only (no RPC). Use 'wallet-info' for live on-chain data."
    )]
    Info {
        /// Key label for the signing key
        #[arg(long)]
        key: String,

        /// Chain ID
        #[arg(long)]
        chain_id: Option<u64>,
    },

    /// Check account balance
    #[command(
        long_about = "Check account balance for native ETH and ERC-20 tokens.\n\n\
            Supports --token for specific ERC-20 contract addresses, --query for JSON \
            query files, and --format for table/json/csv output.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet balance --key my-wallet
  keypo-wallet balance --key my-wallet --token 0xUSDC_ADDRESS
  keypo-wallet balance --key my-wallet --query balances.json --format json
  keypo-wallet balance --key my-wallet --format csv

TABLE OUTPUT:
  Chain    Token  Balance
  84532    ETH    0.042000000000000000

JSON OUTPUT:
  {\"account\": \"0x1234...abcd\", \"balances\": [{\"chain_id\": 84532, \"token\": \"ETH\", \"balance\": \"0.042\", \"raw\": \"42000000000000000\"}]}

CSV OUTPUT:
  chain_id,token,balance,raw_balance
  84532,ETH,0.042000000000000000,42000000000000000"
    )]
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

    // -- Signer passthrough commands --
    /// Create a new signing key
    #[command(
        long_about = "Create a new P-256 signing key in the Secure Enclave via keypo-signer.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet create --label my-key --policy biometric
  keypo-wallet create --label bot-key --policy open

OUTPUT (JSON from keypo-signer):
  {\"label\": \"my-key\", \"policy\": \"biometric\", \"publicKey\": {\"x\": \"0x...\", \"y\": \"0x...\"}}

POLICIES: open, passcode, biometric"
    )]
    Create {
        /// Key label
        #[arg(long)]
        label: String,

        /// Access policy (open/passcode/biometric)
        #[arg(long, default_value = "biometric")]
        policy: String,
    },

    /// List all signing keys
    #[command(long_about = "List all P-256 keys managed by keypo-signer.")]
    List {
        /// Output format (json/pretty)
        #[arg(long)]
        format: Option<String>,
    },

    /// Show key info
    #[command(
        name = "key-info",
        long_about = "Show details for a specific signing key."
    )]
    KeyInfo {
        /// Key label
        label: String,

        /// Output format (json/pretty/raw)
        #[arg(long)]
        format: Option<String>,
    },

    /// Sign a digest
    #[command(
        long_about = "Sign a 32-byte hex digest with a P-256 key via keypo-signer.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet sign 0x$(openssl rand -hex 32) --key my-key
  keypo-wallet sign 0xabcd...1234 --key my-key --format json

NOTE: Digest must be 0x-prefixed, exactly 32 bytes (64 hex chars).

OUTPUT (JSON):
  {\"r\": \"0x...\", \"s\": \"0x...\"}"
    )]
    Sign {
        /// Hex-encoded 32-byte digest
        digest: String,

        /// Key label
        #[arg(long)]
        key: String,

        /// Output format (json/pretty/raw)
        #[arg(long)]
        format: Option<String>,
    },

    /// Verify a signature
    #[command(
        long_about = "Verify a P-256 signature against a digest and key.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet verify 0xDIGEST --key my-key --r 0xR_VALUE --s 0xS_VALUE

OUTPUT (JSON):
  {\"valid\": true}"
    )]
    Verify {
        /// Hex-encoded 32-byte digest
        digest: String,

        /// Key label
        #[arg(long)]
        key: String,

        /// r component (hex)
        #[arg(long)]
        r: String,

        /// s component (hex)
        #[arg(long)]
        s: String,
    },

    /// Delete a signing key
    #[command(long_about = "Delete a signing key from the Secure Enclave via keypo-signer.")]
    Delete {
        /// Key label
        #[arg(long)]
        label: String,

        /// Skip confirmation prompt
        #[arg(long)]
        confirm: bool,
    },

    /// Rotate a signing key
    #[command(long_about = "Rotate a signing key via keypo-signer.")]
    Rotate {
        /// Key label to rotate
        #[arg(long)]
        label: String,
    },

    /// List all wallets (accounts)
    #[command(
        name = "wallet-list",
        long_about = "List all smart wallet accounts with optional live balances.\n\n\
            Shows label, policy, address, chains, and ETH balance for each account. \
            Defaults to JSON output. Use --no-balance to skip RPC queries.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet wallet-list
  keypo-wallet wallet-list --no-balance
  keypo-wallet wallet-list --format table
  keypo-wallet wallet-list --format csv

JSON OUTPUT (default):
  {\"wallets\": [{\"label\": \"my-wallet\", \"policy\": \"open\", \"address\": \"0x1234...abcd\", \"chains\": [84532], \"eth_balance\": \"0.042\"}]}

TABLE OUTPUT:
  Label       Policy  Address                                      Chains  ETH Balance
  my-wallet   open    0x1234567890abcdef1234567890abcdef12345678   84532   0.042

CSV HEADER:
  label,policy,address,chains,eth_balance,eth_balance_raw"
    )]
    WalletList {
        /// RPC URL for balance queries
        #[arg(long)]
        rpc: Option<String>,

        /// Output format (table/json/csv)
        #[arg(long)]
        format: Option<String>,

        /// Skip live balance queries
        #[arg(long)]
        no_balance: bool,
    },

    /// Show detailed wallet info
    #[command(
        name = "wallet-info",
        long_about = "Show detailed info for a specific wallet account, including P-256 \
            public key coordinates and per-chain deployment details.",
        after_long_help = "\
EXAMPLES:
  keypo-wallet wallet-info --key my-wallet
  keypo-wallet wallet-info --key my-wallet --format json

TABLE OUTPUT:
  Wallet:     my-wallet
  Address:    0x1234...abcd
  Policy:     biometric
  Status:     deployed
  Public Key:
    x: 0xabc...
    y: 0xdef...
  Chains:
    84532 — ETH: 0.042

JSON OUTPUT:
  {\"label\": \"my-wallet\", \"address\": \"0x...\", \"policy\": \"biometric\", \"status\": \"deployed\", \"public_key\": {\"x\": \"0x...\", \"y\": \"0x...\"}, \"chains\": [{\"chain_id\": 84532, \"eth_balance\": \"0.042\"}]}"
    )]
    WalletInfo {
        /// Key label
        #[arg(long)]
        key: String,

        /// RPC URL for balance queries
        #[arg(long)]
        rpc: Option<String>,

        /// Output format (table/json)
        #[arg(long)]
        format: Option<String>,
    },
}

#[derive(Subcommand, Clone)]
enum ConfigAction {
    /// Set a config value
    Set {
        /// Config key (e.g. network.rpc_url)
        key: String,
        /// Config value
        value: String,
    },
    /// Show current config
    Show {
        /// Reveal sensitive values (API keys)
        #[arg(long)]
        reveal: bool,
    },
    /// Open config in $EDITOR
    Edit,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let filter = tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        if cli.verbose {
            tracing_subscriber::EnvFilter::new("keypo_wallet=debug")
        } else {
            tracing_subscriber::EnvFilter::new("keypo_wallet=warn")
        }
    });
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .try_init()
        .ok();

    // Validate config on every invocation (if file exists)
    let cfg = match config::load_config() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: {e}");
            if let Some(hint) = e.suggestion() {
                eprintln!("  Hint: {hint}");
            }
            std::process::exit(1);
        }
    };

    let result = match cli.command {
        Commands::Init {
            rpc,
            bundler,
            paymaster,
        } => run_init(rpc, bundler, paymaster).await,

        Commands::Config(action) => run_config(action, &cfg).await,

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
                &cfg,
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
            no_paymaster,
        } => {
            run_send(
                key,
                to,
                value,
                data,
                chain_id,
                bundler,
                paymaster,
                paymaster_policy,
                rpc,
                no_paymaster,
                &cfg,
            )
            .await
        }

        Commands::Batch {
            key,
            calls,
            chain_id,
            bundler,
            paymaster,
            paymaster_policy,
            rpc,
            no_paymaster,
        } => {
            run_batch(
                key,
                calls,
                chain_id,
                bundler,
                paymaster,
                paymaster_policy,
                rpc,
                no_paymaster,
                &cfg,
            )
            .await
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

        // Signer passthrough commands
        Commands::Create { label, policy } => {
            run_signer_passthrough(&["create", "--label", &label, "--policy", &policy])
        }
        Commands::List { format } => {
            let mut args = vec!["list"];
            let fmt;
            if let Some(ref f) = format {
                fmt = f.clone();
                args.extend(["--format", &fmt]);
            }
            run_signer_passthrough(&args)
        }
        Commands::KeyInfo { label, format } => {
            let mut args = vec!["info", &label];
            let fmt;
            if let Some(ref f) = format {
                fmt = f.clone();
                args.extend(["--format", &fmt]);
            }
            run_signer_passthrough(&args)
        }
        Commands::Sign {
            digest,
            key,
            format,
        } => {
            let mut args = vec!["sign", &digest, "--key", &key];
            let fmt;
            if let Some(ref f) = format {
                fmt = f.clone();
                args.extend(["--format", &fmt]);
            }
            run_signer_passthrough(&args)
        }
        Commands::Verify { digest, key, r, s } => {
            run_signer_passthrough(&["verify", &digest, "--key", &key, "--r", &r, "--s", &s])
        }
        Commands::Delete { label, confirm } => {
            let mut args = vec!["delete", "--label", &label];
            if confirm {
                args.push("--confirm");
            }
            run_signer_passthrough(&args)
        }
        Commands::Rotate { label } => run_signer_passthrough(&["rotate", "--label", &label]),

        Commands::WalletList {
            rpc,
            format,
            no_balance,
        } => run_wallet_list(rpc, format, no_balance, &cfg).await,

        Commands::WalletInfo { key, rpc, format } => run_wallet_info(key, rpc, format, &cfg).await,
    };

    if let Err(e) = result {
        eprintln!("Error: {e}");
        if let Some(ke) = e.downcast_ref::<keypo_wallet::Error>() {
            if let Some(hint) = ke.suggestion() {
                eprintln!("  Hint: {hint}");
            }
        }
        std::process::exit(1);
    }
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

async fn run_init(
    rpc: Option<String>,
    bundler: Option<String>,
    paymaster: Option<String>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let path = config::config_path()?;

    // Non-interactive mode if --rpc and --bundler provided
    if let (Some(rpc_url), Some(bundler_url)) = (rpc, bundler) {
        let cfg = config::Config {
            rpc_url: Some(rpc_url),
            bundler_url: Some(bundler_url),
            paymaster_url: paymaster,
            paymaster_policy_id: None,
        };
        config::save_config_at(&cfg, &path)?;
        println!("Config saved to {}", path.display());
        println!("Next: keypo-wallet setup --key <label>");
        return Ok(());
    }

    // Interactive mode
    let stdin = std::io::stdin();
    let mut reader = stdin.lock();
    let stdout = std::io::stdout();
    let mut writer = stdout.lock();

    config::run_init_interactive(&mut reader, &mut writer, &path, false)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// config
// ---------------------------------------------------------------------------

async fn run_config(
    action: ConfigAction,
    cfg: &Option<config::Config>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    match action {
        ConfigAction::Set { key, value } => {
            config::set_config_value(&key, &value)?;
            println!("{key} = {}", config::redact_url(&value));
        }
        ConfigAction::Show { reveal } => {
            print!("{}", config::format_config_show(cfg, reveal));
        }
        ConfigAction::Edit => {
            let path = config::config_path()?;

            // Create with template if missing
            if !path.exists() {
                let template = r#"# Keypo Wallet Configuration
# See: keypo-wallet config show

[network]
# rpc_url = "https://sepolia.base.org"
# bundler_url = "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_KEY"
# paymaster_url = "https://api.pimlico.io/v2/84532/rpc?apikey=YOUR_KEY"
# paymaster_policy_id = "sp_your_policy"
"#;
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::write(&path, template)?;
            }

            let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".into());
            let status = std::process::Command::new(&editor)
                .arg(&path)
                .status()
                .map_err(|e| format!("failed to launch editor '{editor}': {e}"))?;

            if !status.success() {
                return Err(format!("editor exited with {status}").into());
            }

            // Validate after edit
            if let Err(e) = config::load_config_at(&path) {
                eprintln!("Warning: config file has errors after editing: {e}");
                eprintln!("Run 'keypo-wallet config edit' again to fix.");
            } else {
                println!("Config saved.");
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// signer passthrough
// ---------------------------------------------------------------------------

fn run_signer_passthrough(args: &[&str]) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let signer = KeypoSigner::new();
    signer.run_raw(args)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// setup (with config wiring)
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn run_setup(
    key: String,
    key_policy: String,
    rpc: Option<String>,
    bundler: Option<String>,
    chain_id: Option<u64>,
    paymaster: Option<String>,
    implementation: Option<String>,
    impl_name: String,
    cfg: &Option<config::Config>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let rpc_url = config::resolve_rpc(rpc.as_deref(), cfg)?;

    // Resolve implementation address and chain_id
    let (impl_address, resolved_chain_id, imp) = if let Some(ref addr_str) = implementation {
        // Explicit implementation address provided
        let addr: Address = addr_str
            .parse()
            .map_err(|e| format!("invalid --implementation address: {e}"))?;
        let imp = KeypoAccountImpl::new();
        (addr, chain_id, imp)
    } else {
        // Need chain_id to look up deployment
        let cid = if let Some(id) = chain_id {
            id
        } else {
            // Auto-detect chain_id from RPC
            use alloy::providers::{Provider, ProviderBuilder};
            let url: url::Url = rpc_url
                .parse()
                .map_err(|e: url::ParseError| format!("invalid RPC URL: {e}"))?;
            let provider = ProviderBuilder::new().connect_http(url);
            provider
                .get_chain_id()
                .await
                .map_err(|e| format!("failed to get chain ID: {e}"))?
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

    let setup_config = SetupConfig {
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

    let result = account::setup(&setup_config, &imp, &signer, &mut state, funding).await?;

    println!("Account setup complete!");
    println!("  Address:  {}", result.account_address);
    println!("  Tx hash:  {}", result.tx_hash);
    println!("  Chain ID: {}", result.chain_id);

    Ok(())
}

// ---------------------------------------------------------------------------
// resolve account + chain
// ---------------------------------------------------------------------------

/// Resolves account and chain deployment, applying CLI overrides and config fallbacks.
fn resolve_account_and_chain(
    state: &StateStore,
    key: &str,
    chain_id: Option<u64>,
    bundler_override: Option<String>,
    paymaster_override: Option<String>,
    rpc_override: Option<String>,
    cfg: &Option<config::Config>,
) -> std::result::Result<
    (
        keypo_wallet::types::AccountRecord,
        keypo_wallet::types::ChainDeployment,
    ),
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

    // Apply CLI overrides, then config fallbacks
    let mut chain = chain;
    if let Some(b) = bundler_override {
        chain.bundler_url = Some(b);
    } else if chain.bundler_url.is_none() {
        chain.bundler_url = cfg.as_ref().and_then(|c| c.bundler_url.clone());
    }
    if let Some(p) = paymaster_override {
        chain.paymaster_url = Some(p);
    } else if chain.paymaster_url.is_none() {
        chain.paymaster_url = cfg.as_ref().and_then(|c| c.paymaster_url.clone());
    }
    if let Some(r) = rpc_override {
        chain.rpc_url = r;
    }

    Ok((account, chain))
}

// ---------------------------------------------------------------------------
// send
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
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
    no_paymaster: bool,
    cfg: &Option<config::Config>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let state = StateStore::open()?;

    // Resolve paymaster: if --no-paymaster, suppress
    let effective_paymaster = if no_paymaster { None } else { paymaster };
    let (account, chain) = resolve_account_and_chain(
        &state,
        &key,
        chain_id,
        bundler,
        effective_paymaster,
        rpc,
        cfg,
    )?;

    // If --no-paymaster, also clear paymaster_url from chain
    let mut chain = chain;
    if no_paymaster {
        chain.paymaster_url = None;
    }

    let signer = KeypoSigner::new();
    let imp = load_deployments_impl();

    // Parse call fields
    let to_addr: Address = to
        .parse()
        .map_err(|e| format!("invalid --to address: {e}"))?;
    let call_value: U256 = value.parse().map_err(|e| format!("invalid --value: {e}"))?;
    let call_data = if let Some(ref d) = data {
        let stripped = d
            .strip_prefix("0x")
            .or_else(|| d.strip_prefix("0X"))
            .unwrap_or(d);
        Bytes::from(hex::decode(stripped).map_err(|e| format!("invalid --data hex: {e}"))?)
    } else {
        Bytes::new()
    };

    let call = Call {
        to: to_addr,
        value: call_value,
        data: call_data,
    };

    let pm_policy = config::resolve_paymaster_policy(paymaster_policy.as_deref(), cfg);
    let pm_context = pm_policy.map(|id| serde_json::json!({"sponsorshipPolicyId": id}));
    let result = keypo_wallet::transaction::execute_with_context(
        &account,
        &chain,
        &[call],
        &imp,
        &signer,
        pm_context,
    )
    .await?;

    println!("Transaction sent!");
    println!("  UserOp hash: {}", result.user_op_hash);
    println!("  Tx hash:     {}", result.tx_hash);
    println!("  Success:     {}", result.success);

    Ok(())
}

// ---------------------------------------------------------------------------
// batch
// ---------------------------------------------------------------------------

#[allow(clippy::too_many_arguments)]
async fn run_batch(
    key: String,
    calls_path: String,
    chain_id: Option<u64>,
    bundler: Option<String>,
    paymaster: Option<String>,
    paymaster_policy: Option<String>,
    rpc: Option<String>,
    no_paymaster: bool,
    cfg: &Option<config::Config>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    let state = StateStore::open()?;

    let effective_paymaster = if no_paymaster { None } else { paymaster };
    let (account, chain) = resolve_account_and_chain(
        &state,
        &key,
        chain_id,
        bundler,
        effective_paymaster,
        rpc,
        cfg,
    )?;

    let mut chain = chain;
    if no_paymaster {
        chain.paymaster_url = None;
    }

    let signer = KeypoSigner::new();
    let imp = load_deployments_impl();

    // Read and parse calls JSON — "-" means stdin
    let calls_json = if calls_path == "-" {
        use std::io::Read;
        let mut buf = String::new();
        std::io::stdin()
            .read_to_string(&mut buf)
            .map_err(|e| format!("failed to read calls from stdin: {e}"))?;
        buf
    } else {
        std::fs::read_to_string(&calls_path)
            .map_err(|e| format!("failed to read calls file '{calls_path}': {e}"))?
    };
    let calls: Vec<Call> = serde_json::from_str(&calls_json)
        .map_err(|e| format!("failed to parse calls JSON: {e}"))?;

    let pm_policy = config::resolve_paymaster_policy(paymaster_policy.as_deref(), cfg);
    let pm_context = pm_policy.map(|id| serde_json::json!({"sponsorshipPolicyId": id}));
    let result = keypo_wallet::transaction::execute_with_context(
        &account, &chain, &calls, &imp, &signer, pm_context,
    )
    .await?;

    println!("Batch transaction sent!");
    println!("  UserOp hash: {}", result.user_op_hash);
    println!("  Tx hash:     {}", result.tx_hash);
    println!("  Success:     {}", result.success);

    Ok(())
}

// ---------------------------------------------------------------------------
// info
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// balance
// ---------------------------------------------------------------------------

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
    let chains = query::resolve_chains(&account, chain_id, balance_query.as_ref())?;

    // Resolve tokens
    let tokens = query::resolve_tokens(token.as_deref(), balance_query.as_ref())?;

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
                let token_addr: Address = token_str
                    .parse()
                    .map_err(|e| format!("invalid token address '{token_str}': {e}"))?;
                match query::query_erc20_balance(&provider, token_addr, account.address).await {
                    Ok(balance) => {
                        let decimals = query::query_erc20_decimals(&provider, token_addr).await;
                        let symbol = query::query_erc20_symbol(&provider, token_addr).await;
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

// ---------------------------------------------------------------------------
// wallet-list
// ---------------------------------------------------------------------------

async fn run_wallet_list(
    rpc: Option<String>,
    format: Option<String>,
    no_balance: bool,
    cfg: &Option<config::Config>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    use alloy::providers::{Provider, ProviderBuilder};
    use keypo_wallet::query;
    use keypo_wallet::types::WalletListEntry;

    let state = StateStore::open()?;
    let accounts = state.list_accounts();

    if accounts.is_empty() {
        println!("No wallets found. Run 'keypo-wallet setup' to create one.");
        return Ok(());
    }

    // Resolve RPC for balance queries
    let rpc_url = if no_balance {
        None
    } else {
        // Try CLI --rpc, then config
        let resolved = rpc.or_else(|| cfg.as_ref().and_then(|c| c.rpc_url.clone()));
        resolved
    };

    let mut entries = Vec::new();
    for account in accounts {
        let chain_names: Vec<String> = account
            .chains
            .iter()
            .map(|c| {
                query::chain_name(c.chain_id)
                    .unwrap_or("Unknown")
                    .to_string()
            })
            .collect();

        let eth_balance = if no_balance {
            None
        } else {
            // Try account's first chain RPC, or the provided RPC
            let url_str = rpc_url
                .as_deref()
                .or_else(|| account.chains.first().map(|c| c.rpc_url.as_str()));
            match url_str {
                Some(u) => {
                    if let Ok(url) = u.parse::<url::Url>() {
                        let provider = ProviderBuilder::new().connect_http(url);
                        provider.get_balance(account.address).await.ok()
                    } else {
                        None
                    }
                }
                None => None,
            }
        };

        entries.push(WalletListEntry {
            label: account.key_label.clone(),
            policy: account.key_policy.clone(),
            address: account.address,
            chains: chain_names,
            eth_balance,
        });
    }

    let fmt = format.unwrap_or_else(|| "json".to_string());
    let output = match fmt.as_str() {
        "json" => query::format_wallet_list_json(&entries),
        "csv" => query::format_wallet_list_csv(&entries),
        _ => query::format_wallet_list_table(&entries, false),
    };
    print!("{output}");

    Ok(())
}

// ---------------------------------------------------------------------------
// wallet-info
// ---------------------------------------------------------------------------

async fn run_wallet_info(
    key: String,
    rpc: Option<String>,
    format: Option<String>,
    cfg: &Option<config::Config>,
) -> std::result::Result<(), Box<dyn std::error::Error>> {
    use alloy::providers::{Provider, ProviderBuilder};
    use keypo_wallet::query;

    let state = StateStore::open()?;
    let account = state
        .find_accounts_for_key(&key)
        .ok_or_else(|| format!("no account found for key '{key}'"))?
        .clone();

    // Fetch ETH balance per chain
    let mut balances: Vec<(u64, U256)> = Vec::new();
    for chain in &account.chains {
        let url_str = rpc.as_deref().unwrap_or(&chain.rpc_url);
        if let Ok(url) = url_str.parse::<url::Url>() {
            let provider = ProviderBuilder::new().connect_http(url);
            if let Ok(balance) = provider.get_balance(account.address).await {
                balances.push((chain.chain_id, balance));
            }
        }
    }

    let _ = cfg; // config used for RPC resolution above

    let fmt = format.unwrap_or_else(|| "table".to_string());
    let output = match fmt.as_str() {
        "json" => query::format_wallet_info_json(&account, &balances),
        _ => query::format_wallet_info(&account, &balances),
    };
    print!("{output}");

    Ok(())
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

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
                key, token, query, ..
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

    #[test]
    fn verbose_flag_parses() {
        let cli =
            Cli::try_parse_from(["keypo-wallet", "--verbose", "info", "--key", "my-key"]).unwrap();
        assert!(cli.verbose);
    }

    #[test]
    fn long_about_present() {
        use clap::CommandFactory;
        assert!(Cli::command().get_long_about().is_some());
    }

    // -- Phase B: New command arg parsing tests --

    #[test]
    fn init_args_parse() {
        let cli = Cli::try_parse_from(["keypo-wallet", "init"]).unwrap();
        assert!(matches!(cli.command, Commands::Init { .. }));
    }

    #[test]
    fn init_args_non_interactive() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "init",
            "--rpc",
            "https://rpc.example.com",
            "--bundler",
            "https://bundler.example.com",
            "--paymaster",
            "https://pm.example.com",
        ])
        .unwrap();
        match cli.command {
            Commands::Init {
                rpc,
                bundler,
                paymaster,
            } => {
                assert_eq!(rpc, Some("https://rpc.example.com".into()));
                assert_eq!(bundler, Some("https://bundler.example.com".into()));
                assert_eq!(paymaster, Some("https://pm.example.com".into()));
            }
            _ => panic!("expected Init"),
        }
    }

    #[test]
    fn config_set_args_parse() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "config",
            "set",
            "network.rpc_url",
            "https://rpc.example.com",
        ])
        .unwrap();
        match cli.command {
            Commands::Config(ConfigAction::Set { key, value }) => {
                assert_eq!(key, "network.rpc_url");
                assert_eq!(value, "https://rpc.example.com");
            }
            _ => panic!("expected Config Set"),
        }
    }

    #[test]
    fn config_show_args_parse() {
        let cli = Cli::try_parse_from(["keypo-wallet", "config", "show", "--reveal"]).unwrap();
        match cli.command {
            Commands::Config(ConfigAction::Show { reveal }) => {
                assert!(reveal);
            }
            _ => panic!("expected Config Show"),
        }
    }

    #[test]
    fn config_edit_args_parse() {
        let cli = Cli::try_parse_from(["keypo-wallet", "config", "edit"]).unwrap();
        assert!(matches!(cli.command, Commands::Config(ConfigAction::Edit)));
    }

    #[test]
    fn create_args_parse() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "create",
            "--label",
            "my-key",
            "--policy",
            "open",
        ])
        .unwrap();
        match cli.command {
            Commands::Create { label, policy } => {
                assert_eq!(label, "my-key");
                assert_eq!(policy, "open");
            }
            _ => panic!("expected Create"),
        }
    }

    #[test]
    fn list_args_parse() {
        let cli = Cli::try_parse_from(["keypo-wallet", "list", "--format", "json"]).unwrap();
        match cli.command {
            Commands::List { format } => {
                assert_eq!(format, Some("json".into()));
            }
            _ => panic!("expected List"),
        }
    }

    #[test]
    fn key_info_args_parse() {
        let cli = Cli::try_parse_from(["keypo-wallet", "key-info", "my-key", "--format", "json"])
            .unwrap();
        match cli.command {
            Commands::KeyInfo { label, format } => {
                assert_eq!(label, "my-key");
                assert_eq!(format, Some("json".into()));
            }
            _ => panic!("expected KeyInfo"),
        }
    }

    #[test]
    fn sign_args_parse() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "sign",
            "0xabcd",
            "--key",
            "my-key",
            "--format",
            "raw",
        ])
        .unwrap();
        match cli.command {
            Commands::Sign {
                digest,
                key,
                format,
            } => {
                assert_eq!(digest, "0xabcd");
                assert_eq!(key, "my-key");
                assert_eq!(format, Some("raw".into()));
            }
            _ => panic!("expected Sign"),
        }
    }

    #[test]
    fn delete_args_parse() {
        let cli = Cli::try_parse_from(["keypo-wallet", "delete", "--label", "my-key", "--confirm"])
            .unwrap();
        match cli.command {
            Commands::Delete { label, confirm } => {
                assert_eq!(label, "my-key");
                assert!(confirm);
            }
            _ => panic!("expected Delete"),
        }
    }

    #[test]
    fn wallet_list_args_parse() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "wallet-list",
            "--format",
            "json",
            "--no-balance",
        ])
        .unwrap();
        match cli.command {
            Commands::WalletList {
                format,
                no_balance,
                ..
            } => {
                assert_eq!(format, Some("json".into()));
                assert!(no_balance);
            }
            _ => panic!("expected WalletList"),
        }
    }

    #[test]
    fn wallet_list_no_balance_flag() {
        let cli = Cli::try_parse_from(["keypo-wallet", "wallet-list", "--no-balance"]).unwrap();
        match cli.command {
            Commands::WalletList { no_balance, .. } => {
                assert!(no_balance);
            }
            _ => panic!("expected WalletList"),
        }
    }

    #[test]
    fn wallet_info_args_parse() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "wallet-info",
            "--key",
            "my-key",
            "--rpc",
            "https://rpc.example.com",
        ])
        .unwrap();
        match cli.command {
            Commands::WalletInfo { key, rpc, .. } => {
                assert_eq!(key, "my-key");
                assert_eq!(rpc, Some("https://rpc.example.com".into()));
            }
            _ => panic!("expected WalletInfo"),
        }
    }

    #[test]
    fn send_no_paymaster_flag() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "send",
            "--key",
            "my-key",
            "--to",
            "0xdead",
            "--no-paymaster",
        ])
        .unwrap();
        match cli.command {
            Commands::Send { no_paymaster, .. } => {
                assert!(no_paymaster);
            }
            _ => panic!("expected Send"),
        }
    }

    #[test]
    fn batch_no_paymaster_flag() {
        let cli = Cli::try_parse_from([
            "keypo-wallet",
            "batch",
            "--key",
            "my-key",
            "--calls",
            "calls.json",
            "--no-paymaster",
        ])
        .unwrap();
        match cli.command {
            Commands::Batch { no_paymaster, .. } => {
                assert!(no_paymaster);
            }
            _ => panic!("expected Batch"),
        }
    }
}
