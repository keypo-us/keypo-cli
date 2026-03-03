//! Integration tests for the account setup flow.
//!
//! All tests are `#[ignore]` because they require:
//! - `TEST_FUNDER_PRIVATE_KEY` env var (funded on Base Sepolia)
//! - Network access to Base Sepolia
//!
//! Run with: `cargo test -- --ignored`

use std::sync::Once;
use std::time::Duration;

use alloy::primitives::{address, Address};

static INIT_TRACING: Once = Once::new();
fn init_tracing() {
    INIT_TRACING.call_once(|| {
        tracing_subscriber::fmt().with_test_writer().try_init().ok();
    });
}
use keypo_wallet::account::{self, FundingStrategy, SetupConfig, SETUP_FUNDING_AMOUNT};
use keypo_wallet::impls::KeypoAccountImpl;
use keypo_wallet::signer::mock::MockSigner;
use keypo_wallet::signer::P256Signer;
use keypo_wallet::state::StateStore;

const KEYPO_ACCOUNT_ADDR: Address = address!("0x6d1566f9aAcf9c06969D7BF846FA090703A38E43");
const BASE_SEPOLIA_RPC: &str = "https://sepolia.base.org";
const BASE_SEPOLIA_CHAIN_ID: u64 = 84532;

fn funder_key() -> String {
    std::env::var("TEST_FUNDER_PRIVATE_KEY")
        .expect("TEST_FUNDER_PRIVATE_KEY must be set for integration tests")
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

#[tokio::test]
#[ignore]
async fn test_setup_full_flow() {
    init_tracing();
    let signer = MockSigner::new();
    let imp = test_impl();
    let (_tmp, mut state) = test_state();

    let config = SetupConfig {
        key_label: "integration-test".into(),
        key_policy: "open".into(),
        rpc_url: BASE_SEPOLIA_RPC.into(),
        bundler_url: None,
        paymaster_url: None,
        implementation_address: KEYPO_ACCOUNT_ADDR,
        implementation_name: "KeypoAccount".into(),
        chain_id: Some(BASE_SEPOLIA_CHAIN_ID),
    };

    let result = account::setup(&config, &imp, &signer, &mut state, fund_from_strategy())
        .await
        .expect("setup should succeed");

    // Verify result fields
    assert_ne!(result.account_address, Address::ZERO);
    assert_eq!(result.chain_id, BASE_SEPOLIA_CHAIN_ID);

    // Verify state was persisted
    let (acct, chain) = state
        .find_account("integration-test", BASE_SEPOLIA_CHAIN_ID)
        .expect("account should be in state");
    assert_eq!(acct.address, result.account_address);
    assert_eq!(acct.key_label, "integration-test");
    assert_eq!(chain.implementation, KEYPO_ACCOUNT_ADDR);

    // Verify delegation on-chain
    use alloy::providers::{Provider, ProviderBuilder};
    let url: url::Url = BASE_SEPOLIA_RPC.parse().unwrap();
    let provider = ProviderBuilder::new().connect_http(url);
    let code = provider
        .get_code_at(result.account_address)
        .await
        .expect("should get code");
    assert!(
        code.len() >= 23,
        "delegated EOA should have code (got {} bytes)",
        code.len()
    );
    assert_eq!(code[0], 0xef);
    assert_eq!(code[1], 0x01);
    assert_eq!(code[2], 0x00);
}

#[tokio::test]
#[ignore]
async fn test_setup_duplicate_fails() {
    init_tracing();
    let signer = MockSigner::new();
    let imp = test_impl();
    let (_tmp, mut state) = test_state();

    let config = SetupConfig {
        key_label: "dup-test".into(),
        key_policy: "open".into(),
        rpc_url: BASE_SEPOLIA_RPC.into(),
        bundler_url: None,
        paymaster_url: None,
        implementation_address: KEYPO_ACCOUNT_ADDR,
        implementation_name: "KeypoAccount".into(),
        chain_id: Some(BASE_SEPOLIA_CHAIN_ID),
    };

    // First setup should succeed
    account::setup(&config, &imp, &signer, &mut state, fund_from_strategy())
        .await
        .expect("first setup should succeed");

    // Second setup with same key + chain should fail
    let result = account::setup(&config, &imp, &signer, &mut state, fund_from_strategy()).await;
    assert!(
        result.is_err(),
        "duplicate setup should fail, got: {:?}",
        result
    );
    let err = result.unwrap_err();
    assert!(
        err.to_string().contains("already deployed")
            || err.to_string().contains("already has an account"),
        "expected duplicate/multi-chain error, got: {err}"
    );
}

#[tokio::test]
#[ignore]
async fn test_setup_bad_implementation() {
    init_tracing();
    let signer = MockSigner::new();
    let bad_addr = address!("0x0000000000000000000000000000000000000001");
    let imp = KeypoAccountImpl::with_deployment(BASE_SEPOLIA_CHAIN_ID, bad_addr);
    let (_tmp, mut state) = test_state();

    let config = SetupConfig {
        key_label: "bad-impl-test".into(),
        key_policy: "open".into(),
        rpc_url: BASE_SEPOLIA_RPC.into(),
        bundler_url: None,
        paymaster_url: None,
        implementation_address: bad_addr,
        implementation_name: "KeypoAccount".into(),
        chain_id: Some(BASE_SEPOLIA_CHAIN_ID),
    };

    let funding = FundingStrategy::WaitForFunding {
        poll_interval: Duration::from_millis(100),
        max_wait: Duration::from_millis(100),
    };

    let result = account::setup(&config, &imp, &signer, &mut state, funding).await;
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(
        err.to_string().contains("not deployed"),
        "expected ImplementationNotDeployed, got: {err}"
    );
}

#[tokio::test]
#[ignore]
async fn test_setup_with_deterministic_key() {
    init_tracing();
    let signer = MockSigner::new();
    let seed = [0x42u8; 32];
    signer.add_deterministic_key("det-test", "open", &seed);

    let imp = test_impl();
    let (_tmp, mut state) = test_state();

    let config = SetupConfig {
        key_label: "det-test".into(),
        key_policy: "open".into(),
        rpc_url: BASE_SEPOLIA_RPC.into(),
        bundler_url: None,
        paymaster_url: None,
        implementation_address: KEYPO_ACCOUNT_ADDR,
        implementation_name: "KeypoAccount".into(),
        chain_id: Some(BASE_SEPOLIA_CHAIN_ID),
    };

    let result = account::setup(&config, &imp, &signer, &mut state, fund_from_strategy())
        .await
        .expect("setup with deterministic key should succeed");

    // The public key in the result should match the deterministic key
    let expected_pk = signer.get_public_key("det-test").unwrap();
    assert_eq!(result.public_key, expected_pk);
    assert_eq!(result.chain_id, BASE_SEPOLIA_CHAIN_ID);
}
