use alloy::primitives::{keccak256, Address};

use crate::types::P256PublicKey;

/// Derives a Tempo account address from a P-256 public key.
///
/// `address = last20bytes(keccak256(pubKeyX || pubKeyY))`
pub fn derive_tempo_address(pub_key: &P256PublicKey) -> Address {
    let mut buf = [0u8; 64];
    buf[..32].copy_from_slice(pub_key.qx.as_slice());
    buf[32..].copy_from_slice(pub_key.qy.as_slice());
    let hash = keccak256(buf);
    Address::from_slice(&hash[12..])
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::B256;

    #[test]
    fn derive_address_deterministic() {
        let pk = P256PublicKey {
            qx: B256::repeat_byte(0xAA),
            qy: B256::repeat_byte(0xBB),
        };
        let addr1 = derive_tempo_address(&pk);
        let addr2 = derive_tempo_address(&pk);
        assert_eq!(addr1, addr2);
        assert_ne!(addr1, Address::ZERO);
    }

    #[test]
    fn derive_address_different_keys_different_addresses() {
        let pk1 = P256PublicKey {
            qx: B256::repeat_byte(0xAA),
            qy: B256::repeat_byte(0xBB),
        };
        let pk2 = P256PublicKey {
            qx: B256::repeat_byte(0xCC),
            qy: B256::repeat_byte(0xDD),
        };
        assert_ne!(derive_tempo_address(&pk1), derive_tempo_address(&pk2));
    }

    #[test]
    fn derive_address_matches_manual_keccak() {
        let pk = P256PublicKey {
            qx: B256::repeat_byte(0x01),
            qy: B256::repeat_byte(0x02),
        };
        // Manually compute: keccak256(0x01*32 || 0x02*32), take last 20 bytes
        let mut buf = [0u8; 64];
        buf[..32].fill(0x01);
        buf[32..].fill(0x02);
        let hash = keccak256(buf);
        let expected = Address::from_slice(&hash[12..]);
        assert_eq!(derive_tempo_address(&pk), expected);
    }
}
