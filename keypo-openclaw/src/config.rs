use crate::error::Result;
use std::path::PathBuf;

/// Path to the OpenClaw config file.
pub fn openclaw_config_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(".openclaw")
        .join("openclaw.json")
}

/// Path to an agent's auth-profiles.json.
pub fn auth_profiles_path(agent: &str) -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(".openclaw")
        .join("agents")
        .join(agent)
        .join("agent")
        .join("auth-profiles.json")
}

/// Path to the iCloud Drive vault backup.
pub fn icloud_backup_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join("Library")
        .join("Mobile Documents")
        .join("com~apple~CloudDocs")
        .join("Keypo")
        .join("vault-backup.json")
}

/// Read a JSONC file, strip comments, parse to serde_json::Value.
pub fn read_jsonc(path: &std::path::Path) -> Result<serde_json::Value> {
    let raw = std::fs::read_to_string(path)?;
    parse_jsonc(&raw)
}

/// Parse a JSONC string (strips comments, then parses as JSON).
pub fn parse_jsonc(raw: &str) -> Result<serde_json::Value> {
    use json_comments::StripComments;
    use std::io::Read;

    let mut stripped = String::new();
    StripComments::new(raw.as_bytes())
        .read_to_string(&mut stripped)
        .map_err(|e| crate::error::Error::ConfigParse(e.to_string()))?;
    serde_json::from_str(&stripped).map_err(|e| crate::error::Error::ConfigParse(e.to_string()))
}

/// Read the raw file content (for round-trip writes that preserve comments).
pub fn read_raw(path: &std::path::Path) -> Result<String> {
    Ok(std::fs::read_to_string(path)?)
}

/// Check if the keypo provider block exists in the config.
pub fn has_keypo_provider(config: &serde_json::Value) -> bool {
    config
        .get("secrets")
        .and_then(|s| s.get("providers"))
        .and_then(|p| p.get("keypo"))
        .is_some()
}

/// Get the current default exec provider name.
pub fn get_default_exec(config: &serde_json::Value) -> Option<String> {
    config
        .get("secrets")
        .and_then(|s| s.get("defaults"))
        .and_then(|d| d.get("exec"))
        .and_then(|e| e.as_str())
        .map(String::from)
}

/// Build a SecretRef JSON value.
pub fn secret_ref(vault_name: &str) -> serde_json::Value {
    serde_json::json!({
        "source": "exec",
        "provider": "keypo",
        "id": vault_name
    })
}

/// Check if a JSON value is a keypo SecretRef.
pub fn is_keypo_secret_ref(value: &serde_json::Value) -> bool {
    value.get("source").and_then(|v| v.as_str()) == Some("exec")
        && value.get("provider").and_then(|v| v.as_str()) == Some("keypo")
        && value.get("id").and_then(|v| v.as_str()).is_some()
}

/// Get the vault name from a keypo SecretRef, if it is one.
pub fn secret_ref_id(value: &serde_json::Value) -> Option<&str> {
    if is_keypo_secret_ref(value) {
        value.get("id").and_then(|v| v.as_str())
    } else {
        None
    }
}

/// Get a value at a dot-delimited path in a JSON object.
pub fn get_path<'a>(config: &'a serde_json::Value, path: &str) -> Option<&'a serde_json::Value> {
    let mut current = config;
    for key in path.split('.') {
        current = current.get(key)?;
    }
    Some(current)
}

/// Set a value at a dot-delimited path in a JSON object, creating intermediates.
pub fn set_path(config: &mut serde_json::Value, path: &str, value: serde_json::Value) {
    let keys: Vec<&str> = path.split('.').collect();
    let mut current = config;
    for &key in &keys[..keys.len() - 1] {
        if !current.get(key).is_some_and(|v| v.is_object()) {
            current[key] = serde_json::json!({});
        }
        current = current.get_mut(key).unwrap();
    }
    if let Some(last) = keys.last() {
        current[*last] = value;
    }
}

/// Scan a config for all dot-paths that contain a keypo SecretRef with the given vault name.
pub fn find_secret_refs(config: &serde_json::Value, vault_name: &str) -> Vec<String> {
    let mut results = Vec::new();
    find_refs_recursive(config, vault_name, String::new(), &mut results);
    results
}

fn find_refs_recursive(
    value: &serde_json::Value,
    vault_name: &str,
    prefix: String,
    results: &mut Vec<String>,
) {
    if let Some(id) = secret_ref_id(value) {
        if id == vault_name {
            results.push(prefix);
            return;
        }
    }
    if let Some(obj) = value.as_object() {
        for (key, val) in obj {
            let path = if prefix.is_empty() {
                key.clone()
            } else {
                format!("{prefix}.{key}")
            };
            find_refs_recursive(val, vault_name, path, results);
        }
    }
}

/// Scan auth-profiles for keyRef/tokenRef matching a vault name.
/// Returns a list of (profile_id, ref_type) where ref_type is "keyRef" or "tokenRef".
pub fn find_auth_refs(
    profiles: &serde_json::Value,
    vault_name: &str,
) -> Vec<(String, String)> {
    let mut results = Vec::new();
    if let Some(obj) = profiles.get("profiles").and_then(|p| p.as_object()) {
        for (profile_id, profile) in obj {
            for ref_type in ["keyRef", "tokenRef"] {
                if let Some(ref_val) = profile.get(ref_type) {
                    if secret_ref_id(ref_val) == Some(vault_name) {
                        results.push((profile_id.clone(), ref_type.to_string()));
                    }
                }
            }
        }
    }
    results
}

/// Write content to a file atomically (write to temp, rename).
pub fn atomic_write(path: &std::path::Path, content: &str) -> Result<()> {
    use std::io::Write;

    let dir = path
        .parent()
        .ok_or_else(|| crate::error::Error::ConfigWrite("no parent directory".into()))?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir)
        .map_err(|e| crate::error::Error::ConfigWrite(e.to_string()))?;
    tmp.write_all(content.as_bytes())
        .map_err(|e| crate::error::Error::ConfigWrite(e.to_string()))?;
    tmp.persist(path)
        .map_err(|e| crate::error::Error::ConfigWrite(e.to_string()))?;
    Ok(())
}
