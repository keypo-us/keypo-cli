use alloy::primitives::B256;
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
