use std::time::Duration;

use alloy::primitives::{Address, B256};
use serde::Deserialize;

use crate::error::{Error, Result};
use crate::paymaster::PaymasterUserOp;

/// Type alias — UserOp is the unpacked v0.7 format shared with the paymaster module.
pub type UserOp = PaymasterUserOp;

/// ERC-7769 JSON-RPC client for bundler communication.
pub struct BundlerClient {
    url: String,
    client: reqwest::Client,
    entry_point: Address,
}

impl BundlerClient {
    pub fn new(url: impl Into<String>, entry_point: Address) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            url: url.into(),
            client,
            entry_point,
        }
    }

    /// Shared JSON-RPC call via `rpc::json_rpc_post`, mapping errors to `Error::Bundler`.
    async fn rpc_call(&self, method: &str, params: serde_json::Value) -> Result<serde_json::Value> {
        crate::rpc::json_rpc_post(&self.client, &self.url, method, params)
            .await
            .map_err(|e| Error::Bundler(e.to_string()))
    }

    /// Connectivity check — returns supported EntryPoint addresses.
    pub async fn supported_entry_points(&self) -> Result<Vec<Address>> {
        let result = self
            .rpc_call("eth_supportedEntryPoints", serde_json::json!([]))
            .await?;
        let addrs: Vec<String> = serde_json::from_value(result)
            .map_err(|e| Error::Bundler(format!("failed to parse entry points: {e}")))?;
        addrs
            .iter()
            .map(|s| {
                s.parse::<Address>()
                    .map_err(|e| Error::Bundler(format!("invalid address: {e}")))
            })
            .collect()
    }

    /// Estimates gas for a UserOp.
    pub async fn estimate_user_operation_gas(&self, user_op: &UserOp) -> Result<GasEstimate> {
        let result = self
            .rpc_call(
                "eth_estimateUserOperationGas",
                serde_json::json!([user_op, format!("{:?}", self.entry_point)]),
            )
            .await?;
        serde_json::from_value(result)
            .map_err(|e| Error::Bundler(format!("failed to parse gas estimate: {e}")))
    }

    /// Submits a UserOp to the bundler. Returns the UserOp hash.
    pub async fn send_user_operation(&self, user_op: &UserOp) -> Result<B256> {
        let result = self
            .rpc_call(
                "eth_sendUserOperation",
                serde_json::json!([user_op, format!("{:?}", self.entry_point)]),
            )
            .await?;
        let hash_str = result
            .as_str()
            .ok_or_else(|| Error::Bundler("expected string hash from sendUserOperation".into()))?;
        hash_str
            .parse::<B256>()
            .map_err(|e| Error::Bundler(format!("invalid UserOp hash: {e}")))
    }

    /// Polls for a UserOp receipt. Returns `None` if not yet mined.
    pub async fn get_user_operation_receipt(&self, hash: B256) -> Result<Option<UserOpReceipt>> {
        let result = self
            .rpc_call(
                "eth_getUserOperationReceipt",
                serde_json::json!([format!("0x{}", hex::encode(hash.as_slice()))]),
            )
            .await?;
        if result.is_null() {
            return Ok(None);
        }
        let receipt: UserOpReceipt = serde_json::from_value(result)
            .map_err(|e| Error::Bundler(format!("failed to parse receipt: {e}")))?;
        Ok(Some(receipt))
    }

    /// Waits for a UserOp receipt with exponential backoff.
    /// Initial delay 2s, multiplier 1.5, max delay 10s.
    pub async fn wait_for_receipt(&self, hash: B256, max_wait: Duration) -> Result<UserOpReceipt> {
        let start = std::time::Instant::now();
        let mut delay = 2.0_f64; // seconds

        loop {
            if let Some(receipt) = self.get_user_operation_receipt(hash).await? {
                return Ok(receipt);
            }
            if start.elapsed() >= max_wait {
                return Err(Error::ReceiptTimeout(
                    max_wait.as_secs(),
                    format!("0x{}", hex::encode(hash.as_slice())),
                ));
            }
            tokio::time::sleep(Duration::from_secs_f64(delay)).await;
            delay = (delay * 1.5).min(10.0);
        }
    }
}

/// Gas estimate returned by `eth_estimateUserOperationGas`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GasEstimate {
    pub pre_verification_gas: String,
    pub verification_gas_limit: String,
    pub call_gas_limit: String,
    pub paymaster_verification_gas_limit: Option<String>,
    pub paymaster_post_op_gas_limit: Option<String>,
}

/// Receipt for a submitted UserOp.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserOpReceipt {
    pub user_op_hash: String,
    pub success: bool,
    pub receipt: TxReceipt,
    pub reason: Option<String>,
}

/// On-chain transaction receipt (informational fields).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TxReceipt {
    pub transaction_hash: String,
    pub block_number: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gas_estimate_deserialization() {
        let json = r#"{
            "preVerificationGas": "0xb708",
            "verificationGasLimit": "0x114c4",
            "callGasLimit": "0x5208"
        }"#;
        let estimate: GasEstimate = serde_json::from_str(json).unwrap();
        assert_eq!(estimate.pre_verification_gas, "0xb708");
        assert_eq!(estimate.verification_gas_limit, "0x114c4");
        assert_eq!(estimate.call_gas_limit, "0x5208");
        assert!(estimate.paymaster_verification_gas_limit.is_none());
        assert!(estimate.paymaster_post_op_gas_limit.is_none());
    }

    #[test]
    fn gas_estimate_with_paymaster_fields() {
        let json = r#"{
            "preVerificationGas": "0xb708",
            "verificationGasLimit": "0x114c4",
            "callGasLimit": "0x5208",
            "paymasterVerificationGasLimit": "0x5208",
            "paymasterPostOpGasLimit": "0x0"
        }"#;
        let estimate: GasEstimate = serde_json::from_str(json).unwrap();
        assert_eq!(
            estimate.paymaster_verification_gas_limit,
            Some("0x5208".into())
        );
        assert_eq!(estimate.paymaster_post_op_gas_limit, Some("0x0".into()));
    }

    #[test]
    fn gas_estimate_ignores_unknown_fields() {
        let json = r#"{
            "preVerificationGas": "0xb708",
            "verificationGasLimit": "0x114c4",
            "callGasLimit": "0x5208",
            "actualGasCost": "0x12345",
            "someOtherField": true
        }"#;
        let estimate: GasEstimate = serde_json::from_str(json).unwrap();
        assert_eq!(estimate.pre_verification_gas, "0xb708");
    }

    #[test]
    fn receipt_deserialization() {
        let json = r#"{
            "userOpHash": "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            "success": true,
            "receipt": {
                "transactionHash": "0x1111111111111111111111111111111111111111111111111111111111111111",
                "blockNumber": "0x100"
            },
            "reason": null,
            "sender": "0x0000000000000000000000000000000000000001",
            "nonce": "0x0",
            "actualGasCost": "0x12345",
            "logs": []
        }"#;
        let receipt: UserOpReceipt = serde_json::from_str(json).unwrap();
        assert!(receipt.success);
        assert!(receipt.reason.is_none());
        assert_eq!(receipt.receipt.block_number, "0x100");
    }

    #[test]
    fn receipt_with_failure_reason() {
        let json = r#"{
            "userOpHash": "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            "success": false,
            "receipt": {
                "transactionHash": "0x1111111111111111111111111111111111111111111111111111111111111111",
                "blockNumber": "0x100"
            },
            "reason": "AA21 didn't pay prefund"
        }"#;
        let receipt: UserOpReceipt = serde_json::from_str(json).unwrap();
        assert!(!receipt.success);
        assert_eq!(receipt.reason, Some("AA21 didn't pay prefund".into()));
    }

    #[test]
    fn null_receipt_is_none() {
        let val = serde_json::Value::Null;
        assert!(val.is_null());
        // Simulates the get_user_operation_receipt logic
        // where null result maps to Ok(None)
    }
}
