use crate::config;
use crate::error::{Error, Result};
use crate::naming;
use crate::signer::VaultSigner;

/// A parsed add entry from the CLI args.
struct AddEntry {
    name: String,
    value: String,
    path: String,
}

/// Parse trailing args into AddEntry triples: NAME VALUE --path PATH
fn parse_add_args(args: &[String]) -> Result<Vec<AddEntry>> {
    let mut entries = Vec::new();
    let mut i = 0;

    while i < args.len() {
        if i + 1 >= args.len() {
            return Err(Error::Other(format!(
                "expected VALUE after '{}'. Usage: NAME VALUE --path PATH",
                args[i]
            )));
        }

        let name = args[i].clone();
        let value = args[i + 1].clone();
        i += 2;

        // Expect --path next
        if i >= args.len() || args[i] != "--path" {
            return Err(Error::Other(format!(
                "expected --path after value for '{name}'. Usage: NAME VALUE --path PATH"
            )));
        }
        i += 1;

        if i >= args.len() {
            return Err(Error::Other(
                "expected PATH after --path. Usage: NAME VALUE --path PATH".into(),
            ));
        }

        let path = args[i].clone();
        i += 1;

        entries.push(AddEntry { name, value, path });
    }

    if entries.is_empty() {
        return Err(Error::Other(
            "no secrets specified. Usage: NAME VALUE --path PATH".into(),
        ));
    }

    Ok(entries)
}

#[allow(clippy::too_many_arguments)]
pub fn run(
    signer: &VaultSigner,
    args: &[String],
    auth_profile: Option<String>,
    auth_type: Option<String>,
    vault_policy: &str,
    agent: &str,
    update: bool,
) -> Result<()> {
    // Verify vault is initialized
    if !signer.is_vault_initialized() {
        return Err(Error::VaultNotInitialized);
    }

    // Check provider block exists
    let config_path = config::openclaw_config_path();
    if !config_path.exists() {
        return Err(Error::ConfigNotFound(format!(
            "OpenClaw config not found at {}",
            config_path.display()
        )));
    }
    let parsed = config::read_jsonc(&config_path)?;
    if !config::has_keypo_provider(&parsed) {
        return Err(Error::Other(
            "Keypo provider not found in OpenClaw config. Run: keypo-openclaw init".into(),
        ));
    }

    if let Some(ref profile_id) = auth_profile {
        // Auth-profile mode
        let auth_type = auth_type.as_deref().ok_or_else(|| {
            Error::Other("--auth-type (api_key or token) is required when using --auth-profile".into())
        })?;

        if auth_type != "api_key" && auth_type != "token" {
            return Err(Error::Other(format!(
                "invalid --auth-type '{auth_type}'. Must be 'api_key' or 'token'"
            )));
        }

        // Expect exactly NAME VALUE (no --path)
        if args.len() != 2 {
            return Err(Error::Other(
                "with --auth-profile, provide exactly: NAME VALUE".into(),
            ));
        }

        let name = &args[0];
        let value = &args[1];

        if value.is_empty() {
            return Err(Error::Other("Secret value cannot be empty.".into()));
        }

        naming::validate_vault_name(name)?;

        run_add_auth_profile(signer, name, value, profile_id, auth_type, agent, vault_policy, update)
    } else {
        // openclaw.json mode — parse entries
        let entries = parse_add_args(args)?;
        run_add_config(signer, &entries, vault_policy, update)
    }
}

fn run_add_config(
    signer: &VaultSigner,
    entries: &[AddEntry],
    vault_policy: &str,
    update: bool,
) -> Result<()> {
    // Phase 1: Validate all names and values
    for entry in entries {
        naming::validate_vault_name(&entry.name)?;
        if entry.value.is_empty() {
            return Err(Error::Other("Secret value cannot be empty.".into()));
        }
    }

    // Phase 2: Read config, check for conflicts at all paths
    let config_path = config::openclaw_config_path();
    let parsed = config::read_jsonc(&config_path)?;
    let mut skips = vec![false; entries.len()];

    for (i, entry) in entries.iter().enumerate() {
        if let Some(existing) = config::get_path(&parsed, &entry.path) {
            if config::is_keypo_secret_ref(existing) {
                let existing_id = config::secret_ref_id(existing).unwrap_or("");
                if existing_id == entry.name {
                    // Idempotent — same SecretRef already there
                    if !update {
                        skips[i] = true;
                    }
                } else {
                    return Err(Error::Conflict(format!(
                        "{} already has a SecretRef pointing at '{}'. \
                         Remove it first with: keypo-openclaw remove {}",
                        entry.path, existing_id, existing_id
                    )));
                }
            }
            // Existing plaintext value will be replaced — that's fine
        }
    }

    // Phase 3: Store all secrets in vault
    let mut stored: Vec<&str> = Vec::new();
    for (i, entry) in entries.iter().enumerate() {
        if update {
            signer.vault_update(&entry.name, &entry.value)?;
        } else if !skips[i] {
            if let Err(e) = signer.vault_set(&entry.name, &entry.value, vault_policy) {
                // Rollback previously stored secrets
                for name in &stored {
                    let _ = signer.vault_delete(name);
                }
                return Err(e);
            }
            stored.push(&entry.name);
        }
    }

    // Phase 4: Patch config with all SecretRefs
    if !update {
        let mut config_val = parsed;
        let mut any_changes = false;

        for (i, entry) in entries.iter().enumerate() {
            if !skips[i] {
                config::set_path(&mut config_val, &entry.path, config::secret_ref(&entry.name));
                any_changes = true;
            }
        }

        if any_changes {
            let output = serde_json::to_string_pretty(&config_val)?;
            config::atomic_write(&config_path, &output)?;
        }
    }

    for entry in entries {
        eprintln!("Added {} → {}", entry.name, entry.path);
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn run_add_auth_profile(
    signer: &VaultSigner,
    name: &str,
    value: &str,
    profile_id: &str,
    auth_type: &str,
    agent: &str,
    vault_policy: &str,
    update: bool,
) -> Result<()> {
    let profiles_path = config::auth_profiles_path(agent);
    if !profiles_path.exists() {
        return Err(Error::ConfigNotFound(format!(
            "Auth profiles not found at {}",
            profiles_path.display()
        )));
    }

    let parsed = config::read_jsonc(&profiles_path)?;

    // Check profile exists
    let profiles = parsed
        .get("profiles")
        .and_then(|p| p.as_object())
        .ok_or_else(|| Error::ConfigParse("missing 'profiles' in auth-profiles.json".into()))?;

    if !profiles.contains_key(profile_id) {
        return Err(Error::Other(format!(
            "Profile '{profile_id}' not found in auth-profiles.json"
        )));
    }

    // Store secret in vault
    if update {
        signer.vault_update(name, value)?;
    } else {
        signer.vault_set(name, value, vault_policy)?;
    }

    // Update auth-profiles.json
    if !update {
        let mut config_val = parsed;
        let profile = config_val["profiles"][profile_id].as_object_mut().ok_or_else(|| {
            Error::ConfigParse(format!("profile '{profile_id}' is not an object"))
        })?;

        let ref_val = config::secret_ref(name);

        match auth_type {
            "api_key" => {
                profile.insert("key".to_string(), serde_json::Value::String(String::new()));
                profile.insert("keyRef".to_string(), ref_val);
            }
            "token" => {
                profile.insert("token".to_string(), serde_json::Value::String(String::new()));
                profile.insert("tokenRef".to_string(), ref_val);
            }
            _ => unreachable!(),
        }

        let output = serde_json::to_string_pretty(&config_val)?;
        config::atomic_write(&profiles_path, &output)?;
    }

    eprintln!("Added {name} → auth-profile {profile_id} ({auth_type})");
    Ok(())
}
