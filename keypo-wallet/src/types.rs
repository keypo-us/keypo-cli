use alloy::primitives::{Address, Bytes, B256, U256};

fn default_format() -> String {
    "table".to_string()
}
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct P256PublicKey {
    pub qx: B256,
    pub qy: B256,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct P256Signature {
    pub r: B256,
    pub s: B256,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Call {
    pub to: Address,
    pub value: U256,
    pub data: Bytes,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct KeyInfo {
    #[serde(rename = "keyId")]
    pub key_id: String,
    #[serde(rename = "publicKey")]
    pub public_key: String,
    pub policy: String,
    pub status: String,
    #[serde(rename = "signingCount")]
    pub signing_count: u64,
    #[serde(rename = "lastUsedAt")]
    pub last_used_at: Option<String>,
}

impl KeyInfo {
    /// Returns the label portion of the key_id, stripping the `com.keypo.signer.` prefix.
    pub fn label(&self) -> &str {
        self.key_id
            .strip_prefix("com.keypo.signer.")
            .unwrap_or(&self.key_id)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChainDeployment {
    pub chain_id: u64,
    pub implementation: Address,
    pub implementation_name: String,
    pub entry_point: Address,
    pub bundler_url: Option<String>,
    pub paymaster_url: Option<String>,
    pub rpc_url: String,
    pub deployed_at: String,
    #[serde(default)]
    pub tx_hash: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AccountRecord {
    pub address: Address,
    pub key_label: String,
    pub key_policy: String,
    pub public_key: P256PublicKey,
    pub chains: Vec<ChainDeployment>,
    pub created_at: String,
}

/// Entry for wallet-list output.
#[derive(Debug, Clone)]
pub struct WalletListEntry {
    pub label: String,
    pub policy: String,
    pub address: Address,
    pub chains: Vec<String>,
    pub eth_balance: Option<U256>,
}

/// Structured balance query file (spec §5.3).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct BalanceQuery {
    #[serde(default)]
    pub chains: Vec<u64>,
    #[serde(default)]
    pub tokens: Option<TokenFilter>,
    #[serde(default = "default_format")]
    pub format: String,
    #[serde(default)]
    pub sort_by: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TokenFilter {
    #[serde(default)]
    pub include: Vec<String>,
    #[serde(default)]
    pub exclude: Vec<String>,
    #[serde(default)]
    pub min_balance: Option<String>,
}

/// Result of a balance query for a single token on a single chain.
#[derive(Debug, Clone)]
pub struct TokenBalance {
    pub chain_id: u64,
    pub token: String,
    pub symbol: Option<String>,
    pub balance: U256,
    pub decimals: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChainConfig {
    pub chain_id: u64,
    pub rpc_url: String,
    pub bundler_url: Option<String>,
    pub paymaster_url: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn p256_public_key_serde_roundtrip() {
        let key = P256PublicKey {
            qx: B256::repeat_byte(0xAA),
            qy: B256::repeat_byte(0xBB),
        };
        let json = serde_json::to_string(&key).unwrap();
        let decoded: P256PublicKey = serde_json::from_str(&json).unwrap();
        assert_eq!(key, decoded);
    }

    #[test]
    fn p256_signature_serde_roundtrip() {
        let sig = P256Signature {
            r: B256::repeat_byte(0x11),
            s: B256::repeat_byte(0x22),
        };
        let json = serde_json::to_string(&sig).unwrap();
        let decoded: P256Signature = serde_json::from_str(&json).unwrap();
        assert_eq!(sig, decoded);
    }

    #[test]
    fn call_serde_roundtrip() {
        let call = Call {
            to: Address::repeat_byte(0xDE),
            value: U256::from(1_000_000_000_000_000_000u64),
            data: Bytes::from(vec![0x12, 0x34]),
        };
        let json = serde_json::to_string(&call).unwrap();
        let decoded: Call = serde_json::from_str(&json).unwrap();
        assert_eq!(call, decoded);
    }

    #[test]
    fn chain_config_serde_roundtrip() {
        let cfg = ChainConfig {
            chain_id: 84532,
            rpc_url: "https://sepolia.base.org".into(),
            bundler_url: Some("https://bundler.example.com".into()),
            paymaster_url: Some("https://paymaster.example.com".into()),
        };
        let json = serde_json::to_string(&cfg).unwrap();
        let decoded: ChainConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(cfg, decoded);
    }

    #[test]
    fn account_record_multi_chain_serde_roundtrip() {
        let record = AccountRecord {
            address: Address::repeat_byte(0x42),
            key_label: "test-key".into(),
            key_policy: "biometric".into(),
            public_key: P256PublicKey {
                qx: B256::repeat_byte(0x01),
                qy: B256::repeat_byte(0x02),
            },
            chains: vec![
                ChainDeployment {
                    chain_id: 84532,
                    implementation: Address::repeat_byte(0x6D),
                    implementation_name: "KeypoAccount".into(),
                    entry_point: Address::repeat_byte(0x71),
                    bundler_url: Some("https://bundler1.example.com".into()),
                    paymaster_url: None,
                    rpc_url: "https://sepolia.base.org".into(),
                    deployed_at: "2026-03-01T00:00:00Z".into(),
                    tx_hash: None,
                },
                ChainDeployment {
                    chain_id: 1,
                    implementation: Address::repeat_byte(0x6D),
                    implementation_name: "KeypoAccount".into(),
                    entry_point: Address::repeat_byte(0x71),
                    bundler_url: Some("https://bundler2.example.com".into()),
                    paymaster_url: Some("https://paymaster.example.com".into()),
                    rpc_url: "https://eth.example.com".into(),
                    deployed_at: "2026-03-02T00:00:00Z".into(),
                    tx_hash: None,
                },
            ],
            created_at: "2026-03-01T00:00:00Z".into(),
        };
        let json = serde_json::to_string_pretty(&record).unwrap();
        let decoded: AccountRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(record, decoded);
    }

    #[test]
    fn b256_hex_format() {
        let val = B256::repeat_byte(0xAB);
        let json = serde_json::to_string(&val).unwrap();
        // Should be "0x" + 64 hex chars
        let s: String = serde_json::from_str(&json).unwrap();
        assert!(s.starts_with("0x"), "B256 hex should start with 0x");
        assert_eq!(s.len(), 66, "B256 hex should be 66 chars (0x + 64)");
    }

    #[test]
    fn key_info_deserialization() {
        let json = r#"{
            "keyId": "com.keypo.signer.test-key",
            "publicKey": "0x04aabbccdd",
            "policy": "open",
            "status": "active",
            "signingCount": 42,
            "lastUsedAt": "2026-03-01T12:00:00Z"
        }"#;
        let info: KeyInfo = serde_json::from_str(json).unwrap();
        assert_eq!(info.key_id, "com.keypo.signer.test-key");
        assert_eq!(info.policy, "open");
        assert_eq!(info.signing_count, 42);
        assert_eq!(info.last_used_at, Some("2026-03-01T12:00:00Z".to_string()));
    }

    #[test]
    fn balance_query_serde_full() {
        let query = BalanceQuery {
            chains: vec![84532, 1],
            tokens: Some(TokenFilter {
                include: vec![
                    "ETH".into(),
                    "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913".into(),
                ],
                exclude: vec![],
                min_balance: Some("0.001".into()),
            }),
            format: "json".into(),
            sort_by: Some("balance".into()),
        };
        let json = serde_json::to_string(&query).unwrap();
        let decoded: BalanceQuery = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.chains, vec![84532, 1]);
        assert_eq!(decoded.format, "json");
        assert_eq!(decoded.sort_by, Some("balance".into()));
        let tokens = decoded.tokens.unwrap();
        assert_eq!(tokens.include.len(), 2);
        assert_eq!(tokens.min_balance, Some("0.001".into()));
    }

    #[test]
    fn balance_query_serde_minimal() {
        let decoded: BalanceQuery = serde_json::from_str("{}").unwrap();
        assert!(decoded.chains.is_empty());
        assert!(decoded.tokens.is_none());
        assert_eq!(decoded.format, "table");
        assert!(decoded.sort_by.is_none());
    }

    #[test]
    fn balance_query_serde_partial() {
        let json = r#"{"chains": [84532], "format": "csv"}"#;
        let decoded: BalanceQuery = serde_json::from_str(json).unwrap();
        assert_eq!(decoded.chains, vec![84532]);
        assert_eq!(decoded.format, "csv");
        assert!(decoded.tokens.is_none());
        assert!(decoded.sort_by.is_none());
    }

    #[test]
    fn key_info_label_strips_prefix() {
        let info = KeyInfo {
            key_id: "com.keypo.signer.my-key".into(),
            public_key: "0x04aabb".into(),
            policy: "biometric".into(),
            status: "active".into(),
            signing_count: 0,
            last_used_at: None,
        };
        assert_eq!(info.label(), "my-key");
    }
}
