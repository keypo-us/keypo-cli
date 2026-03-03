//! Integration tests for the balance query flow.
//!
//! All tests are `#[ignore]` because they require:
//! - `TEST_FUNDER_PRIVATE_KEY` env var (funded on Base Sepolia)
//! - Network access to Base Sepolia
//!
//! Run with: `cargo test --test integration_balance -- --ignored --test-threads=1`

use std::sync::Once;

use alloy::primitives::{address, Address};
use alloy::providers::ProviderBuilder;

static INIT_TRACING: Once = Once::new();
fn init_tracing() {
    INIT_TRACING.call_once(|| {
        tracing_subscriber::fmt().with_test_writer().try_init().ok();
    });
}

use keypo_wallet::account::{self, FundingStrategy, SetupConfig, SETUP_FUNDING_AMOUNT};
use keypo_wallet::impls::KeypoAccountImpl;
use keypo_wallet::query;
use keypo_wallet::signer::mock::MockSigner;
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
    let path = tmp.path().join("accounts.json");
    let store = StateStore::open_at(path).unwrap();
    (tmp, store)
}

fn setup_config(label: &str) -> SetupConfig {
    SetupConfig {
        key_label: label.to_string(),
        key_policy: "open".to_string(),
        rpc_url: BASE_SEPOLIA_RPC.to_string(),
        bundler_url: None,
        paymaster_url: None,
        implementation_address: KEYPO_ACCOUNT_ADDR,
        implementation_name: "KeypoAccount".to_string(),
        chain_id: Some(BASE_SEPOLIA_CHAIN_ID),
    }
}

#[tokio::test]
#[ignore]
async fn test_balance_native_after_setup() {
    init_tracing();

    let (_tmp, mut state) = test_state();
    let signer = MockSigner::new();
    let imp = KeypoAccountImpl::new();

    let config = setup_config("balance-test-key");
    let funding = FundingStrategy::FundFrom {
        funder_private_key: funder_key(),
        amount: SETUP_FUNDING_AMOUNT,
        rpc_url: BASE_SEPOLIA_RPC.to_string(),
    };

    let result = account::setup(&config, &imp, &signer, &mut state, funding)
        .await
        .expect("setup should succeed");

    // Query native balance
    let url: url::Url = BASE_SEPOLIA_RPC.parse().unwrap();
    let provider = ProviderBuilder::new().connect_http(url);

    let balance = query::query_native_balance(&provider, result.account_address)
        .await
        .expect("balance query should succeed");

    // After setup, balance should be > 0 (funded)
    assert!(
        !balance.is_zero(),
        "balance should be > 0 after setup funding"
    );
}

#[tokio::test]
#[ignore]
async fn test_info_after_setup() {
    init_tracing();

    let (_tmp, mut state) = test_state();
    let signer = MockSigner::new();
    let imp = KeypoAccountImpl::new();

    let config = setup_config("info-test-key");
    let funding = FundingStrategy::FundFrom {
        funder_private_key: funder_key(),
        amount: SETUP_FUNDING_AMOUNT,
        rpc_url: BASE_SEPOLIA_RPC.to_string(),
    };

    let result = account::setup(&config, &imp, &signer, &mut state, funding)
        .await
        .expect("setup should succeed");

    let account = state
        .find_accounts_for_key("info-test-key")
        .expect("account should exist after setup");

    let info = query::format_info(account, None);
    assert!(info.contains(&format!("{}", result.account_address)[..6]));
    assert!(info.contains("84532"));
}
