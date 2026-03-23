use crate::config;
use crate::error::{Error, Result};
use crate::signer::VaultSigner;

pub fn run(signer: &VaultSigner) -> Result<()> {
    // 1. Verify keypo-signer is on PATH
    if !signer.is_available() {
        return Err(Error::SignerNotFound(
            "keypo-signer not found. Install with: brew install keypo-us/tap/keypo-signer".into(),
        ));
    }

    // 2. Verify openclaw.json exists
    let config_path = config::openclaw_config_path();
    if !config_path.exists() {
        return Err(Error::ConfigNotFound(format!(
            "OpenClaw config not found at {}. Is OpenClaw installed?",
            config_path.display()
        )));
    }

    // 3. Check if vault already initialized
    let vault_exists = signer.is_vault_initialized();

    if !vault_exists {
        // 4. Check for iCloud backup
        let backup_path = config::icloud_backup_path();
        if backup_path.exists() {
            eprintln!(
                "Found an existing vault backup in iCloud Drive. Would you like to restore it? [y/N] "
            );

            let mut answer = String::new();
            if std::io::stdin().read_line(&mut answer).is_ok()
                && answer.trim().eq_ignore_ascii_case("y")
            {
                match signer.vault_restore() {
                    Ok(()) => {
                        eprintln!("Vault restored successfully.");
                    }
                    Err(e) => {
                        eprintln!("Restore failed: {e}");
                        eprintln!("Proceeding with fresh vault initialization.");
                        signer.vault_init()?;
                    }
                }
            } else {
                signer.vault_init()?;
            }
        } else {
            // 5. No backup — fresh init
            signer.vault_init()?;
        }
    }

    // 6. Read and update openclaw.json
    let raw = config::read_raw(&config_path)?;
    let parsed = config::parse_jsonc(&raw)?;

    let has_provider = config::has_keypo_provider(&parsed);
    let default_exec = config::get_default_exec(&parsed);

    if has_provider && default_exec.as_deref() == Some("keypo") {
        eprintln!("keypo provider already configured in OpenClaw.");
        return Ok(());
    }

    // Build updated config via serde_json (for now; Phase 2 adds JSONC-preserving patcher)
    let mut config_val = parsed;

    if !has_provider {
        // Resolve binary path for the provider block
        let binary_path = std::env::current_exe()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|_| "keypo-openclaw".to_string());
        let parent_dir = std::path::Path::new(&binary_path)
            .parent()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "/usr/local/bin".to_string());

        let provider_block = serde_json::json!({
            "source": "exec",
            "command": binary_path,
            "allowSymlinkCommand": true,
            "trustedDirs": [parent_dir],
            "args": ["resolve"],
            "passEnv": ["HOME", "PATH"],
            "jsonOnly": true
        });

        config::set_path(
            &mut config_val,
            "secrets.providers.keypo",
            provider_block,
        );
    }

    match default_exec.as_deref() {
        None => {
            config::set_path(
                &mut config_val,
                "secrets.defaults.exec",
                serde_json::Value::String("keypo".to_string()),
            );
        }
        Some("keypo") => {}
        Some(other) => {
            eprintln!(
                "Note: secrets.defaults.exec is already set to '{other}'. \
                 The keypo provider was added but is not the default. \
                 You can change this manually or use provider: 'keypo' in each SecretRef."
            );
        }
    }

    // Write updated config
    let output = serde_json::to_string_pretty(&config_val)?;
    config::atomic_write(&config_path, &output)?;

    eprintln!("keypo provider registered in OpenClaw config.");
    eprintln!("After adding secrets, run: keypo-openclaw backup");
    Ok(())
}
