use alloy::primitives::{keccak256, Address, Bytes, B256, U256};
use alloy::rlp::{Decodable, Encodable};

use crate::error::{Error, Result};

/// A single call within a Tempo transaction.
/// Encoded as RLP list: [to, value, data]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TempoCall {
    pub to: Address,
    pub value: U256,
    pub data: Bytes,
}

impl Encodable for TempoCall {
    fn encode(&self, out: &mut dyn alloy::rlp::BufMut) {
        let payload_len = self.to.length() + self.value.length() + self.data.length();
        alloy::rlp::Header {
            list: true,
            payload_length: payload_len,
        }
        .encode(out);
        self.to.encode(out);
        self.value.encode(out);
        self.data.encode(out);
    }

    fn length(&self) -> usize {
        let payload_len = self.to.length() + self.value.length() + self.data.length();
        alloy::rlp::length_of_length(payload_len) + payload_len
    }
}

impl Decodable for TempoCall {
    fn decode(buf: &mut &[u8]) -> alloy::rlp::Result<Self> {
        let header = alloy::rlp::Header::decode(buf)?;
        if !header.list {
            return Err(alloy::rlp::Error::UnexpectedString);
        }
        let to = Address::decode(buf)?;
        let value = U256::decode(buf)?;
        let data = Bytes::decode(buf)?;
        Ok(TempoCall { to, value, data })
    }
}

/// A Tempo transaction (type 0x76).
///
/// Field order per Tempo spec (confirmed from source code):
/// ```text
/// 0x76 || rlp([
///   chain_id, max_priority_fee_per_gas, max_fee_per_gas, gas,
///   calls, access_list, nonce_key, nonce,
///   valid_before, valid_after, fee_token,
///   fee_payer_signature, aa_authorization_list,
///   key_authorization?,   // trailing: zero bytes if None
///   sender_signature      // raw bytes (not RLP list)
/// ])
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TempoTx {
    pub chain_id: u64,
    pub max_priority_fee_per_gas: u128,
    pub max_fee_per_gas: u128,
    pub gas_limit: u64,
    pub calls: Vec<TempoCall>,
    // accessList: always empty for now
    pub nonce_key: U256,
    pub nonce: u64,
    pub valid_before: Option<u64>,
    pub valid_after: Option<u64>,
    pub fee_token: Option<Address>,
    pub fee_payer_signature: Option<Bytes>,
    // aaAuthorizationList: always empty for now
    /// Raw RLP-encoded signed key authorization (an RLP list, pasted inline).
    /// When None, zero bytes are emitted (truly trailing/optional).
    pub key_authorization: Option<Vec<u8>>,
}

/// Helper for RLP encoding optional values.
/// None -> encodes as empty string (0x80)
fn encode_optional<T: Encodable>(opt: &Option<T>, out: &mut dyn alloy::rlp::BufMut) {
    match opt {
        Some(v) => v.encode(out),
        None => out.put_u8(0x80),
    }
}

fn optional_length<T: Encodable>(opt: &Option<T>) -> usize {
    match opt {
        Some(v) => v.length(),
        None => 1, // 0x80
    }
}

/// Empty list encoding (0xc0)
const EMPTY_LIST_LEN: usize = 1;

fn encode_empty_list(out: &mut dyn alloy::rlp::BufMut) {
    out.put_u8(0xc0);
}

impl TempoTx {
    /// RLP length of unsigned fields (no signature, no key_authorization).
    fn unsigned_fields_len(&self) -> usize {
        self.chain_id.length()
            + self.max_priority_fee_per_gas.length()
            + self.max_fee_per_gas.length()
            + self.gas_limit.length()
            + self.calls.length()
            + EMPTY_LIST_LEN // accessList
            + self.nonce_key.length()
            + self.nonce.length()
            + optional_length(&self.valid_before)
            + optional_length(&self.valid_after)
            + optional_length(&self.fee_token)
            + optional_length(&self.fee_payer_signature)
            + EMPTY_LIST_LEN // aaAuthorizationList
    }

    /// Encode the common fields (everything before key_authorization/signature).
    fn encode_common_fields(&self, out: &mut dyn alloy::rlp::BufMut) {
        self.chain_id.encode(out);
        self.max_priority_fee_per_gas.encode(out);
        self.max_fee_per_gas.encode(out);
        self.gas_limit.encode(out);
        self.calls.encode(out);
        encode_empty_list(out); // accessList
        self.nonce_key.encode(out);
        self.nonce.encode(out);
        encode_optional(&self.valid_before, out);
        encode_optional(&self.valid_after, out);
        encode_optional(&self.fee_token, out);
        encode_optional(&self.fee_payer_signature, out);
        encode_empty_list(out); // aaAuthorizationList
    }
}

impl Encodable for TempoTx {
    fn encode(&self, out: &mut dyn alloy::rlp::BufMut) {
        // For signing hash: encode just the unsigned fields (no key_auth, no sig)
        let payload_len = self.unsigned_fields_len();
        alloy::rlp::Header {
            list: true,
            payload_length: payload_len,
        }
        .encode(out);
        self.encode_common_fields(out);
    }

    fn length(&self) -> usize {
        let payload_len = self.unsigned_fields_len();
        alloy::rlp::length_of_length(payload_len) + payload_len
    }
}

impl Decodable for TempoTx {
    fn decode(buf: &mut &[u8]) -> alloy::rlp::Result<Self> {
        let header = alloy::rlp::Header::decode(buf)?;
        if !header.list {
            return Err(alloy::rlp::Error::UnexpectedString);
        }

        let chain_id = u64::decode(buf)?;
        let max_priority_fee_per_gas = u128::decode(buf)?;
        let max_fee_per_gas = u128::decode(buf)?;
        let gas_limit = u64::decode(buf)?;
        let calls = Vec::<TempoCall>::decode(buf)?;
        let _access_list_header = alloy::rlp::Header::decode(buf)?; // skip empty list
        let nonce_key = U256::decode(buf)?;
        let nonce = u64::decode(buf)?;
        let valid_before = decode_optional_u64(buf)?;
        let valid_after = decode_optional_u64(buf)?;
        let fee_token = decode_optional_address(buf)?;
        let fee_payer_signature = decode_optional_bytes(buf)?;
        let _aa_list_header = alloy::rlp::Header::decode(buf)?; // skip empty list

        // key_authorization is trailing: check if next byte is an RLP list (>= 0xc0)
        let key_authorization = if let Some(&first) = buf.first() {
            if first >= 0xc0 {
                Some(consume_raw_rlp_item(buf)?)
            } else {
                None
            }
        } else {
            None
        };

        Ok(TempoTx {
            chain_id,
            max_priority_fee_per_gas,
            max_fee_per_gas,
            gas_limit,
            calls,
            nonce_key,
            nonce,
            valid_before,
            valid_after,
            fee_token,
            fee_payer_signature,
            key_authorization,
        })
    }
}

/// Consume an entire RLP item (list or string) from the buffer and return it as raw bytes.
fn consume_raw_rlp_item(buf: &mut &[u8]) -> alloy::rlp::Result<Vec<u8>> {
    let item_start = *buf;
    let header = alloy::rlp::Header::decode(buf)?;
    let header_len = item_start.len() - buf.len();
    if buf.len() < header.payload_length {
        return Err(alloy::rlp::Error::InputTooShort);
    }
    let payload = &buf[..header.payload_length];
    *buf = &buf[header.payload_length..];
    let mut raw = Vec::with_capacity(header_len + header.payload_length);
    raw.extend_from_slice(&item_start[..header_len]);
    raw.extend_from_slice(payload);
    Ok(raw)
}

fn decode_optional_address(buf: &mut &[u8]) -> alloy::rlp::Result<Option<Address>> {
    if buf.is_empty() || buf[0] == 0x80 {
        if !buf.is_empty() {
            *buf = &buf[1..];
        }
        return Ok(None);
    }
    Address::decode(buf).map(Some)
}

fn decode_optional_u64(buf: &mut &[u8]) -> alloy::rlp::Result<Option<u64>> {
    if buf.is_empty() || buf[0] == 0x80 {
        if !buf.is_empty() {
            *buf = &buf[1..];
        }
        return Ok(None);
    }
    u64::decode(buf).map(Some)
}

fn decode_optional_bytes(buf: &mut &[u8]) -> alloy::rlp::Result<Option<Bytes>> {
    if buf.is_empty() || buf[0] == 0x80 {
        if !buf.is_empty() {
            *buf = &buf[1..];
        }
        return Ok(None);
    }
    Bytes::decode(buf).map(Some)
}

/// RLP-encode a TempoTx (just the unsigned fields, no type byte, no signature).
pub fn rlp_encode_tx(tx: &TempoTx) -> Vec<u8> {
    let mut out = Vec::new();
    tx.encode(&mut out);
    out
}

/// RLP-decode a TempoTx from bytes.
pub fn rlp_decode_tx(data: &[u8]) -> Result<TempoTx> {
    TempoTx::decode(&mut &data[..])
        .map_err(|e| Error::Other(format!("RLP decode error: {e}")))
}

/// Compute the signing hash for a Tempo transaction.
///
/// `keccak256(0x76 || rlp(fields_including_key_authorization))`
///
/// When key_authorization is present, it is included in the hash
/// (as a trailing field in the RLP list).
pub fn signing_hash(tx: &TempoTx) -> B256 {
    // Build the RLP list including key_authorization if present
    let mut payload_len = tx.unsigned_fields_len();
    if let Some(ref ka) = tx.key_authorization {
        payload_len += ka.len();
    }

    let mut rlp = Vec::new();
    alloy::rlp::Header {
        list: true,
        payload_length: payload_len,
    }
    .encode(&mut rlp);
    tx.encode_common_fields(&mut rlp);
    if let Some(ref ka) = tx.key_authorization {
        rlp.extend_from_slice(ka);
    }

    let mut prefixed = Vec::with_capacity(1 + rlp.len());
    prefixed.push(0x76);
    prefixed.extend_from_slice(&rlp);
    keccak256(prefixed)
}

/// Serialize a signed transaction envelope.
///
/// Without key_authorization:
/// `0x76 || rlp(unsigned_fields || signature)`
///
/// With key_authorization:
/// `0x76 || rlp(unsigned_fields || key_authorization_rlp || signature)`
pub fn serialize_signed_tx(tx: &TempoTx, signature: &[u8]) -> Vec<u8> {
    let sig_bytes = Bytes::from(signature.to_vec());

    // Payload = unsigned fields + optional key_authorization + signature
    let mut payload_len = tx.unsigned_fields_len() + sig_bytes.length();
    if let Some(ref ka) = tx.key_authorization {
        payload_len += ka.len(); // raw RLP bytes, no wrapping
    }

    let mut out = Vec::new();
    out.push(0x76); // type byte

    alloy::rlp::Header {
        list: true,
        payload_length: payload_len,
    }
    .encode(&mut out);

    tx.encode_common_fields(&mut out);

    // Key authorization (trailing, only if present)
    if let Some(ref ka) = tx.key_authorization {
        out.extend_from_slice(ka);
    }

    // Signature (raw bytes, RLP-encoded as string)
    sig_bytes.encode(&mut out);

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_tx() -> TempoTx {
        TempoTx {
            chain_id: 42431,
            max_priority_fee_per_gas: 1_000_000,
            max_fee_per_gas: 40_002_000_000,
            gas_limit: 86_000,
            calls: vec![TempoCall {
                to: Address::repeat_byte(0xAA),
                value: U256::ZERO,
                data: Bytes::from(vec![0x12, 0x34]),
            }],
            nonce_key: U256::ZERO,
            nonce: 0,
            valid_before: None,
            valid_after: None,
            fee_token: None,
            fee_payer_signature: None,
            key_authorization: None,
        }
    }

    #[test]
    fn rlp_roundtrip() {
        let tx = test_tx();
        let encoded = rlp_encode_tx(&tx);
        let decoded = rlp_decode_tx(&encoded).unwrap();
        assert_eq!(tx, decoded);
    }

    #[test]
    fn rlp_roundtrip_with_optional_fields() {
        let tx = TempoTx {
            fee_token: Some(Address::repeat_byte(0xBB)),
            valid_before: Some(1_700_000_000),
            valid_after: Some(1_600_000_000),
            ..test_tx()
        };
        let encoded = rlp_encode_tx(&tx);
        let decoded = rlp_decode_tx(&encoded).unwrap();
        assert_eq!(tx, decoded);
    }

    #[test]
    fn rlp_roundtrip_multiple_calls() {
        let tx = TempoTx {
            calls: vec![
                TempoCall {
                    to: Address::repeat_byte(0x01),
                    value: U256::from(100u64),
                    data: Bytes::from(vec![0x01]),
                },
                TempoCall {
                    to: Address::repeat_byte(0x02),
                    value: U256::from(200u64),
                    data: Bytes::from(vec![0x02, 0x03]),
                },
            ],
            ..test_tx()
        };
        let encoded = rlp_encode_tx(&tx);
        let decoded = rlp_decode_tx(&encoded).unwrap();
        assert_eq!(tx, decoded);
    }

    #[test]
    fn rlp_roundtrip_large_nonce_key() {
        let tx = TempoTx {
            nonce_key: U256::MAX,
            ..test_tx()
        };
        let encoded = rlp_encode_tx(&tx);
        let decoded = rlp_decode_tx(&encoded).unwrap();
        assert_eq!(tx, decoded);
    }

    #[test]
    fn signing_hash_deterministic() {
        let tx = test_tx();
        let h1 = signing_hash(&tx);
        let h2 = signing_hash(&tx);
        assert_eq!(h1, h2);
        assert_ne!(h1, B256::ZERO);
    }

    #[test]
    fn signing_hash_includes_type_byte() {
        let tx = test_tx();
        let rlp = rlp_encode_tx(&tx);
        let mut prefixed = vec![0x76];
        prefixed.extend_from_slice(&rlp);
        let expected = keccak256(prefixed);
        assert_eq!(signing_hash(&tx), expected);
    }

    #[test]
    fn signing_hash_changes_with_nonce() {
        let tx1 = test_tx();
        let mut tx2 = test_tx();
        tx2.nonce = 1;
        assert_ne!(signing_hash(&tx1), signing_hash(&tx2));
    }

    #[test]
    fn serialize_signed_tx_starts_with_0x76() {
        let tx = test_tx();
        let fake_sig = vec![0x01; 130];
        let envelope = serialize_signed_tx(&tx, &fake_sig);
        assert_eq!(envelope[0], 0x76);
    }

    #[test]
    fn serialize_with_key_authorization_longer() {
        let tx_without = test_tx();
        let mut tx_with = test_tx();
        // A minimal RLP list: [0x42] = c1 42
        tx_with.key_authorization = Some(vec![0xc1, 0x42]);

        let fake_sig = vec![0x01; 130];
        let env_without = serialize_signed_tx(&tx_without, &fake_sig);
        let env_with = serialize_signed_tx(&tx_with, &fake_sig);
        // With key_authorization should be exactly 2 bytes longer
        assert_eq!(env_with.len(), env_without.len() + 2);
    }
}
