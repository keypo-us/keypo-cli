use std::time::Duration;

use alloy::primitives::{Address, B256};
use serde_json::Value;

use crate::error::{Error, Result};

/// Sends a JSON-RPC POST request and returns the result field.
pub async fn json_rpc_post(
    client: &reqwest::Client,
    url: &str,
    method: &str,
    params: Value,
) -> Result<Value> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1,
    });

    let resp = client
        .post(url)
        .json(&body)
        .send()
        .await
        .map_err(|e| Error::Rpc(format!("request failed: {e}")))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| Error::Rpc(format!("failed to read response: {e}")))?;

    if !status.is_success() {
        return Err(Error::Rpc(format!("HTTP {status}: {text}")));
    }

    let json: Value =
        serde_json::from_str(&text).map_err(|e| Error::Rpc(format!("invalid JSON: {e}")))?;

    if let Some(error) = json.get("error") {
        return Err(Error::Rpc(format!("RPC error: {error}")));
    }

    json.get("result")
        .cloned()
        .ok_or_else(|| Error::Rpc("missing result field".into()))
}

/// Fetches the transaction count (nonce) for an address.
pub async fn get_nonce(client: &reqwest::Client, rpc_url: &str, address: Address) -> Result<u64> {
    let result = json_rpc_post(
        client,
        rpc_url,
        "eth_getTransactionCount",
        serde_json::json!([format!("{address}"), "latest"]),
    )
    .await?;

    parse_hex_u64(&result)
}

/// Fetches current gas price.
pub async fn get_gas_price(client: &reqwest::Client, rpc_url: &str) -> Result<u128> {
    let result = json_rpc_post(
        client,
        rpc_url,
        "eth_gasPrice",
        serde_json::json!([]),
    )
    .await?;

    parse_hex_u128(&result)
}

/// Sends a raw signed transaction.
pub async fn send_raw_transaction(
    client: &reqwest::Client,
    rpc_url: &str,
    raw: &[u8],
) -> Result<B256> {
    let hex = format!("0x{}", hex::encode(raw));
    let result = json_rpc_post(
        client,
        rpc_url,
        "eth_sendRawTransaction",
        serde_json::json!([hex]),
    )
    .await?;

    let hash_str = result
        .as_str()
        .ok_or_else(|| Error::Rpc("expected tx hash string".into()))?;
    hash_str
        .parse::<B256>()
        .map_err(|e| Error::Rpc(format!("invalid tx hash: {e}")))
}

/// Polls for a transaction receipt until confirmed or timeout.
pub async fn wait_for_receipt(
    client: &reqwest::Client,
    rpc_url: &str,
    tx_hash: B256,
    timeout: Duration,
) -> Result<TransactionReceipt> {
    let start = std::time::Instant::now();
    let poll_interval = Duration::from_secs(2);

    loop {
        if start.elapsed() > timeout {
            return Err(Error::TransactionFailed(format!(
                "receipt timeout after {}s for tx {tx_hash}",
                timeout.as_secs()
            )));
        }

        let result = json_rpc_post(
            client,
            rpc_url,
            "eth_getTransactionReceipt",
            serde_json::json!([format!("{tx_hash}")]),
        )
        .await?;

        if !result.is_null() {
            return parse_receipt(&result);
        }

        tokio::time::sleep(poll_interval).await;
    }
}

/// Funds a testnet address via the `tempo_fundAddress` RPC method.
pub async fn fund_testnet_address(
    client: &reqwest::Client,
    rpc_url: &str,
    address: Address,
) -> Result<()> {
    let _result = json_rpc_post(
        client,
        rpc_url,
        "tempo_fundAddress",
        serde_json::json!([format!("{address}")]),
    )
    .await?;

    Ok(())
}

/// Tries to get a revert reason by re-simulating a failed transaction's calls.
/// Returns a human-readable error string, or None if it can't determine the reason.
pub async fn get_revert_reason(
    client: &reqwest::Client,
    rpc_url: &str,
    from: Address,
    to: Address,
    data: &[u8],
) -> Option<String> {
    let result = json_rpc_post(
        client,
        rpc_url,
        "eth_call",
        serde_json::json!([
            {
                "from": format!("{from}"),
                "to": format!("{to}"),
                "data": format!("0x{}", hex::encode(data)),
            },
            "latest"
        ]),
    )
    .await;

    match result {
        Err(Error::Rpc(msg)) => {
            // Parse the RPC error for a revert reason
            // Common format: {"code": 3, "message": "execution reverted: SpendingLimitExceeded", "data": "0x..."}
            if msg.contains("SpendingLimitExceeded") {
                return Some("spending limit exceeded for this access key".to_string());
            }
            if msg.contains("InsufficientBalance") || msg.contains("insufficient") {
                return Some("insufficient token balance".to_string());
            }
            if msg.contains("UnauthorizedCaller") {
                return Some("unauthorized: only the root key can perform this action".to_string());
            }
            // Extract the message from the RPC error JSON
            if let Some(start) = msg.find("\"message\":\"") {
                let rest = &msg[start + 11..];
                if let Some(end) = rest.find('"') {
                    return Some(rest[..end].to_string());
                }
            }
            // Return raw error if we can't parse it
            Some(msg)
        }
        _ => None,
    }
}

/// Makes an `eth_call` to a contract.
pub async fn eth_call(
    client: &reqwest::Client,
    rpc_url: &str,
    to: Address,
    data: &[u8],
) -> Result<Vec<u8>> {
    let result = json_rpc_post(
        client,
        rpc_url,
        "eth_call",
        serde_json::json!([
            {
                "to": format!("{to}"),
                "data": format!("0x{}", hex::encode(data)),
            },
            "latest"
        ]),
    )
    .await?;

    let hex_str = result
        .as_str()
        .ok_or_else(|| Error::Rpc("expected hex string from eth_call".into()))?;
    let stripped = hex_str.strip_prefix("0x").unwrap_or(hex_str);
    hex::decode(stripped).map_err(|e| Error::Rpc(format!("invalid hex in eth_call result: {e}")))
}

// ---------------------------------------------------------------------------
// Receipt type
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct TransactionReceipt {
    pub tx_hash: B256,
    pub block_number: u64,
    pub status: bool,
    pub gas_used: u64,
    pub revert_reason: Option<String>,
}

fn parse_receipt(value: &Value) -> Result<TransactionReceipt> {
    let tx_hash = value
        .get("transactionHash")
        .and_then(|v| v.as_str())
        .ok_or_else(|| Error::Rpc("missing transactionHash in receipt".into()))?
        .parse::<B256>()
        .map_err(|e| Error::Rpc(format!("invalid transactionHash: {e}")))?;

    let block_number = value
        .get("blockNumber")
        .and_then(|v| v.as_str())
        .map(parse_hex_u64_str)
        .transpose()?
        .unwrap_or(0);

    let status = value
        .get("status")
        .and_then(|v| v.as_str())
        .map(|s| s == "0x1")
        .unwrap_or(false);

    let gas_used = value
        .get("gasUsed")
        .and_then(|v| v.as_str())
        .map(parse_hex_u64_str)
        .transpose()?
        .unwrap_or(0);

    // Try to extract revert reason from receipt
    let revert_reason = if !status {
        extract_revert_reason(value)
    } else {
        None
    };

    Ok(TransactionReceipt {
        tx_hash,
        block_number,
        status,
        gas_used,
        revert_reason,
    })
}

/// Tries to extract a human-readable revert reason from a receipt.
fn extract_revert_reason(value: &Value) -> Option<String> {
    // Check for revertReason field (some nodes include it)
    if let Some(reason) = value.get("revertReason").and_then(|v| v.as_str()) {
        return Some(reason.to_string());
    }

    // Check for statusReason field
    if let Some(reason) = value.get("statusReason").and_then(|v| v.as_str()) {
        return Some(reason.to_string());
    }

    // Try to decode revert data from logs or output
    // Common Solidity revert: 0x08c379a0 + ABI-encoded string
    if let Some(output) = value.get("output").and_then(|v| v.as_str()) {
        if let Some(msg) = decode_revert_string(output) {
            return Some(msg);
        }
    }

    None
}

/// Decodes a Solidity `Error(string)` revert from hex output.
fn decode_revert_string(hex_output: &str) -> Option<String> {
    let stripped = hex_output.strip_prefix("0x").unwrap_or(hex_output);
    let bytes = hex::decode(stripped).ok()?;

    // Error(string) selector = 0x08c379a0
    if bytes.len() < 68 || bytes[0..4] != [0x08, 0xc3, 0x79, 0xa0] {
        return None;
    }

    // ABI decode: offset at bytes 4..36, length at offset, string data follows
    let offset = u64::from_be_bytes(bytes[28..36].try_into().ok()?) as usize;
    let start = 4 + offset;
    if start + 32 > bytes.len() {
        return None;
    }
    let len = u64::from_be_bytes(bytes[start + 24..start + 32].try_into().ok()?) as usize;
    let str_start = start + 32;
    if str_start + len > bytes.len() {
        return None;
    }
    String::from_utf8(bytes[str_start..str_start + len].to_vec()).ok()
}

// ---------------------------------------------------------------------------
// Hex parsing helpers
// ---------------------------------------------------------------------------

fn parse_hex_u64(value: &Value) -> Result<u64> {
    let s = value
        .as_str()
        .ok_or_else(|| Error::Rpc("expected hex string".into()))?;
    parse_hex_u64_str(s)
}

fn parse_hex_u64_str(s: &str) -> Result<u64> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    u64::from_str_radix(stripped, 16).map_err(|e| Error::Rpc(format!("invalid hex u64 '{s}': {e}")))
}

fn parse_hex_u128(value: &Value) -> Result<u128> {
    let s = value
        .as_str()
        .ok_or_else(|| Error::Rpc("expected hex string".into()))?;
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    u128::from_str_radix(stripped, 16)
        .map_err(|e| Error::Rpc(format!("invalid hex u128 '{s}': {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_hex_u64_valid() {
        let val = serde_json::json!("0xa5bf");
        assert_eq!(parse_hex_u64(&val).unwrap(), 42431);
    }

    #[test]
    fn parse_hex_u128_valid() {
        let val = serde_json::json!("0x4a8270a40");
        assert_eq!(parse_hex_u128(&val).unwrap(), 0x4a8270a40);
    }

    #[test]
    fn parse_receipt_success() {
        let json = serde_json::json!({
            "transactionHash": "0x0000000000000000000000000000000000000000000000000000000000000001",
            "blockNumber": "0x10",
            "status": "0x1",
            "gasUsed": "0x5208"
        });
        let receipt = parse_receipt(&json).unwrap();
        assert!(receipt.status);
        assert_eq!(receipt.block_number, 16);
        assert_eq!(receipt.gas_used, 21000);
    }

    #[test]
    fn parse_receipt_failure() {
        let json = serde_json::json!({
            "transactionHash": "0x0000000000000000000000000000000000000000000000000000000000000002",
            "blockNumber": "0x20",
            "status": "0x0",
            "gasUsed": "0x7148"
        });
        let receipt = parse_receipt(&json).unwrap();
        assert!(!receipt.status);
    }
}
