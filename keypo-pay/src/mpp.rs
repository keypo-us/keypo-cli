//! Machine Payments Protocol (MPP) client — charge flow only.
//!
//! Implements the HTTP 402 challenge-response protocol for Tempo charge payments.
//! Session support is deferred per the implementation plan.

use alloy::primitives::{Address, U256};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;

use crate::config::{AccessKeyEntry, TokenEntry, WalletConfig};
use crate::error::{Error, Result};
use crate::rlp::TempoCall;
use crate::signer::P256Signer;
use crate::transaction;

// ---------------------------------------------------------------------------
// Challenge parsing
// ---------------------------------------------------------------------------

/// Parsed MPP challenge from a 402 WWW-Authenticate header.
#[derive(Debug, Clone)]
pub struct MppChallenge {
    pub id: String,
    pub realm: String,
    pub method: String,
    pub intent: String,
    pub request_b64: String, // raw base64url-encoded request (echoed back)
    pub expires: Option<String>,
    pub recipient: Address,
    pub amount: U256,
    pub token: Address,
    pub chain_id: Option<u64>,
}

/// Parses the WWW-Authenticate header value (after "Payment ").
///
/// Format: `Payment id="...", realm="...", method="...", intent="...", request="..."`
pub fn parse_www_authenticate(header: &str) -> Result<MppChallenge> {
    let header = header.strip_prefix("Payment ").unwrap_or(header);

    let mut params = std::collections::HashMap::new();
    // Parse key="value" pairs (handles commas in values carefully)
    let mut remaining = header.trim();
    while !remaining.is_empty() {
        remaining = remaining.trim_start_matches([',', ' ']);
        if remaining.is_empty() {
            break;
        }
        let eq_pos = remaining
            .find('=')
            .ok_or_else(|| Error::Other("malformed WWW-Authenticate: missing '='".into()))?;
        let key = remaining[..eq_pos].trim();
        remaining = &remaining[eq_pos + 1..];

        let value = if remaining.starts_with('"') {
            remaining = &remaining[1..];
            let end = remaining
                .find('"')
                .ok_or_else(|| Error::Other("malformed WWW-Authenticate: unclosed quote".into()))?;
            let val = &remaining[..end];
            remaining = &remaining[end + 1..];
            val
        } else {
            let end = remaining.find([',', ' ']).unwrap_or(remaining.len());
            let val = &remaining[..end];
            remaining = &remaining[end..];
            val
        };

        params.insert(key.to_string(), value.to_string());
    }

    let id = params
        .get("id")
        .ok_or_else(|| Error::Other("missing 'id' in challenge".into()))?
        .clone();
    let realm = params
        .get("realm")
        .ok_or_else(|| Error::Other("missing 'realm' in challenge".into()))?
        .clone();
    let method = params
        .get("method")
        .ok_or_else(|| Error::Other("missing 'method' in challenge".into()))?
        .clone();
    let intent = params
        .get("intent")
        .ok_or_else(|| Error::Other("missing 'intent' in challenge".into()))?
        .clone();
    let request_b64 = params
        .get("request")
        .ok_or_else(|| Error::Other("missing 'request' in challenge".into()))?
        .clone();
    let expires = params.get("expires").cloned();

    if method != "tempo" {
        return Err(Error::Other(format!(
            "unsupported payment method: '{method}'"
        )));
    }
    if intent != "charge" {
        return Err(Error::Other(format!(
            "unsupported intent: '{intent}' (only 'charge' is supported)"
        )));
    }

    // Decode the request JSON
    let request_bytes = URL_SAFE_NO_PAD
        .decode(&request_b64)
        .map_err(|e| Error::Other(format!("invalid base64url in request: {e}")))?;
    let request_json: serde_json::Value = serde_json::from_slice(&request_bytes)
        .map_err(|e| Error::Other(format!("invalid JSON in request: {e}")))?;

    let amount_str = request_json["amount"]
        .as_str()
        .ok_or_else(|| Error::Other("missing 'amount' in request".into()))?;
    let amount = U256::from_str_radix(amount_str, 10)
        .map_err(|e| Error::Other(format!("invalid amount: {e}")))?;

    let currency = request_json["currency"]
        .as_str()
        .ok_or_else(|| Error::Other("missing 'currency' in request".into()))?;
    let token_addr: Address = currency
        .parse()
        .map_err(|e| Error::Other(format!("invalid currency address: {e}")))?;

    let recipient_str = request_json["recipient"]
        .as_str()
        .ok_or_else(|| Error::Other("missing 'recipient' in request".into()))?;
    let recipient: Address = recipient_str
        .parse()
        .map_err(|e| Error::Other(format!("invalid recipient address: {e}")))?;

    let chain_id = request_json
        .get("methodDetails")
        .and_then(|md| md.get("chainId"))
        .and_then(|v| v.as_u64());

    Ok(MppChallenge {
        id,
        realm,
        method,
        intent,
        request_b64,
        expires,
        recipient,
        amount,
        token: token_addr,
        chain_id,
    })
}

// ---------------------------------------------------------------------------
// Credential construction
// ---------------------------------------------------------------------------

/// Builds the Authorization header value for a charge payment.
///
/// Format: `Payment <base64url(JSON)>`
pub fn build_authorization_header(
    challenge: &MppChallenge,
    payer_address: Address,
    chain_id: u64,
    tx_hash: &str,
) -> String {
    let credential = serde_json::json!({
        "challenge": {
            "id": challenge.id,
            "realm": challenge.realm,
            "method": challenge.method,
            "intent": challenge.intent,
            "request": challenge.request_b64,
        },
        "source": format!("did:pkh:eip155:{chain_id}:{payer_address}"),
        "payload": {
            "type": "hash",
            "hash": tx_hash,
        }
    });

    let json_bytes = serde_json::to_vec(&credential).unwrap();
    let encoded = URL_SAFE_NO_PAD.encode(&json_bytes);
    format!("Payment {encoded}")
}

// ---------------------------------------------------------------------------
// Receipt parsing
// ---------------------------------------------------------------------------

/// Parsed MPP payment receipt.
#[derive(Debug, Clone)]
pub struct MppReceipt {
    pub status: String,
    pub method: String,
    pub timestamp: Option<String>,
    pub reference: Option<String>,
}

/// Parses a Payment-Receipt header value.
pub fn parse_receipt(header: &str) -> Result<MppReceipt> {
    let bytes = URL_SAFE_NO_PAD
        .decode(header.trim())
        .map_err(|e| Error::Other(format!("invalid base64url in receipt: {e}")))?;
    let json: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|e| Error::Other(format!("invalid JSON in receipt: {e}")))?;

    Ok(MppReceipt {
        status: json["status"].as_str().unwrap_or("unknown").to_string(),
        method: json["method"].as_str().unwrap_or("unknown").to_string(),
        timestamp: json["timestamp"].as_str().map(|s| s.to_string()),
        reference: json["reference"].as_str().map(|s| s.to_string()),
    })
}

// ---------------------------------------------------------------------------
// Response type
// ---------------------------------------------------------------------------

/// Result of a paid MPP request.
#[derive(Debug)]
pub struct MppResponse {
    pub status: u16,
    pub body: String,
    pub receipt: Option<MppReceipt>,
    pub tx_hash: Option<String>,
}

// ---------------------------------------------------------------------------
// Charge flow
// ---------------------------------------------------------------------------

/// Executes the MPP charge flow:
/// 1. Make initial request, expect 402
/// 2. Parse challenge from WWW-Authenticate
/// 3. Submit TIP-20 transfer on-chain
/// 4. Retry request with Authorization header
pub async fn pay_charge(
    url: &str,
    rpc_url: &str,
    wallet: &WalletConfig,
    access_key: &AccessKeyEntry,
    signer: &dyn P256Signer,
    _tokens: &[TokenEntry],
) -> Result<MppResponse> {
    let http = reqwest::Client::new();

    // Step 1: Initial request
    tracing::info!("requesting {url}...");
    let resp = http
        .get(url)
        .send()
        .await
        .map_err(|e| Error::Rpc(format!("HTTP request failed: {e}")))?;

    if resp.status().as_u16() != 402 {
        return Ok(MppResponse {
            status: resp.status().as_u16(),
            body: resp.text().await.unwrap_or_default(),
            receipt: None,
            tx_hash: None,
        });
    }

    // Step 2: Parse challenge
    let www_auth = resp
        .headers()
        .get("www-authenticate")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| Error::Other("402 response missing WWW-Authenticate header".into()))?
        .to_string();

    let challenge = parse_www_authenticate(&www_auth)?;
    tracing::info!(
        "challenge: {} {} to {} for {} (token {})",
        challenge.method,
        challenge.intent,
        challenge.recipient,
        challenge.amount,
        challenge.token
    );

    // Step 3: Submit payment on-chain
    let wallet_addr: Address = wallet
        .address
        .parse()
        .map_err(|e| Error::Other(format!("invalid wallet address: {e}")))?;

    let calldata = transaction::encode_tip20_transfer(challenge.recipient, challenge.amount);
    let call = TempoCall {
        to: challenge.token,
        value: U256::ZERO,
        data: calldata,
    };

    let ak_label = access_key
        .key_id
        .split('.')
        .next_back()
        .unwrap_or(&access_key.key_id);

    let bio = format!("Pay {} for {}", challenge.amount, url);
    let tx_result = transaction::send_tempo_tx(
        rpc_url,
        wallet,
        vec![call],
        signer,
        ak_label,
        Some(wallet_addr),
        None,
        Some(&bio),
    )
    .await?;

    let tx_hash_str = format!("{}", tx_result.tx_hash);
    tracing::info!("payment tx: {tx_hash_str}");

    // Step 4: Retry with credential
    let auth_header =
        build_authorization_header(&challenge, wallet_addr, wallet.chain_id, &tx_hash_str);

    let resp = http
        .get(url)
        .header("Authorization", &auth_header)
        .send()
        .await
        .map_err(|e| Error::Rpc(format!("retry request failed: {e}")))?;

    let status = resp.status().as_u16();
    let receipt = resp
        .headers()
        .get("payment-receipt")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| parse_receipt(v).ok());

    let body = resp.text().await.unwrap_or_default();

    Ok(MppResponse {
        status,
        body,
        receipt,
        tx_hash: Some(tx_hash_str),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_request_b64() -> String {
        let request = serde_json::json!({
            "amount": "10000",
            "currency": "0x20c0000000000000000000000000000000000000",
            "recipient": "0x1111111111111111111111111111111111111111"
        });
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&request).unwrap())
    }

    #[test]
    fn parse_www_authenticate_valid() {
        let request_b64 = sample_request_b64();
        let header = format!(
            r#"Payment id="abc123", realm="api.example.com", method="tempo", intent="charge", request="{request_b64}""#
        );
        let challenge = parse_www_authenticate(&header).unwrap();
        assert_eq!(challenge.id, "abc123");
        assert_eq!(challenge.realm, "api.example.com");
        assert_eq!(challenge.method, "tempo");
        assert_eq!(challenge.intent, "charge");
        assert_eq!(challenge.amount, U256::from(10000u64));
        assert_eq!(
            challenge.recipient,
            "0x1111111111111111111111111111111111111111"
                .parse::<Address>()
                .unwrap()
        );
    }

    #[test]
    fn parse_www_authenticate_unsupported_method() {
        let request_b64 = sample_request_b64();
        let header = format!(
            r#"Payment id="abc", realm="x", method="stripe", intent="charge", request="{request_b64}""#
        );
        let err = parse_www_authenticate(&header).unwrap_err();
        assert!(format!("{err}").contains("unsupported payment method"));
    }

    #[test]
    fn parse_www_authenticate_unsupported_intent() {
        let request_b64 = sample_request_b64();
        let header = format!(
            r#"Payment id="abc", realm="x", method="tempo", intent="session", request="{request_b64}""#
        );
        let err = parse_www_authenticate(&header).unwrap_err();
        assert!(format!("{err}").contains("unsupported intent"));
    }

    #[test]
    fn parse_www_authenticate_missing_field() {
        let header = r#"Payment id="abc", realm="x""#;
        assert!(parse_www_authenticate(header).is_err());
    }

    #[test]
    fn build_authorization_header_contains_payment() {
        let request_b64 = sample_request_b64();
        let challenge = parse_www_authenticate(&format!(
            r#"Payment id="abc", realm="x", method="tempo", intent="charge", request="{request_b64}""#
        ))
        .unwrap();

        let header = build_authorization_header(
            &challenge,
            Address::repeat_byte(0xAA),
            42431,
            "0xdeadbeef",
        );

        assert!(header.starts_with("Payment "));
        // Decode and verify structure
        let b64 = header.strip_prefix("Payment ").unwrap();
        let bytes = URL_SAFE_NO_PAD.decode(b64).unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(json["challenge"]["id"], "abc");
        assert_eq!(json["payload"]["type"], "hash");
        assert_eq!(json["payload"]["hash"], "0xdeadbeef");
        assert!(json["source"].as_str().unwrap().contains("42431"));
    }

    #[test]
    fn parse_receipt_valid() {
        let receipt_json = serde_json::json!({
            "status": "success",
            "method": "tempo",
            "timestamp": "2026-03-20T12:00:00Z",
            "reference": "0xabcdef"
        });
        let b64 = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&receipt_json).unwrap());
        let receipt = parse_receipt(&b64).unwrap();
        assert_eq!(receipt.status, "success");
        assert_eq!(receipt.method, "tempo");
        assert_eq!(receipt.reference, Some("0xabcdef".to_string()));
    }
}
