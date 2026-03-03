use crate::error::{Error, Result};

/// Shared JSON-RPC POST helper used by both `BundlerClient` and `PaymasterClient`.
///
/// Builds a `{"jsonrpc":"2.0","id":1,"method":"...","params":...}` envelope,
/// POSTs via the provided `reqwest::Client`, and extracts `result` or maps the
/// error field to `Error::Other`. Callers wrap into domain-specific errors via
/// `.map_err()`.
pub(crate) async fn json_rpc_post(
    client: &reqwest::Client,
    url: &str,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params,
    });

    let resp = client
        .post(url)
        .json(&body)
        .send()
        .await
        .map_err(|e| Error::Other(format!("RPC HTTP error: {e}")))?;

    let json: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| Error::Other(format!("RPC HTTP error: {e}")))?;

    if let Some(err) = json.get("error") {
        let code = err.get("code").and_then(|c| c.as_i64()).unwrap_or(0);
        let message = err
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("unknown error");
        let data = err.get("data");
        return Err(Error::Other(format_rpc_error(code, message, data)));
    }

    // Return `result` field (including JSON null) — caller handles null.
    Ok(json
        .get("result")
        .cloned()
        .unwrap_or(serde_json::Value::Null))
}

/// Formats an RPC error into a human-readable string.
/// AA-prefixed data (ERC-4337 convention) is displayed prominently.
fn format_rpc_error(code: i64, message: &str, data: Option<&serde_json::Value>) -> String {
    let data_str = data.and_then(|d| {
        // Use .as_str() for string values to avoid JSON quotes
        d.as_str()
            .map(|s| s.to_string())
            .or_else(|| Some(format!("{d}")))
    });

    match data_str {
        Some(ref s) if s.starts_with("AA") => format!("{s} ({message})"),
        Some(s) => format!("RPC error {code}: {message} {s}"),
        None => format!("RPC error {code}: {message}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_rpc_error_aa_prefix() {
        let data = serde_json::json!("AA21 didn't pay prefund");
        let result = format_rpc_error(-32602, "invalid params", Some(&data));
        assert_eq!(result, "AA21 didn't pay prefund (invalid params)");
    }

    #[test]
    fn format_rpc_error_non_aa() {
        let data = serde_json::json!("some details");
        let result = format_rpc_error(-32602, "invalid params", Some(&data));
        assert_eq!(result, "RPC error -32602: invalid params some details");
    }
}
