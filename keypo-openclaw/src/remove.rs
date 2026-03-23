use crate::config;
use crate::error::{Error, Result};
use crate::signer::VaultSigner;

pub fn run(
    signer: &VaultSigner,
    names: &[String],
    keep_config: bool,
    keep_vault: bool,
) -> Result<()> {
    if keep_config && keep_vault {
        return Err(Error::Other(
            "Cannot use --keep-config and --keep-vault together.".into(),
        ));
    }

    if !signer.is_vault_initialized() {
        return Err(Error::VaultNotInitialized);
    }

    let config_path = config::openclaw_config_path();
    let config_exists = config_path.exists();

    // Scan for references and vault entries
    let parsed = if config_exists {
        Some(config::read_jsonc(&config_path)?)
    } else {
        None
    };

    // Scan all agents' auth-profiles.json
    let agents_dir = dirs::home_dir()
        .unwrap_or_default()
        .join(".openclaw")
        .join("agents");

    struct RemoveInfo {
        name: String,
        config_refs: Vec<String>,
        auth_refs: Vec<(String, String, String)>, // (agent, profile_id, ref_type)
        in_vault: bool,
    }

    let vault_entries = signer.vault_list().unwrap_or_default();
    let mut infos: Vec<RemoveInfo> = Vec::new();

    for name in names {
        let config_refs = if let Some(ref p) = parsed {
            config::find_secret_refs(p, name)
        } else {
            vec![]
        };

        let mut auth_refs = Vec::new();
        if let Ok(entries) = std::fs::read_dir(&agents_dir) {
            for entry in entries.flatten() {
                let agent_id = entry.file_name().to_string_lossy().to_string();
                let ap_path = config::auth_profiles_path(&agent_id);
                if ap_path.exists() {
                    if let Ok(ap) = config::read_jsonc(&ap_path) {
                        for (profile_id, ref_type) in config::find_auth_refs(&ap, name) {
                            auth_refs.push((agent_id.clone(), profile_id, ref_type));
                        }
                    }
                }
            }
        }

        let in_vault = vault_entries.iter().any(|e| e.name == *name);

        if !in_vault && config_refs.is_empty() && auth_refs.is_empty() {
            eprintln!("Warning: secret '{name}' not found in vault or config. Nothing to remove.");
            continue;
        }

        infos.push(RemoveInfo {
            name: name.clone(),
            config_refs,
            auth_refs,
            in_vault,
        });
    }

    if infos.is_empty() {
        return Ok(());
    }

    // Present findings
    for info in &infos {
        eprintln!("Removing '{}':", info.name);
        if info.in_vault {
            eprintln!("  - vault: present");
        }
        for path in &info.config_refs {
            eprintln!("  - openclaw.json: {path}");
        }
        for (agent, profile_id, ref_type) in &info.auth_refs {
            eprintln!("  - auth-profiles.json (agent={agent}): {profile_id}.{ref_type}");
        }
    }

    // Remove SecretRefs from config files
    if !keep_config {
        // Update openclaw.json
        if config_exists {
            let any_config_refs = infos.iter().any(|i| !i.config_refs.is_empty());
            if any_config_refs {
                let mut config_val = parsed.clone().unwrap();
                for info in &infos {
                    for path in &info.config_refs {
                        remove_path(&mut config_val, path);
                    }
                }
                let output = serde_json::to_string_pretty(&config_val)?;
                config::atomic_write(&config_path, &output)?;
            }
        }

        // Update auth-profiles.json files
        let mut modified_agents: std::collections::HashMap<String, serde_json::Value> =
            std::collections::HashMap::new();

        for info in &infos {
            for (agent, profile_id, ref_type) in &info.auth_refs {
                let ap_path = config::auth_profiles_path(agent);
                let ap_val = modified_agents
                    .entry(agent.clone())
                    .or_insert_with(|| config::read_jsonc(&ap_path).unwrap_or_default());

                if let Some(profile) = ap_val
                    .get_mut("profiles")
                    .and_then(|p| p.get_mut(profile_id.as_str()))
                    .and_then(|p| p.as_object_mut())
                {
                    profile.remove(ref_type);
                }
            }
        }

        for (agent, val) in &modified_agents {
            let ap_path = config::auth_profiles_path(agent);
            let output = serde_json::to_string_pretty(val)?;
            config::atomic_write(&ap_path, &output)?;
        }
    }

    // Delete from vault
    if !keep_vault {
        for info in &infos {
            if info.in_vault {
                if let Err(e) = signer.vault_delete(&info.name) {
                    eprintln!(
                        "Warning: failed to delete '{}' from vault: {e}. \
                         SecretRef was already removed from config.",
                        info.name
                    );
                }
            }
        }
    }

    for info in &infos {
        eprintln!("Removed '{}'.", info.name);
    }
    Ok(())
}

/// Remove a value at a dot-delimited path in a JSON object.
fn remove_path(config: &mut serde_json::Value, path: &str) {
    let keys: Vec<&str> = path.split('.').collect();
    if keys.is_empty() {
        return;
    }

    let mut current = config;
    for &key in &keys[..keys.len() - 1] {
        match current.get_mut(key) {
            Some(next) => current = next,
            None => return,
        }
    }

    if let Some(last) = keys.last() {
        if let Some(obj) = current.as_object_mut() {
            obj.remove(*last);
        }
    }
}
