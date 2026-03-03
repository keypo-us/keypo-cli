use alloy::primitives::{Address, Bytes, B256, U256};
use alloy::sol_types::SolCall;
use alloy::sol_types::SolValue;

use keypo_wallet::impls::KeypoAccountImpl;
use keypo_wallet::signer::mock::MockSigner;
use keypo_wallet::signer::P256Signer;
use keypo_wallet::state::StateStore;
use keypo_wallet::traits::AccountImplementation;
use keypo_wallet::types::Call;
use keypo_wallet::types::{ChainDeployment, P256PublicKey};

alloy::sol! {
    function initialize(bytes32 qx, bytes32 qy);
    function execute(bytes32 mode, bytes executionData);
    struct Execution { address target; uint256 value; bytes callData; }
}

#[test]
fn keypo_account_encode_decode_roundtrip() {
    let imp = KeypoAccountImpl::new();

    // Test initialize roundtrip
    let qx = B256::repeat_byte(0xAA);
    let qy = B256::repeat_byte(0xBB);
    let init_encoded = imp.encode_initialize(qx, qy);
    let init_decoded = initializeCall::abi_decode(&init_encoded).unwrap();
    assert_eq!(init_decoded.qx, qx);
    assert_eq!(init_decoded.qy, qy);

    // Test execute roundtrip
    let calls = vec![
        Call {
            to: Address::repeat_byte(0x11),
            value: U256::from(100u64),
            data: Bytes::from(vec![0xAB, 0xCD]),
        },
        Call {
            to: Address::repeat_byte(0x22),
            value: U256::ZERO,
            data: Bytes::new(),
        },
    ];
    let exec_encoded = imp.encode_execute(&calls);
    let exec_decoded = executeCall::abi_decode(&exec_encoded).unwrap();

    let executions = Vec::<Execution>::abi_decode(&exec_decoded.executionData).unwrap();
    assert_eq!(executions.len(), 2);
    assert_eq!(executions[0].target, Address::repeat_byte(0x11));
    assert_eq!(executions[0].value, U256::from(100u64));
    assert_eq!(executions[1].target, Address::repeat_byte(0x22));
    assert_eq!(executions[1].value, U256::ZERO);
}

#[test]
fn state_store_full_lifecycle() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("accounts.json");

    // Open fresh store
    let mut store = StateStore::open_at(path.clone()).unwrap();
    assert!(store.list_accounts().is_empty());

    let addr = alloy::primitives::address!("0x1111111111111111111111111111111111111111");
    let pubkey = P256PublicKey {
        qx: B256::repeat_byte(0x11),
        qy: B256::repeat_byte(0x22),
    };

    // Add first deployment
    let deployment1 = ChainDeployment {
        chain_id: 84532,
        implementation: alloy::primitives::address!("0x6d1566f9aAcf9c06969D7BF846FA090703A38E43"),
        implementation_name: "KeypoAccount".into(),
        entry_point: alloy::primitives::address!("0x0000000071727De22E5E9d8BAf0edAc6f37da032"),
        bundler_url: Some("https://bundler.example.com".into()),
        paymaster_url: None,
        rpc_url: "https://sepolia.base.org".into(),
        deployed_at: "2026-03-01T00:00:00Z".into(),
    };
    store
        .add_chain_deployment("test-key", "biometric", addr, pubkey.clone(), deployment1)
        .unwrap();

    // Add second chain
    let deployment2 = ChainDeployment {
        chain_id: 1,
        implementation: alloy::primitives::address!("0x6d1566f9aAcf9c06969D7BF846FA090703A38E43"),
        implementation_name: "KeypoAccount".into(),
        entry_point: alloy::primitives::address!("0x0000000071727De22E5E9d8BAf0edAc6f37da032"),
        bundler_url: Some("https://bundler-mainnet.example.com".into()),
        paymaster_url: Some("https://paymaster.example.com".into()),
        rpc_url: "https://eth.example.com".into(),
        deployed_at: "2026-03-02T00:00:00Z".into(),
    };
    store
        .add_chain_deployment("test-key", "biometric", addr, pubkey, deployment2)
        .unwrap();

    assert_eq!(store.list_accounts().len(), 1);
    assert_eq!(store.list_accounts()[0].chains.len(), 2);

    // Save and reload
    store.save().unwrap();
    let reloaded = StateStore::open_at(path).unwrap();
    assert_eq!(reloaded.list_accounts().len(), 1);
    assert_eq!(reloaded.list_accounts()[0].chains.len(), 2);

    let (acct, chain) = reloaded.find_account("test-key", 84532).unwrap();
    assert_eq!(acct.key_label, "test-key");
    assert_eq!(chain.chain_id, 84532);

    let (_, chain_mainnet) = reloaded.find_account("test-key", 1).unwrap();
    assert_eq!(chain_mainnet.chain_id, 1);
}

#[test]
fn mock_signer_create_sign_encode() {
    let signer = MockSigner::new();
    let imp = KeypoAccountImpl::new();

    // Create a key
    let pk = signer.create_key("integration-test", "open").unwrap();
    assert_ne!(pk.qx, B256::ZERO);
    assert_ne!(pk.qy, B256::ZERO);

    // Verify we can retrieve the same key
    let pk2 = signer.get_public_key("integration-test").unwrap();
    assert_eq!(pk, pk2);

    // Sign a digest
    let digest = [0x42u8; 32];
    let sig = signer.sign(&digest, "integration-test").unwrap();

    // Encode the signature via KeypoAccountImpl
    let encoded = imp.encode_signature(sig.r, sig.s);
    assert_eq!(encoded.len(), 64);
    assert_eq!(&encoded[..32], sig.r.as_slice());
    assert_eq!(&encoded[32..], sig.s.as_slice());
}
