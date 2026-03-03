//! Integration tests for the transaction sending flow.
//!
//! All tests are `#[ignore]` because they require:
//! - `TEST_FUNDER_PRIVATE_KEY` env var (funded on Base Sepolia)
//! - `BASE_SEPOLIA_RPC_URL` or default `https://sepolia.base.org`
//! - Network access to Base Sepolia + Pimlico bundler
//!
//! NOTE: Run with --test-threads=1 to avoid funder wallet nonce conflicts.
//! set -a && source .env && set +a && cargo test --test integration_send -- --ignored --test-threads=1

use std::sync::Once;
use std::time::Duration;

use alloy::primitives::{address, Address, Bytes, U256};

use keypo_wallet::account::{self, FundingStrategy, SetupConfig, SETUP_FUNDING_AMOUNT};
use keypo_wallet::bundler::BundlerClient;
use keypo_wallet::impls::KeypoAccountImpl;
use keypo_wallet::signer::mock::MockSigner;
use keypo_wallet::state::StateStore;
use keypo_wallet::transaction;
use keypo_wallet::types::Call;

static INIT_TRACING: Once = Once::new();
fn init_tracing() {
    INIT_TRACING.call_once(|| {
        tracing_subscriber::fmt()
            .with_test_writer()
            .try_init()
            .ok();
    });
}

const KEYPO_ACCOUNT_ADDR: Address =
    address!("0x6d1566f9aAcf9c06969D7BF846FA090703A38E43");
const BASE_SEPOLIA_RPC: &str = "https://sepolia.base.org";
const BASE_SEPOLIA_CHAIN_ID: u64 = 84532;
const ENTRY_POINT_V07: Address =
    address!("0x0000000071727De22E5E9d8BAf0edAc6f37da032");

fn funder_key() -> String {
    std::env::var("TEST_FUNDER_PRIVATE_KEY")
        .expect("TEST_FUNDER_PRIVATE_KEY must be set for integration tests")
}

fn bundler_url() -> String {
    std::env::var("BASE_SEPOLIA_RPC_URL")
        .expect("BASE_SEPOLIA_RPC_URL must be set (Pimlico bundler URL)")
}

fn test_state() -> (tempfile::TempDir, StateStore) {
    let tmp = tempfile::tempdir().unwrap();
    let state = StateStore::open_at(tmp.path().join("accounts.json")).unwrap();
    (tmp, state)
}

fn test_impl() -> KeypoAccountImpl {
    KeypoAccountImpl::with_deployment(BASE_SEPOLIA_CHAIN_ID, KEYPO_ACCOUNT_ADDR)
}

fn fund_from_strategy() -> FundingStrategy {
    FundingStrategy::FundFrom {
        funder_private_key: funder_key(),
        amount: SETUP_FUNDING_AMOUNT,
        rpc_url: BASE_SEPOLIA_RPC.to_string(),
    }
}

/// Sets up a fresh account for testing, returns (account, chain_deployment, signer, state_dir).
async fn setup_test_account(
    label: &str,
) -> (
    keypo_wallet::types::AccountRecord,
    keypo_wallet::types::ChainDeployment,
    MockSigner,
    tempfile::TempDir,
) {
    let signer = MockSigner::new();
    let imp = test_impl();
    let (tmp, mut state) = test_state();

    let config = SetupConfig {
        key_label: label.into(),
        key_policy: "open".into(),
        rpc_url: BASE_SEPOLIA_RPC.into(),
        bundler_url: Some(bundler_url()),
        paymaster_url: std::env::var("PAYMASTER_URL").ok(),
        implementation_address: KEYPO_ACCOUNT_ADDR,
        implementation_name: "KeypoAccount".into(),
        chain_id: Some(BASE_SEPOLIA_CHAIN_ID),
    };

    account::setup(&config, &imp, &signer, &mut state, fund_from_strategy())
        .await
        .expect("setup should succeed");

    let (acct, chain) = state
        .find_account(label, BASE_SEPOLIA_CHAIN_ID)
        .expect("account should exist after setup");

    (acct.clone(), chain.clone(), signer, tmp)
}

#[tokio::test]
#[ignore]
async fn test_bundler_connectivity() {
    init_tracing();
    let url = bundler_url();
    let bundler = BundlerClient::new(url, ENTRY_POINT_V07);

    let entry_points = bundler
        .supported_entry_points()
        .await
        .expect("should get entry points");

    assert!(
        entry_points.contains(&ENTRY_POINT_V07),
        "v0.7 EntryPoint should be supported, got: {:?}",
        entry_points
    );
}

#[tokio::test]
#[ignore]
async fn test_query_nonce_fresh_account() {
    init_tracing();
    let (account, _chain, _signer, _tmp) = setup_test_account("nonce-test").await;

    // Query nonce via EntryPoint
    let rpc_url: url::Url = BASE_SEPOLIA_RPC.parse().unwrap();
    let provider = alloy::providers::ProviderBuilder::new().connect_http(rpc_url);

    let nonce = transaction::query_nonce(&provider, account.address, ENTRY_POINT_V07)
        .await
        .expect("nonce query should succeed");

    assert_eq!(nonce, U256::ZERO, "fresh account should have nonce 0");
}

#[tokio::test]
#[ignore]
async fn test_send_eth_self_transfer() {
    init_tracing();
    let (account, mut chain, signer, _tmp) = setup_test_account("send-test").await;
    let imp = test_impl();

    // Fund account with 0.005 ETH for gas (self-funded, no paymaster)
    let fund_amount = U256::from(5_000_000_000_000_000u64);
    {
        use alloy::network::{EthereumWallet, TransactionBuilder};
        use alloy::providers::{Provider, ProviderBuilder};
        use alloy::rpc::types::TransactionRequest;
        use alloy::signers::local::PrivateKeySigner;

        let funder: PrivateKeySigner = funder_key().parse().unwrap();
        let wallet = EthereumWallet::from(funder);
        let url: url::Url = BASE_SEPOLIA_RPC.parse().unwrap();
        let provider = ProviderBuilder::new().wallet(wallet).connect_http(url);

        let tx = TransactionRequest::default()
            .with_to(account.address)
            .with_value(fund_amount);
        let pending = provider.send_transaction(tx).await.expect("fund tx");
        pending.get_receipt().await.expect("fund receipt");
    }

    // Wait for balance to be visible
    tokio::time::sleep(Duration::from_secs(3)).await;

    // Ensure bundler URL is set
    chain.bundler_url = Some(bundler_url());
    // Remove paymaster to force self-funded
    chain.paymaster_url = None;

    // Build a 0-value self-transfer
    let call = Call {
        to: account.address,
        value: U256::ZERO,
        data: Bytes::new(),
    };

    let result = transaction::execute(&account, &chain, &[call], &imp, &signer)
        .await
        .expect("self-transfer should succeed");

    assert!(result.success, "UserOp should succeed");
    println!("Self-transfer succeeded!");
    println!("  UserOp hash: {}", result.user_op_hash);
    println!("  Tx hash:     {}", result.tx_hash);
}

#[tokio::test]
#[ignore]
async fn test_send_with_paymaster() {
    init_tracing();

    if std::env::var("PAYMASTER_URL").is_err() {
        println!("skipping: PAYMASTER_URL not set");
        return;
    }

    let (account, mut chain, signer, _tmp) = setup_test_account("pm-send-test").await;
    let imp = test_impl();

    // Ensure bundler + paymaster URLs are set
    chain.bundler_url = Some(bundler_url());
    chain.paymaster_url = Some(
        std::env::var("PAYMASTER_URL").expect("PAYMASTER_URL"),
    );

    // Build a 0-value self-transfer — gas sponsored by paymaster
    let call = Call {
        to: account.address,
        value: U256::ZERO,
        data: Bytes::new(),
    };

    // Pimlico testnet sponsors without a policy ID
    let result = transaction::execute_with_context(&account, &chain, &[call], &imp, &signer, None)
        .await
        .expect("paymaster-sponsored send should succeed");

    assert!(result.success, "UserOp should succeed");
    println!("Paymaster-sponsored send succeeded!");
    println!("  UserOp hash: {}", result.user_op_hash);
    println!("  Tx hash:     {}", result.tx_hash);
}
