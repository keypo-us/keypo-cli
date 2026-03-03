use crate::error::{Error, Result};
use crate::types::{KeyInfo, P256PublicKey, P256Signature};
use alloy::primitives::B256;

/// Trait for P-256 key management and signing operations.
///
/// Named `P256Signer` (not `Signer`) to avoid collision with `alloy::signers::Signer`.
pub trait P256Signer: Send + Sync {
    /// Retrieves the public key for the given label.
    fn get_public_key(&self, label: &str) -> Result<P256PublicKey>;

    /// Creates a new key with the given label and access policy.
    fn create_key(&self, label: &str, policy: &str) -> Result<P256PublicKey>;

    /// Signs a 32-byte digest with the key identified by label.
    fn sign(&self, digest: &[u8; 32], label: &str) -> Result<P256Signature>;

    /// Lists all managed keys.
    fn list_keys(&self) -> Result<Vec<KeyInfo>>;
}

/// Parses an uncompressed P-256 public key (`0x04` || qx || qy) into a `P256PublicKey`.
pub fn parse_public_key(hex_str: &str) -> Result<P256PublicKey> {
    let stripped = hex_str
        .strip_prefix("0x")
        .or_else(|| hex_str.strip_prefix("0X"))
        .unwrap_or(hex_str);

    if !stripped.starts_with("04") {
        return Err(Error::SignerOutput(format!(
            "public key missing 0x04 uncompressed prefix: {}",
            hex_str
        )));
    }

    let coord_hex = &stripped[2..]; // skip "04"
    if coord_hex.len() != 128 {
        return Err(Error::SignerOutput(format!(
            "public key has invalid length (expected 128 hex chars for coordinates, got {}): {}",
            coord_hex.len(),
            hex_str
        )));
    }

    let qx_bytes = hex::decode(&coord_hex[..64])
        .map_err(|e| Error::SignerOutput(format!("invalid hex in qx: {}", e)))?;
    let qy_bytes = hex::decode(&coord_hex[64..])
        .map_err(|e| Error::SignerOutput(format!("invalid hex in qy: {}", e)))?;

    Ok(P256PublicKey {
        qx: B256::from_slice(&qx_bytes),
        qy: B256::from_slice(&qy_bytes),
    })
}

/// Wrapper around the `keypo-signer` CLI binary.
pub struct KeypoSigner {
    binary: String,
}

impl KeypoSigner {
    /// Creates a new KeypoSigner using the default binary name.
    pub fn new() -> Self {
        Self {
            binary: "keypo-signer".to_string(),
        }
    }

    /// Creates a new KeypoSigner with a custom binary path.
    pub fn with_binary(binary: impl Into<String>) -> Self {
        Self {
            binary: binary.into(),
        }
    }

    /// Runs a keypo-signer command and returns parsed JSON output.
    fn run_command(&self, args: &[&str]) -> Result<serde_json::Value> {
        let output = std::process::Command::new(&self.binary)
            .args(args)
            .output()
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::NotFound {
                    Error::SignerNotFound(self.binary.clone())
                } else {
                    Error::SignerCommand(format!("failed to run {}: {}", self.binary, e))
                }
            })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(Error::SignerCommand(format!(
                "{} exited with {}: {}",
                self.binary,
                output.status,
                stderr.trim()
            )));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        serde_json::from_str(stdout.trim())
            .map_err(|e| Error::SignerOutput(format!("failed to parse JSON output: {}", e)))
    }
}

impl Default for KeypoSigner {
    fn default() -> Self {
        Self::new()
    }
}

impl P256Signer for KeypoSigner {
    fn get_public_key(&self, label: &str) -> Result<P256PublicKey> {
        let output = self.run_command(&["info", label, "--format", "json"])?;
        let pk_hex = output["publicKey"]
            .as_str()
            .ok_or_else(|| Error::SignerOutput("missing publicKey field".into()))?;
        parse_public_key(pk_hex)
    }

    fn create_key(&self, label: &str, policy: &str) -> Result<P256PublicKey> {
        let output = self.run_command(&[
            "create", "--label", label, "--policy", policy, "--format", "json",
        ])?;
        let pk_hex = output["publicKey"]
            .as_str()
            .ok_or_else(|| Error::SignerOutput("missing publicKey field".into()))?;
        parse_public_key(pk_hex)
    }

    fn sign(&self, digest: &[u8; 32], label: &str) -> Result<P256Signature> {
        let hex_digest = format!("0x{}", hex::encode(digest));
        let output =
            self.run_command(&["sign", &hex_digest, "--key", label, "--format", "json"])?;

        let r_hex = output["r"]
            .as_str()
            .ok_or_else(|| Error::SignerOutput("missing r field".into()))?;
        let s_hex = output["s"]
            .as_str()
            .ok_or_else(|| Error::SignerOutput("missing s field".into()))?;

        let r_bytes = hex::decode(r_hex.strip_prefix("0x").unwrap_or(r_hex))
            .map_err(|e| Error::SignerOutput(format!("invalid hex in r: {}", e)))?;
        let s_bytes = hex::decode(s_hex.strip_prefix("0x").unwrap_or(s_hex))
            .map_err(|e| Error::SignerOutput(format!("invalid hex in s: {}", e)))?;

        Ok(P256Signature {
            r: B256::from_slice(&r_bytes),
            s: B256::from_slice(&s_bytes),
        })
    }

    fn list_keys(&self) -> Result<Vec<KeyInfo>> {
        let output = self.run_command(&["list", "--format", "json"])?;
        let keys = output["keys"]
            .as_array()
            .ok_or_else(|| Error::SignerOutput("missing keys array".into()))?;

        keys.iter()
            .map(|v| {
                serde_json::from_value(v.clone())
                    .map_err(|e| Error::SignerOutput(format!("failed to parse key info: {}", e)))
            })
            .collect()
    }
}

/// Mock signer for testing — software P-256 signing without Secure Enclave.
#[cfg(any(test, feature = "test-utils"))]
pub mod mock {
    use super::*;
    use p256::ecdsa::{signature::hazmat::PrehashSigner, Signature, SigningKey};
    use std::collections::HashMap;
    use std::sync::Mutex;

    pub struct MockSigner {
        keys: Mutex<HashMap<String, (SigningKey, String)>>,
    }

    impl MockSigner {
        pub fn new() -> Self {
            Self {
                keys: Mutex::new(HashMap::new()),
            }
        }

        /// Adds a random key with the given label and policy.
        pub fn add_key(&self, label: &str, policy: &str) -> P256PublicKey {
            let sk = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
            let pk = extract_public_key(&sk);
            self.keys
                .lock()
                .unwrap()
                .insert(label.to_string(), (sk, policy.to_string()));
            pk
        }

        /// Adds a deterministic key derived from a 32-byte seed.
        pub fn add_deterministic_key(
            &self,
            label: &str,
            policy: &str,
            seed: &[u8; 32],
        ) -> P256PublicKey {
            let sk = SigningKey::from_bytes(seed.into()).expect("valid seed for P-256 signing key");
            let pk = extract_public_key(&sk);
            self.keys
                .lock()
                .unwrap()
                .insert(label.to_string(), (sk, policy.to_string()));
            pk
        }
    }

    impl Default for MockSigner {
        fn default() -> Self {
            Self::new()
        }
    }

    fn extract_public_key(sk: &SigningKey) -> P256PublicKey {
        use p256::ecdsa::VerifyingKey;

        let vk = VerifyingKey::from(sk);
        let point = vk.to_encoded_point(false); // uncompressed
        let x = point.x().expect("x coordinate");
        let y = point.y().expect("y coordinate");

        P256PublicKey {
            qx: B256::from_slice(x),
            qy: B256::from_slice(y),
        }
    }

    impl P256Signer for MockSigner {
        fn get_public_key(&self, label: &str) -> Result<P256PublicKey> {
            let keys = self.keys.lock().unwrap();
            let (sk, _) = keys
                .get(label)
                .ok_or_else(|| Error::SignerNotFound(label.to_string()))?;
            Ok(extract_public_key(sk))
        }

        fn create_key(&self, label: &str, policy: &str) -> Result<P256PublicKey> {
            Ok(self.add_key(label, policy))
        }

        fn sign(&self, digest: &[u8; 32], label: &str) -> Result<P256Signature> {
            let keys = self.keys.lock().unwrap();
            let (sk, _) = keys
                .get(label)
                .ok_or_else(|| Error::SignerNotFound(label.to_string()))?;

            let sig: Signature = sk
                .sign_prehash(digest)
                .map_err(|e| Error::Other(format!("P-256 signing failed: {e}")))?;
            // Normalize to low-S
            let sig = sig.normalize_s().unwrap_or(sig);
            let (r_bytes, s_bytes) = sig.split_bytes();

            Ok(P256Signature {
                r: B256::from_slice(&r_bytes),
                s: B256::from_slice(&s_bytes),
            })
        }

        fn list_keys(&self) -> Result<Vec<KeyInfo>> {
            let keys = self.keys.lock().unwrap();
            Ok(keys
                .iter()
                .map(|(label, (sk, policy))| {
                    let pk = extract_public_key(sk);
                    KeyInfo {
                        key_id: format!("com.keypo.signer.{}", label),
                        public_key: format!(
                            "0x04{}{}",
                            hex::encode(pk.qx.as_slice()),
                            hex::encode(pk.qy.as_slice())
                        ),
                        policy: policy.clone(),
                        status: "active".to_string(),
                        signing_count: 0,
                        last_used_at: None,
                    }
                })
                .collect())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_public_key_valid() {
        // Build a valid uncompressed key: 0x04 + 64 hex qx + 64 hex qy
        let qx_hex = "aa".repeat(32);
        let qy_hex = "bb".repeat(32);
        let pk_hex = format!("0x04{}{}", qx_hex, qy_hex);

        let pk = parse_public_key(&pk_hex).unwrap();
        assert_eq!(pk.qx, B256::repeat_byte(0xAA));
        assert_eq!(pk.qy, B256::repeat_byte(0xBB));
    }

    #[test]
    fn parse_public_key_invalid_prefix() {
        let hex = format!("0x05{}", "aa".repeat(64));
        assert!(parse_public_key(&hex).is_err());
    }

    #[test]
    fn parse_public_key_invalid_length() {
        let hex = format!("0x04{}", "aa".repeat(30)); // too short
        assert!(parse_public_key(&hex).is_err());
    }

    #[test]
    fn parse_sign_response() {
        let json: serde_json::Value = serde_json::from_str(
            r#"{"r":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","s":"0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}"#,
        )
        .unwrap();

        let r_hex = json["r"].as_str().unwrap();
        let s_hex = json["s"].as_str().unwrap();
        let r_bytes = hex::decode(r_hex.strip_prefix("0x").unwrap()).unwrap();
        let s_bytes = hex::decode(s_hex.strip_prefix("0x").unwrap()).unwrap();

        let sig = P256Signature {
            r: B256::from_slice(&r_bytes),
            s: B256::from_slice(&s_bytes),
        };
        assert_eq!(sig.r, B256::repeat_byte(0xAA));
        assert_eq!(sig.s, B256::repeat_byte(0xBB));
    }

    #[test]
    fn mock_signer_create_and_sign() {
        use mock::MockSigner;

        let signer = MockSigner::new();
        let pk = signer.create_key("test", "open").unwrap();

        // Public key coordinates should be non-zero
        assert_ne!(pk.qx, B256::ZERO);
        assert_ne!(pk.qy, B256::ZERO);

        // Sign a digest
        let digest = [0x42u8; 32];
        let sig = signer.sign(&digest, "test").unwrap();
        assert_ne!(sig.r, B256::ZERO);
        assert_ne!(sig.s, B256::ZERO);
    }

    #[test]
    fn mock_signer_deterministic_key() {
        use mock::MockSigner;

        let seed = [0x01u8; 32];
        let signer1 = MockSigner::new();
        let pk1 = signer1.add_deterministic_key("det", "open", &seed);

        let signer2 = MockSigner::new();
        let pk2 = signer2.add_deterministic_key("det", "open", &seed);

        assert_eq!(pk1, pk2, "same seed should produce same public key");
    }
}
