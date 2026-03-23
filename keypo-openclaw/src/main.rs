mod add;
mod config;
mod error;
mod init;
mod list;
mod naming;
mod remove;
mod resolve;
mod signer;
mod status;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "keypo-openclaw",
    about = "Hardware-secured secrets for OpenClaw",
    long_about = "Integrates keypo-signer's Secure Enclave vault with OpenClaw's SecretRef system.\n\n\
        Secrets are encrypted by hardware-bound P-256 keys in the Secure Enclave.\n\
        OpenClaw resolves them at gateway startup via the batched exec provider protocol.",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialize the vault and register the keypo provider in OpenClaw's config
    Init,

    /// Store a secret in the vault and write a SecretRef to the OpenClaw config
    #[command(long_about = "Store a secret in the vault and write a SecretRef to the OpenClaw config.\n\n\
        Examples:\n  \
        keypo-openclaw add TELEGRAM_BOT_TOKEN \"123456:ABCDEF\" --path channels.telegram.botToken\n  \
        keypo-openclaw add ANTHROPIC_API_KEY \"sk-ant-...\" --auth-profile anthropic:default --auth-type api_key\n  \
        keypo-openclaw add KEY \"val\" --path some.path --vault biometric")]
    Add {
        /// Vault name(s) and value(s). Format: NAME VALUE --path PATH [NAME VALUE --path PATH ...]
        #[arg(trailing_var_arg = true, required = true)]
        args: Vec<String>,

        /// Target an auth-profiles.json profile instead of openclaw.json
        #[arg(long)]
        auth_profile: Option<String>,

        /// Profile type: api_key or token (required with --auth-profile)
        #[arg(long)]
        auth_type: Option<String>,

        /// Vault policy tier for the secret
        #[arg(long, default_value = "open")]
        vault: String,

        /// Agent ID for auth-profiles.json targeting
        #[arg(long, default_value = "main")]
        agent: String,

        /// Update an existing secret instead of creating new
        #[arg(long)]
        update: bool,
    },

    /// Remove secrets from the vault and clean up SecretRefs from the config
    Remove {
        /// Vault name(s) to remove
        #[arg(required = true)]
        names: Vec<String>,

        /// Remove from vault only; leave SecretRefs in config
        #[arg(long)]
        keep_config: bool,

        /// Remove from config only; leave secret in vault
        #[arg(long)]
        keep_vault: bool,
    },

    /// Create or manage an encrypted vault backup in iCloud Drive
    Backup {
        /// Show backup status (last date, secret count, device)
        #[arg(long)]
        info: bool,

        /// Reset the backup encryption key and passphrase
        #[arg(long)]
        reset: bool,
    },

    /// Restore vault secrets from an iCloud Drive backup
    Restore,

    /// Resolve secrets for OpenClaw (exec provider protocol; not called directly)
    #[command(hide = true)]
    Resolve,

    /// List secrets stored in the vault
    List,

    /// Show the current state of the keypo-openclaw integration
    Status,
}

fn main() {
    let cli = Cli::parse();
    let signer = signer::VaultSigner::new();

    let result = match cli.command {
        Commands::Init => init::run(&signer),
        Commands::Add {
            args,
            auth_profile,
            auth_type,
            vault,
            agent,
            update,
        } => add::run(&signer, &args, auth_profile, auth_type, &vault, &agent, update),
        Commands::Remove {
            names,
            keep_config,
            keep_vault,
        } => remove::run(&signer, &names, keep_config, keep_vault),
        Commands::Backup { info, reset } => {
            if info {
                signer.vault_backup_info()
            } else if reset {
                signer.vault_backup_reset()
            } else {
                signer.vault_backup()
            }
        }
        Commands::Restore => signer.vault_restore(),
        Commands::Resolve => resolve::run(&signer),
        Commands::List => list::run(&signer),
        Commands::Status => status::run(&signer),
    };

    if let Err(e) = result {
        eprintln!("error: {e}");
        if let Some(hint) = e.suggestion() {
            eprintln!("  hint: {hint}");
        }
        std::process::exit(1);
    }
}
