use crate::error::{Error, Result};
use crate::signer::VaultSigner;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Read;

#[derive(Deserialize)]
struct ResolveRequest {
    #[serde(rename = "protocolVersion")]
    protocol_version: u64,
    #[allow(dead_code)]
    provider: Option<String>,
    ids: Vec<String>,
}

#[derive(Serialize)]
struct ResolveResponse {
    #[serde(rename = "protocolVersion")]
    protocol_version: u64,
    values: HashMap<String, String>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    errors: HashMap<String, ResolveError>,
}

#[derive(Serialize)]
struct ResolveError {
    message: String,
}

pub fn run(signer: &VaultSigner) -> Result<()> {
    // Verify keypo-signer is available
    if !signer.is_available() {
        eprintln!("keypo-signer not found.");
        std::process::exit(1);
    }

    // Verify vault is initialized
    if !signer.is_vault_initialized() {
        eprintln!("vault not initialized. Run: keypo-openclaw init");
        std::process::exit(1);
    }

    // Read request from stdin
    let mut input = String::new();
    std::io::stdin()
        .read_to_string(&mut input)
        .map_err(|e| Error::Protocol(format!("failed to read stdin: {e}")))?;

    let request: ResolveRequest = serde_json::from_str(&input).map_err(|_| {
        eprintln!("invalid request: expected JSON on stdin");
        Error::Protocol("invalid request: expected JSON on stdin".into())
    })?;

    // Validate protocol version
    if request.protocol_version != 1 {
        eprintln!("unsupported protocol version: {}", request.protocol_version);
        std::process::exit(1);
    }

    // Deduplicate IDs while preserving order
    let mut seen = std::collections::HashSet::new();
    let unique_ids: Vec<&str> = request
        .ids
        .iter()
        .filter(|id| seen.insert(id.as_str()))
        .map(|id| id.as_str())
        .collect();

    // Resolve each ID
    let mut values = HashMap::new();
    let mut errors = HashMap::new();

    for id in unique_ids {
        match signer.vault_get_raw(id) {
            Ok(value) => {
                values.insert(id.to_string(), value);
            }
            Err(e) => {
                errors.insert(
                    id.to_string(),
                    ResolveError {
                        message: e.to_string(),
                    },
                );
            }
        }
    }

    // Write response to stdout
    let response = ResolveResponse {
        protocol_version: 1,
        values,
        errors,
    };

    serde_json::to_writer(std::io::stdout(), &response)?;
    Ok(())
}
