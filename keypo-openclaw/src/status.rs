use crate::config;
use crate::error::Result;
use crate::signer::VaultSigner;

pub fn run(signer: &VaultSigner) -> Result<()> {
    // keypo-signer availability
    if signer.is_available() {
        match signer.version() {
            Ok(v) => println!("keypo-signer: {v}"),
            Err(_) => println!("keypo-signer: installed (version unknown)"),
        }
    } else {
        println!("keypo-signer: NOT INSTALLED");
        println!("  Install with: brew install keypo-us/tap/keypo-signer");
    }

    // Vault status
    let vault_initialized = signer.is_vault_initialized();
    if vault_initialized {
        println!("Vault: initialized");
    } else {
        println!("Vault: NOT INITIALIZED");
    }

    // Vault entries
    let vault_entries = if vault_initialized {
        signer.vault_list().unwrap_or_default()
    } else {
        vec![]
    };

    if !vault_entries.is_empty() {
        let open = vault_entries.iter().filter(|e| e.vault == "open").count();
        let passcode = vault_entries.iter().filter(|e| e.vault == "passcode").count();
        let biometric = vault_entries.iter().filter(|e| e.vault == "biometric").count();
        println!(
            "Vault secrets: {} ({} open, {} passcode, {} biometric)",
            vault_entries.len(),
            open,
            passcode,
            biometric
        );
    } else if vault_initialized {
        println!("Vault secrets: 0");
    }

    // OpenClaw config
    let config_path = config::openclaw_config_path();
    if config_path.exists() {
        match config::read_jsonc(&config_path) {
            Ok(parsed) => {
                if config::has_keypo_provider(&parsed) {
                    println!("OpenClaw provider: configured");
                } else {
                    println!("OpenClaw provider: NOT CONFIGURED");
                    println!("  Run: keypo-openclaw init");
                }

                // Count SecretRefs
                let mut ref_names: Vec<String> = Vec::new();
                count_refs(&parsed, &mut ref_names);
                println!("SecretRefs: {}", ref_names.len());

                // Check for mismatches
                let vault_names: std::collections::HashSet<&str> =
                    vault_entries.iter().map(|e| e.name.as_str()).collect();
                let ref_name_set: std::collections::HashSet<&str> =
                    ref_names.iter().map(|s| s.as_str()).collect();

                let orphan_refs: Vec<&&str> = ref_name_set
                    .iter()
                    .filter(|n| !vault_names.contains(**n))
                    .collect();
                let orphan_vault: Vec<&&str> = vault_names
                    .iter()
                    .filter(|n| !ref_name_set.contains(**n))
                    .collect();

                if !orphan_refs.is_empty() {
                    println!("Mismatches:");
                    for name in &orphan_refs {
                        println!(
                            "  - SecretRef '{}' has no vault secret. Run: keypo-openclaw add",
                            name
                        );
                    }
                }
                if !orphan_vault.is_empty() {
                    for name in &orphan_vault {
                        println!(
                            "  - Vault secret '{}' has no SecretRef (may be unused or in auth-profiles)",
                            name
                        );
                    }
                }
            }
            Err(e) => println!("OpenClaw config: ERROR ({e})"),
        }
    } else {
        println!("OpenClaw config: NOT FOUND");
    }

    // Backup status
    let backup_path = config::icloud_backup_path();
    if backup_path.exists() {
        println!("Backup: present in iCloud Drive");
    } else {
        println!("Backup: no backup");
    }

    Ok(())
}

/// Recursively find all keypo SecretRef IDs in a config value.
fn count_refs(value: &serde_json::Value, names: &mut Vec<String>) {
    if let Some(id) = config::secret_ref_id(value) {
        names.push(id.to_string());
        return;
    }
    if let Some(obj) = value.as_object() {
        for val in obj.values() {
            count_refs(val, names);
        }
    }
}
