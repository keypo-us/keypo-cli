use std::time::Duration;

use alloy::primitives::{Address, Bytes, U256, B256};

use crate::config::WalletConfig;
use crate::error::{Error, Result};
use crate::rlp::{self, TempoCall, TempoTx};
use crate::rpc;
use crate::signature;
use crate::signer::P256Signer;

/// Result of a submitted Tempo transaction.
#[derive(Debug, Clone)]
pub struct TxResult {
    pub tx_hash: B256,
    pub success: bool,
    pub block_number: u64,
    pub gas_used: u64,
}

/// Builds, signs, submits, and waits for a Tempo transaction.
///
/// If `root_address` is `Some`, the transaction is signed with an access key
/// (Keychain signature format 0x03). If `None`, signed with the root key
/// (P-256 signature format 0x01).
pub async fn send_tempo_tx(
    rpc_url: &str,
    wallet: &WalletConfig,
    calls: Vec<TempoCall>,
    signer: &dyn P256Signer,
    signing_key_label: &str,
    root_address: Option<Address>,
    key_authorization: Option<Vec<u8>>,
) -> Result<TxResult> {
    let client = reqwest::Client::new();
    let sender_address: Address = wallet.address.parse()
        .map_err(|e| Error::Other(format!("invalid wallet address: {e}")))?;

    // Fetch nonce
    let nonce = rpc::get_nonce(&client, rpc_url, sender_address).await?;
    tracing::debug!("nonce: {nonce}");

    // Fetch gas price
    let gas_price = rpc::get_gas_price(&client, rpc_url).await?;
    let max_fee_per_gas = gas_price * 2; // 2x buffer
    let max_priority_fee_per_gas = gas_price / 10; // 10% tip
    tracing::debug!("gas_price: {gas_price}, max_fee: {max_fee_per_gas}");

    // Gas estimation: use a generous limit, the protocol refunds unused gas
    // P-256 signature verification: 26,000 base + 5,000 for P-256
    // Keychain: +3,000 for key validation
    // Key authorization: +35,000 base + 22,000 per spending limit
    // Contract calls: ~100,000 per call with data (TIP-20 transfer)
    // The testnet transaction we observed used 0x8a210 = 565,776 for a mint
    let base_gas: u64 = if root_address.is_some() { 29_000 } else { 26_000 };
    let auth_gas: u64 = if key_authorization.is_some() { 500_000 } else { 0 }; // key auth is expensive
    let call_gas: u64 = calls.iter().map(|c| {
        if c.data.is_empty() { 21_000 } else { 200_000 }
    }).sum();
    let gas_limit = base_gas + auth_gas + call_gas + 100_000; // generous buffer

    // Build transaction
    let tx = TempoTx {
        chain_id: wallet.chain_id,
        max_priority_fee_per_gas,
        max_fee_per_gas,
        gas_limit,
        calls,
        nonce_key: U256::ZERO,
        nonce,
        valid_before: None,
        valid_after: None,
        fee_token: None,
        key_authorization,
        fee_payer_signature: None,
    };

    // Compute signing hash
    let tx_hash = rlp::signing_hash(&tx);
    tracing::debug!("tx signing hash: {tx_hash}");

    // For access key (Keychain V2), derive the domain-separated hash
    let effective_hash = match root_address {
        Some(root_addr) => {
            let v2_hash = signature::keychain_v2_signing_hash(tx_hash, root_addr);
            tracing::debug!("keychain v2 hash: {v2_hash}");
            v2_hash
        }
        None => tx_hash,
    };

    // Sign
    let hash_bytes: &[u8; 32] = effective_hash.as_ref();
    let sig = signer.sign(hash_bytes, signing_key_label)?;
    let pub_key = signer.get_public_key(signing_key_label)?;

    // Format signature (pre_hash = false per Tempo Protocol Reference)
    let p256_sig = signature::format_p256_signature(&sig, &pub_key, false);
    let final_sig = match root_address {
        Some(root_addr) => signature::format_keychain_signature(root_addr, &p256_sig),
        None => p256_sig,
    };

    // Serialize signed transaction envelope
    let raw = rlp::serialize_signed_tx(&tx, &final_sig);
    tracing::debug!("raw tx: {} bytes, hex: 0x{}", raw.len(), hex::encode(&raw));

    // Submit
    let tx_hash = rpc::send_raw_transaction(&client, rpc_url, &raw).await?;
    tracing::info!("tx submitted: {tx_hash}");

    // Wait for receipt
    let receipt = rpc::wait_for_receipt(&client, rpc_url, tx_hash, Duration::from_secs(60)).await?;

    if !receipt.status {
        return Err(Error::TransactionFailed(format!(
            "tx {tx_hash} reverted in block {}",
            receipt.block_number
        )));
    }

    Ok(TxResult {
        tx_hash: receipt.tx_hash,
        success: receipt.status,
        block_number: receipt.block_number,
        gas_used: receipt.gas_used,
    })
}

/// Encodes a TIP-20 `transfer(address,uint256)` call.
pub fn encode_tip20_transfer(to: Address, amount: U256) -> Bytes {
    // transfer(address,uint256) selector = keccak256("transfer(address,uint256)")[..4]
    // = 0xa9059cbb
    let mut data = vec![0xa9, 0x05, 0x9c, 0xbb];
    // ABI-encode the address (32 bytes, left-padded)
    let mut addr_bytes = [0u8; 32];
    addr_bytes[12..].copy_from_slice(to.as_slice());
    data.extend_from_slice(&addr_bytes);
    // ABI-encode the amount (32 bytes)
    data.extend_from_slice(&amount.to_be_bytes::<32>());
    Bytes::from(data)
}

/// Encodes a TIP-20 `balanceOf(address)` call.
pub fn encode_balance_of(account: Address) -> Bytes {
    // balanceOf(address) selector = 0x70a08231
    let mut data = vec![0x70, 0xa0, 0x82, 0x31];
    let mut addr_bytes = [0u8; 32];
    addr_bytes[12..].copy_from_slice(account.as_slice());
    data.extend_from_slice(&addr_bytes);
    Bytes::from(data)
}

/// Encodes a TIP-20 `decimals()` call.
pub fn encode_decimals() -> Bytes {
    // decimals() selector = 0x313ce567
    Bytes::from(vec![0x31, 0x3c, 0xe5, 0x67])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_tip20_transfer_correct_selector() {
        let data = encode_tip20_transfer(Address::ZERO, U256::from(1000u64));
        assert_eq!(&data[..4], &[0xa9, 0x05, 0x9c, 0xbb]);
        assert_eq!(data.len(), 4 + 32 + 32); // selector + address + amount
    }

    #[test]
    fn encode_balance_of_correct_selector() {
        let data = encode_balance_of(Address::ZERO);
        assert_eq!(&data[..4], &[0x70, 0xa0, 0x82, 0x31]);
        assert_eq!(data.len(), 4 + 32);
    }

    #[test]
    fn encode_decimals_correct_selector() {
        let data = encode_decimals();
        assert_eq!(&data[..4], &[0x31, 0x3c, 0xe5, 0x67]);
        assert_eq!(data.len(), 4);
    }

    #[test]
    fn encode_transfer_address_padded() {
        let addr = Address::repeat_byte(0xFF);
        let data = encode_tip20_transfer(addr, U256::from(0u64));
        // Address is in bytes 4..36, left-padded with zeros
        assert_eq!(&data[4..16], &[0u8; 12]); // 12 zero bytes padding
        assert_eq!(&data[16..36], addr.as_slice()); // 20 address bytes
    }
}
