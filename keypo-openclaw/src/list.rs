use crate::config;
use crate::error::{Error, Result};
use crate::signer::VaultSigner;

pub fn run(signer: &VaultSigner) -> Result<()> {
    if !signer.is_available() {
        return Err(Error::SignerNotFound("keypo-signer".into()));
    }

    if !signer.is_vault_initialized() {
        return Err(Error::VaultNotInitialized);
    }

    let entries = signer.vault_list()?;

    if entries.is_empty() {
        println!("Vault is empty.");
        return Ok(());
    }

    // Cross-reference with OpenClaw config
    let config_path = config::openclaw_config_path();
    let parsed = if config_path.exists() {
        config::read_jsonc(&config_path).ok()
    } else {
        eprintln!("Note: OpenClaw config not found — skipping SecretRef cross-reference.");
        None
    };

    println!("{:<30} {:<12} SECRETREF", "NAME", "TIER");
    println!("{}", "-".repeat(60));

    for entry in &entries {
        let has_ref = parsed
            .as_ref()
            .map(|p| !config::find_secret_refs(p, &entry.name).is_empty())
            .unwrap_or(false);

        let ref_marker = if has_ref { "yes" } else { "-" };
        println!("{:<30} {:<12} {}", entry.name, entry.vault, ref_marker);
    }

    println!("\n{} secret(s) in vault.", entries.len());
    Ok(())
}
