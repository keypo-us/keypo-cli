use alloy::primitives::{keccak256, Address, Bytes, U256};
use alloy::rlp::Encodable;

use crate::error::Result;
use crate::rpc;
use crate::signer::P256Signer;

// ---------------------------------------------------------------------------
// AccountKeychain precompile
// ---------------------------------------------------------------------------

/// AccountKeychain precompile address on Tempo.
pub const ACCOUNT_KEYCHAIN: Address =
    Address::new(hex_literal("AAAAAAAA00000000000000000000000000000000"));

const fn hex_literal(s: &str) -> [u8; 20] {
    let bytes = s.as_bytes();
    let mut result = [0u8; 20];
    let mut i = 0;
    while i < 20 {
        let hi = hex_val(bytes[i * 2]);
        let lo = hex_val(bytes[i * 2 + 1]);
        result[i] = (hi << 4) | lo;
        i += 1;
    }
    result
}

const fn hex_val(c: u8) -> u8 {
    match c {
        b'0'..=b'9' => c - b'0',
        b'a'..=b'f' => c - b'a' + 10,
        b'A'..=b'F' => c - b'A' + 10,
        _ => panic!("invalid hex char"),
    }
}

// ---------------------------------------------------------------------------
// Spending limits
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpendingLimit {
    pub token: Address,
    pub amount: U256,
}

// ---------------------------------------------------------------------------
// KeyAuthorization RLP encoding
// ---------------------------------------------------------------------------

/// Represents a key authorization to be signed by the root key.
#[derive(Debug, Clone)]
pub struct KeyAuthorization {
    pub chain_id: u64,
    pub key_type: u8,   // 1 for P-256
    pub key_id: Address, // derived from access key's public key
    pub expiry: Option<u64>,
    pub limits: Vec<SpendingLimit>,
}

/// RLP-encode a KeyAuthorization (unsigned).
/// `rlp([chain_id, key_type, key_id, expiry?, limits?])`
pub fn rlp_encode_key_authorization(auth: &KeyAuthorization) -> Vec<u8> {
    let mut payload = Vec::new();
    auth.chain_id.encode(&mut payload);
    auth.key_type.encode(&mut payload);
    auth.key_id.encode(&mut payload);

    // Expiry: encode value or 0x80 for none
    match auth.expiry {
        Some(e) => e.encode(&mut payload),
        None => payload.push(0x80),
    }

    // Limits: encode as list of [token, amount] pairs, or 0x80 for none
    if auth.limits.is_empty() {
        payload.push(0x80);
    } else {
        // Build inner list of [token, amount] pairs
        let mut limits_payload = Vec::new();
        for limit in &auth.limits {
            let mut pair_payload = Vec::new();
            limit.token.encode(&mut pair_payload);
            limit.amount.encode(&mut pair_payload);
            alloy::rlp::Header {
                list: true,
                payload_length: pair_payload.len(),
            }
            .encode(&mut limits_payload);
            limits_payload.extend_from_slice(&pair_payload);
        }
        alloy::rlp::Header {
            list: true,
            payload_length: limits_payload.len(),
        }
        .encode(&mut payload);
        payload.extend_from_slice(&limits_payload);
    }

    // Wrap in outer list
    let mut out = Vec::new();
    alloy::rlp::Header {
        list: true,
        payload_length: payload.len(),
    }
    .encode(&mut out);
    out.extend_from_slice(&payload);
    out
}

/// Compute the authorization digest that the root key signs.
/// `keccak256(rlp([chain_id, key_type, key_id, expiry?, limits?]))`
pub fn authorization_digest(auth: &KeyAuthorization) -> [u8; 32] {
    let rlp = rlp_encode_key_authorization(auth);
    let hash = keccak256(rlp);
    *hash
}

/// RLP-encode a signed authorization.
///
/// Tempo's `SignedKeyAuthorization` is an RLP list with two items:
/// 1. `KeyAuthorization` — a nested RLP list `[chain_id, key_type, key_id, expiry?, limits?]`
/// 2. `PrimitiveSignature` — encoded as bytes (P-256: 0x01 || r || s || pubX || pubY || pre_hash)
///
/// So the encoding is: `rlp([ rlp([chain_id, key_type, key_id, ...]), sig_bytes ])`
pub fn rlp_encode_signed_authorization(
    auth: &KeyAuthorization,
    sig_bytes: &[u8],
) -> Vec<u8> {
    // First item: the KeyAuthorization RLP list (reuse rlp_encode_key_authorization)
    let auth_rlp = rlp_encode_key_authorization(auth);

    // Second item: the signature as an RLP bytes string
    let sig = Bytes::from(sig_bytes.to_vec());

    // Outer list: [auth_rlp, sig_bytes]
    let payload_len = auth_rlp.len() + sig.length();
    let mut out = Vec::new();
    alloy::rlp::Header {
        list: true,
        payload_length: payload_len,
    }
    .encode(&mut out);
    out.extend_from_slice(&auth_rlp); // nested list (already has list header)
    sig.encode(&mut out); // bytes string

    out
}

// ---------------------------------------------------------------------------
// ABI encoding for AccountKeychain precompile calls
// ---------------------------------------------------------------------------

/// Encodes `revokeKey(address keyId)` — selector: keccak256("revokeKey(address)")[..4]
pub fn encode_revoke_key(key_id: Address) -> Bytes {
    // revokeKey(address) = 0x8beb4c43 (computed from keccak256)
    let mut data = keccak256("revokeKey(address)")[..4].to_vec();
    let mut addr_bytes = [0u8; 32];
    addr_bytes[12..].copy_from_slice(key_id.as_slice());
    data.extend_from_slice(&addr_bytes);
    Bytes::from(data)
}

/// Encodes `updateSpendingLimit(address keyId, address token, uint256 newLimit)`
pub fn encode_update_spending_limit(
    key_id: Address,
    token: Address,
    new_limit: U256,
) -> Bytes {
    let mut data =
        keccak256("updateSpendingLimit(address,address,uint256)")[..4].to_vec();
    let mut key_bytes = [0u8; 32];
    key_bytes[12..].copy_from_slice(key_id.as_slice());
    data.extend_from_slice(&key_bytes);
    let mut token_bytes = [0u8; 32];
    token_bytes[12..].copy_from_slice(token.as_slice());
    data.extend_from_slice(&token_bytes);
    data.extend_from_slice(&new_limit.to_be_bytes::<32>());
    Bytes::from(data)
}

/// Encodes `getKey(address account, address keyId)` for eth_call.
pub fn encode_get_key(account: Address, key_id: Address) -> Bytes {
    let mut data = keccak256("getKey(address,address)")[..4].to_vec();
    let mut acct_bytes = [0u8; 32];
    acct_bytes[12..].copy_from_slice(account.as_slice());
    data.extend_from_slice(&acct_bytes);
    let mut key_bytes = [0u8; 32];
    key_bytes[12..].copy_from_slice(key_id.as_slice());
    data.extend_from_slice(&key_bytes);
    Bytes::from(data)
}

/// Encodes `getRemainingLimit(address account, address keyId, address token)` for eth_call.
pub fn encode_get_remaining_limit(
    account: Address,
    key_id: Address,
    token: Address,
) -> Bytes {
    let mut data =
        keccak256("getRemainingLimit(address,address,address)")[..4].to_vec();
    let mut acct_bytes = [0u8; 32];
    acct_bytes[12..].copy_from_slice(account.as_slice());
    data.extend_from_slice(&acct_bytes);
    let mut key_bytes = [0u8; 32];
    key_bytes[12..].copy_from_slice(key_id.as_slice());
    data.extend_from_slice(&key_bytes);
    let mut token_bytes = [0u8; 32];
    token_bytes[12..].copy_from_slice(token.as_slice());
    data.extend_from_slice(&token_bytes);
    Bytes::from(data)
}

// ---------------------------------------------------------------------------
// On-chain queries
// ---------------------------------------------------------------------------

/// Status of an access key on-chain.
#[derive(Debug, Clone)]
pub struct KeyStatus {
    pub signature_type: u8,
    pub key_id: Address,
    pub expiry: u64,
}

/// Queries the on-chain status of an access key via the AccountKeychain precompile.
/// Returns None if the key is not registered.
pub async fn query_key_status(
    client: &reqwest::Client,
    rpc_url: &str,
    account: Address,
    key_id: Address,
) -> Result<Option<KeyStatus>> {
    let calldata = encode_get_key(account, key_id);
    let result = rpc::eth_call(client, rpc_url, ACCOUNT_KEYCHAIN, &calldata).await?;

    // getKey returns (uint8 signatureType, address keyId, uint256 expiry)
    // If not registered, returns all zeros
    if result.len() < 96 {
        return Ok(None);
    }

    let sig_type = result[31]; // last byte of first 32-byte word
    let returned_key_id = Address::from_slice(&result[44..64]); // bytes 44-63

    // If signatureType is 0 and keyId is zero, the key is not registered
    if sig_type == 0 && returned_key_id == Address::ZERO {
        return Ok(None);
    }

    let expiry = u64::from_be_bytes(result[88..96].try_into().unwrap_or([0u8; 8]));

    Ok(Some(KeyStatus {
        signature_type: sig_type,
        key_id: returned_key_id,
        expiry,
    }))
}

/// Queries the remaining spending limit for an access key and token.
pub async fn query_remaining_limit(
    client: &reqwest::Client,
    rpc_url: &str,
    account: Address,
    key_id: Address,
    token: Address,
) -> Result<U256> {
    let calldata = encode_get_remaining_limit(account, key_id, token);
    let result = rpc::eth_call(client, rpc_url, ACCOUNT_KEYCHAIN, &calldata).await?;

    if result.len() < 32 {
        return Ok(U256::ZERO);
    }

    Ok(U256::from_be_slice(&result[..32]))
}

// ---------------------------------------------------------------------------
// High-level operations
// ---------------------------------------------------------------------------

/// Signs a KeyAuthorization with the root key and returns the signed authorization RLP.
pub fn sign_and_encode_authorization(
    auth: &KeyAuthorization,
    signer: &dyn P256Signer,
    root_key_label: &str,
    bio_reason: Option<&str>,
) -> Result<Vec<u8>> {
    let digest = authorization_digest(auth);
    let sig = signer.sign(&digest, root_key_label, bio_reason)?;
    let pub_key = signer.get_public_key(root_key_label)?;
    // Format as P-256 signature (type 0x01, pre_hash = false)
    let sig_bytes = crate::signature::format_p256_signature(&sig, &pub_key, false);
    Ok(rlp_encode_signed_authorization(auth, &sig_bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn account_keychain_address() {
        // Address display uses EIP-55 checksum, so compare bytes instead
        let expected_bytes = hex::decode("AAAAAAAA00000000000000000000000000000000").unwrap();
        assert_eq!(ACCOUNT_KEYCHAIN.as_slice(), &expected_bytes[..]);
    }

    #[test]
    fn rlp_encode_key_authorization_basic() {
        let auth = KeyAuthorization {
            chain_id: 42431,
            key_type: 1,
            key_id: Address::repeat_byte(0xAA),
            expiry: None,
            limits: vec![],
        };
        let encoded = rlp_encode_key_authorization(&auth);
        // Should be a valid RLP list
        assert!(encoded[0] >= 0xc0, "should start with RLP list prefix");
    }

    #[test]
    fn rlp_encode_key_authorization_with_limits() {
        let auth = KeyAuthorization {
            chain_id: 42431,
            key_type: 1,
            key_id: Address::repeat_byte(0xAA),
            expiry: Some(1_700_000_000),
            limits: vec![
                SpendingLimit {
                    token: Address::repeat_byte(0xBB),
                    amount: U256::from(100_000u64),
                },
            ],
        };
        let encoded = rlp_encode_key_authorization(&auth);
        assert!(encoded[0] >= 0xc0);
        // Should be longer than the basic case
        assert!(encoded.len() > 30);
    }

    #[test]
    fn authorization_digest_deterministic() {
        let auth = KeyAuthorization {
            chain_id: 42431,
            key_type: 1,
            key_id: Address::repeat_byte(0xAA),
            expiry: None,
            limits: vec![],
        };
        let d1 = authorization_digest(&auth);
        let d2 = authorization_digest(&auth);
        assert_eq!(d1, d2);
        assert_ne!(d1, [0u8; 32]);
    }

    #[test]
    fn authorization_digest_changes_with_key_id() {
        let auth1 = KeyAuthorization {
            chain_id: 42431,
            key_type: 1,
            key_id: Address::repeat_byte(0xAA),
            expiry: None,
            limits: vec![],
        };
        let auth2 = KeyAuthorization {
            chain_id: 42431,
            key_type: 1,
            key_id: Address::repeat_byte(0xBB),
            expiry: None,
            limits: vec![],
        };
        assert_ne!(authorization_digest(&auth1), authorization_digest(&auth2));
    }

    #[test]
    fn signed_authorization_contains_signature() {
        let auth = KeyAuthorization {
            chain_id: 42431,
            key_type: 1,
            key_id: Address::repeat_byte(0xAA),
            expiry: None,
            limits: vec![],
        };
        let fake_sig = vec![0x01; 130]; // fake P-256 signature
        let signed = rlp_encode_signed_authorization(&auth, &fake_sig);
        // Should be longer than unsigned
        let unsigned = rlp_encode_key_authorization(&auth);
        assert!(signed.len() > unsigned.len());
        // Should be a valid RLP list
        assert!(signed[0] >= 0xc0);
    }

    #[test]
    fn encode_revoke_key_correct_length() {
        let data = encode_revoke_key(Address::repeat_byte(0xAA));
        assert_eq!(data.len(), 4 + 32); // selector + address
    }

    #[test]
    fn encode_get_key_correct_length() {
        let data = encode_get_key(Address::repeat_byte(0xAA), Address::repeat_byte(0xBB));
        assert_eq!(data.len(), 4 + 32 + 32); // selector + 2 addresses
    }

    #[test]
    fn encode_get_remaining_limit_correct_length() {
        let data = encode_get_remaining_limit(
            Address::repeat_byte(0xAA),
            Address::repeat_byte(0xBB),
            Address::repeat_byte(0xCC),
        );
        assert_eq!(data.len(), 4 + 32 + 32 + 32); // selector + 3 addresses
    }

    #[test]
    fn encode_update_spending_limit_correct_length() {
        let data = encode_update_spending_limit(
            Address::repeat_byte(0xAA),
            Address::repeat_byte(0xBB),
            U256::from(1000u64),
        );
        assert_eq!(data.len(), 4 + 32 + 32 + 32); // selector + 2 addresses + uint256
    }
}
