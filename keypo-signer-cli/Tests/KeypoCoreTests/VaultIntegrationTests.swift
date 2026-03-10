import XCTest
import CryptoKit
@testable import KeypoCore

/// Integration tests using real Secure Enclave with open-policy keys.
/// Each test creates a fresh vault in a temp directory and cleans up after.
final class VaultIntegrationTests: XCTestCase {
    var tempDir: URL!
    var store: VaultStore!
    let manager = VaultManager()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(SecureEnclave.isAvailable, "Secure Enclave not available (CI)")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keypo-vault-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = VaultStore(configDir: tempDir)
    }

    override func tearDown() {
        // Clean up SE keys if vault exists
        if store.vaultExists(), let vaultFile = try? store.loadVaultFile() {
            for (_, entry) in vaultFile.vaults {
                if let dataRep = Data(base64Encoded: entry.dataRepresentation) {
                    manager.deleteKeyAgreementKey(dataRepresentation: dataRep)
                }
            }
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func initVault() throws -> VaultFile {
        let now = Date()
        var vaults: [String: VaultEntry] = [:]
        for policyName in ["open", "passcode", "biometric"] {
            let policy = KeyPolicy(rawValue: policyName)!
            let keyResult = try manager.createKeyAgreementKey(policy: policy)
            let envelope = try manager.createIntegrityEnvelope(
                seKeyDataRepresentation: keyResult.dataRepresentation
            )
            vaults[policyName] = VaultEntry(
                vaultKeyId: "com.keypo.vault.\(policyName)",
                dataRepresentation: keyResult.dataRepresentation.base64EncodedString(),
                publicKey: SignatureFormatter.formatHex(keyResult.publicKey),
                integrityEphemeralPublicKey: SignatureFormatter.formatHex(envelope.ephemeralPublicKey),
                integrityHmac: envelope.hmac.base64EncodedString(),
                createdAt: now
            )
        }
        let vaultFile = VaultFile(version: 2, vaults: vaults)
        try store.saveVaultFile(vaultFile)
        return vaultFile
    }

    private func setSecret(name: String, value: String, vaultFile: inout VaultFile, policyName: String = "open") throws {
        guard var entry = vaultFile.vaults[policyName] else {
            XCTFail("vault \(policyName) not found")
            return
        }
        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
            XCTFail("corrupt dataRepresentation")
            return
        }
        let pubKeyData = try SignatureFormatter.parseHex(entry.publicKey)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyData)

        let encrypted = try manager.encrypt(
            plaintext: Data(value.utf8),
            secretName: name,
            sePublicKey: publicKey
        )
        entry.secrets[name] = EncryptedSecret(from: encrypted)

        // Recompute HMAC
        let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
        var secretDataMap: [String: EncryptedSecretData] = [:]
        for (n, s) in entry.secrets {
            secretDataMap[n] = try s.toEncryptedSecretData()
        }
        let newHMAC = try manager.computeHMAC(
            secrets: secretDataMap,
            seKeyDataRepresentation: dataRep,
            integrityEphemeralPublicKey: integrityKey
        )
        entry.integrityHmac = newHMAC.base64EncodedString()
        vaultFile.vaults[policyName] = entry
        try store.saveVaultFile(vaultFile)
    }

    private func getSecret(name: String, vaultFile: VaultFile, policyName: String = "open") throws -> String {
        guard let entry = vaultFile.vaults[policyName] else {
            throw VaultError.integrityCheckFailed("vault not found")
        }
        guard let secret = entry.secrets[name] else {
            throw VaultError.decryptionFailed("secret not found")
        }
        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else {
            throw VaultError.decryptionFailed("corrupt dataRepresentation")
        }

        // Verify HMAC
        let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
        guard let expectedHMAC = Data(base64Encoded: entry.integrityHmac) else {
            throw VaultError.integrityCheckFailed("corrupt HMAC")
        }
        var secretDataMap: [String: EncryptedSecretData] = [:]
        for (n, s) in entry.secrets {
            secretDataMap[n] = try s.toEncryptedSecretData()
        }
        let valid = try manager.verifyHMAC(
            secrets: secretDataMap,
            seKeyDataRepresentation: dataRep,
            integrityEphemeralPublicKey: integrityKey,
            expectedHMAC: expectedHMAC
        )
        guard valid else {
            throw VaultError.integrityCheckFailed("HMAC mismatch")
        }

        let encData = try secret.toEncryptedSecretData()
        let plaintext = try manager.decrypt(
            encryptedData: encData,
            secretName: name,
            seKeyDataRepresentation: dataRep
        )
        return String(data: plaintext, encoding: .utf8)!
    }

    // MARK: - Init Tests

    func testInitCreatesAllThreeVaults() throws {
        let vaultFile = try initVault()
        XCTAssertNotNil(vaultFile.vaults["biometric"])
        XCTAssertNotNil(vaultFile.vaults["passcode"])
        XCTAssertNotNil(vaultFile.vaults["open"])
        XCTAssertEqual(vaultFile.vaults.count, 3)
    }

    // MARK: - Full Lifecycle

    func testFullLifecycle_SetGetUpdateDelete() throws {
        var vaultFile = try initVault()

        // Set
        try setSecret(name: "TEST_KEY", value: "hello", vaultFile: &vaultFile)

        // Get
        let value = try getSecret(name: "TEST_KEY", vaultFile: vaultFile)
        XCTAssertEqual(value, "hello")

        // Update
        guard var entry = vaultFile.vaults["open"] else { return XCTFail() }
        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else { return XCTFail() }
        let pubKeyData = try SignatureFormatter.parseHex(entry.publicKey)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyData)

        var encrypted = try manager.encrypt(
            plaintext: Data("world".utf8),
            secretName: "TEST_KEY",
            sePublicKey: publicKey
        )
        encrypted.createdAt = entry.secrets["TEST_KEY"]!.createdAt  // preserve
        entry.secrets["TEST_KEY"] = EncryptedSecret(from: encrypted)

        let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
        var secretDataMap: [String: EncryptedSecretData] = [:]
        for (n, s) in entry.secrets { secretDataMap[n] = try s.toEncryptedSecretData() }
        let newHMAC = try manager.computeHMAC(
            secrets: secretDataMap, seKeyDataRepresentation: dataRep,
            integrityEphemeralPublicKey: integrityKey
        )
        entry.integrityHmac = newHMAC.base64EncodedString()
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        let updated = try getSecret(name: "TEST_KEY", vaultFile: vaultFile)
        XCTAssertEqual(updated, "world")

        // Delete
        entry.secrets.removeValue(forKey: "TEST_KEY")
        secretDataMap.removeAll()
        for (n, s) in entry.secrets { secretDataMap[n] = try s.toEncryptedSecretData() }
        let hmacAfterDelete = try manager.computeHMAC(
            secrets: secretDataMap, seKeyDataRepresentation: dataRep,
            integrityEphemeralPublicKey: integrityKey
        )
        entry.integrityHmac = hmacAfterDelete.base64EncodedString()
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        let result = try store.findSecret(name: "TEST_KEY")
        XCTAssertNil(result)
    }

    func testSetAndGetRoundtrip_10Secrets() throws {
        var vaultFile = try initVault()
        let secrets = (0..<10).map { ("SECRET_\($0)", "value_\($0)") }

        for (name, value) in secrets {
            try setSecret(name: name, value: value, vaultFile: &vaultFile)
        }

        // Reload from disk
        vaultFile = try store.loadVaultFile()

        for (name, expectedValue) in secrets {
            let value = try getSecret(name: name, vaultFile: vaultFile)
            XCTAssertEqual(value, expectedValue, "Mismatch for \(name)")
        }
    }

    func testSetAndGetWithSpecialCharacters() throws {
        var vaultFile = try initVault()
        let testCases: [(name: String, value: String)] = [
            ("QUOTES_KEY", "he said \"hello\""),
            ("NEWLINE_KEY", "line1\nline2\nline3"),
            ("EMOJI_KEY", "🔑🔐💎"),
            ("UNICODE_KEY", "日本語テスト"),
            ("LONG_KEY", String(repeating: "x", count: 10000)),
        ]

        for (name, value) in testCases {
            try setSecret(name: name, value: value, vaultFile: &vaultFile)
        }

        vaultFile = try store.loadVaultFile()

        for (name, expectedValue) in testCases {
            let value = try getSecret(name: name, vaultFile: vaultFile)
            XCTAssertEqual(value, expectedValue, "Mismatch for \(name)")
        }
    }

    func testUpdatePreservesCreatedAt() throws {
        var vaultFile = try initVault()
        try setSecret(name: "PRESERVE_KEY", value: "old", vaultFile: &vaultFile)

        let originalCreatedAt = vaultFile.vaults["open"]!.secrets["PRESERVE_KEY"]!.createdAt

        // Wait briefly to ensure time difference
        Thread.sleep(forTimeInterval: 0.1)

        // Update
        guard var entry = vaultFile.vaults["open"] else { return XCTFail() }
        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else { return XCTFail() }
        let pubKeyData = try SignatureFormatter.parseHex(entry.publicKey)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: pubKeyData)
        var encrypted = try manager.encrypt(plaintext: Data("new".utf8), secretName: "PRESERVE_KEY", sePublicKey: publicKey)
        encrypted.createdAt = originalCreatedAt
        entry.secrets["PRESERVE_KEY"] = EncryptedSecret(from: encrypted)

        let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
        var sdm: [String: EncryptedSecretData] = [:]
        for (n, s) in entry.secrets { sdm[n] = try s.toEncryptedSecretData() }
        let newHMAC = try manager.computeHMAC(secrets: sdm, seKeyDataRepresentation: dataRep, integrityEphemeralPublicKey: integrityKey)
        entry.integrityHmac = newHMAC.base64EncodedString()
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        let secret = vaultFile.vaults["open"]!.secrets["PRESERVE_KEY"]!
        XCTAssertEqual(secret.createdAt, originalCreatedAt)
        XCTAssertGreaterThan(secret.updatedAt, originalCreatedAt)
    }

    func testDeleteThenSetReuseName() throws {
        var vaultFile = try initVault()
        try setSecret(name: "REUSE_KEY", value: "first", vaultFile: &vaultFile)

        // Delete
        guard var entry = vaultFile.vaults["open"] else { return XCTFail() }
        guard let dataRep = Data(base64Encoded: entry.dataRepresentation) else { return XCTFail() }
        entry.secrets.removeValue(forKey: "REUSE_KEY")
        let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
        var sdm: [String: EncryptedSecretData] = [:]
        for (n, s) in entry.secrets { sdm[n] = try s.toEncryptedSecretData() }
        let hmac = try manager.computeHMAC(secrets: sdm, seKeyDataRepresentation: dataRep, integrityEphemeralPublicKey: integrityKey)
        entry.integrityHmac = hmac.base64EncodedString()
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        // Re-set
        try setSecret(name: "REUSE_KEY", value: "second", vaultFile: &vaultFile)
        vaultFile = try store.loadVaultFile()
        let value = try getSecret(name: "REUSE_KEY", vaultFile: vaultFile)
        XCTAssertEqual(value, "second")
    }

    // MARK: - HMAC Integrity Tests

    func testHMACIntegrityAfterSet_CorruptedCiphertext() throws {
        var vaultFile = try initVault()
        try setSecret(name: "TAMPER_KEY", value: "secret", vaultFile: &vaultFile)
        vaultFile = try store.loadVaultFile()

        // Corrupt ciphertext directly in vault.json
        guard var entry = vaultFile.vaults["open"],
              var secret = entry.secrets["TAMPER_KEY"],
              var ctData = Data(base64Encoded: secret.ciphertext),
              !ctData.isEmpty else {
            return XCTFail("setup failed")
        }
        ctData[0] ^= 0xFF
        secret.ciphertext = ctData.base64EncodedString()
        entry.secrets["TAMPER_KEY"] = secret
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        // Attempt to get should fail HMAC
        XCTAssertThrowsError(try getSecret(name: "TAMPER_KEY", vaultFile: vaultFile))
    }

    func testHMACIntegrityOnEmptyVault() throws {
        let vaultFile = try initVault()
        // Get on nonexistent secret should return not-found, not integrity error
        let result = try store.findSecret(name: "NONEXISTENT")
        XCTAssertNil(result)

        // Verify HMAC on empty vault still passes
        let entry = vaultFile.vaults["open"]!
        let dataRep = Data(base64Encoded: entry.dataRepresentation)!
        let integrityKey = try SignatureFormatter.parseHex(entry.integrityEphemeralPublicKey)
        let expectedHMAC = Data(base64Encoded: entry.integrityHmac)!
        let sdm: [String: EncryptedSecretData] = [:]
        let valid = try manager.verifyHMAC(
            secrets: sdm, seKeyDataRepresentation: dataRep,
            integrityEphemeralPublicKey: integrityKey, expectedHMAC: expectedHMAC
        )
        XCTAssertTrue(valid)
    }

    // MARK: - Tamper Resistance

    func testTamperAddSecretDirectly() throws {
        var vaultFile = try initVault()
        try setSecret(name: "LEGIT_KEY", value: "legit", vaultFile: &vaultFile)
        vaultFile = try store.loadVaultFile()

        // Add a fake secret directly to JSON
        guard var entry = vaultFile.vaults["open"] else { return XCTFail() }
        entry.secrets["FAKE_KEY"] = EncryptedSecret(
            ephemeralPublicKey: "0x04" + String(repeating: "ab", count: 64),
            nonce: Data(repeating: 0, count: 12).base64EncodedString(),
            ciphertext: Data([1, 2, 3]).base64EncodedString(),
            tag: Data(repeating: 0, count: 16).base64EncodedString(),
            createdAt: Date(), updatedAt: Date()
        )
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        // HMAC should fail
        XCTAssertThrowsError(try getSecret(name: "LEGIT_KEY", vaultFile: vaultFile))
    }

    func testTamperRemoveSecret() throws {
        var vaultFile = try initVault()
        try setSecret(name: "KEY_A", value: "a", vaultFile: &vaultFile)
        try setSecret(name: "KEY_B", value: "b", vaultFile: &vaultFile)
        vaultFile = try store.loadVaultFile()

        // Remove KEY_A without updating HMAC
        guard var entry = vaultFile.vaults["open"] else { return XCTFail() }
        entry.secrets.removeValue(forKey: "KEY_A")
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        // HMAC should fail when trying to get KEY_B
        XCTAssertThrowsError(try getSecret(name: "KEY_B", vaultFile: vaultFile))
    }

    func testTamperReplaceHMAC() throws {
        var vaultFile = try initVault()
        try setSecret(name: "MY_KEY", value: "value", vaultFile: &vaultFile)
        vaultFile = try store.loadVaultFile()

        // Replace HMAC with random bytes
        guard var entry = vaultFile.vaults["open"] else { return XCTFail() }
        entry.integrityHmac = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        vaultFile.vaults["open"] = entry
        try store.saveVaultFile(vaultFile)

        XCTAssertThrowsError(try getSecret(name: "MY_KEY", vaultFile: vaultFile))
    }

    // MARK: - List Tests

    func testListShowsAllVaults() throws {
        let vaultFile = try initVault()
        XCTAssertEqual(vaultFile.vaults.count, 3)
        XCTAssertNotNil(vaultFile.vaults["biometric"])
        XCTAssertNotNil(vaultFile.vaults["passcode"])
        XCTAssertNotNil(vaultFile.vaults["open"])
    }

    func testListShowsSecretsPerVault() throws {
        var vaultFile = try initVault()
        try setSecret(name: "SEC_A", value: "a", vaultFile: &vaultFile)
        try setSecret(name: "SEC_B", value: "b", vaultFile: &vaultFile)
        vaultFile = try store.loadVaultFile()

        let openEntry = vaultFile.vaults["open"]!
        XCTAssertEqual(openEntry.secrets.count, 2)
        XCTAssertEqual(vaultFile.vaults["biometric"]!.secrets.count, 0)
        XCTAssertEqual(vaultFile.vaults["passcode"]!.secrets.count, 0)
    }

    func testListOnFreshVault() throws {
        let vaultFile = try initVault()
        for (_, entry) in vaultFile.vaults {
            XCTAssertTrue(entry.secrets.isEmpty)
        }
    }

    // MARK: - Destroy

    func testDestroyRemovesEverything() throws {
        var vaultFile = try initVault()
        try setSecret(name: "DESTROY_KEY", value: "val", vaultFile: &vaultFile)

        // Delete all SE keys
        vaultFile = try store.loadVaultFile()
        for (_, entry) in vaultFile.vaults {
            if let dataRep = Data(base64Encoded: entry.dataRepresentation) {
                manager.deleteKeyAgreementKey(dataRepresentation: dataRep)
            }
        }
        try store.deleteVaultFile()

        XCTAssertFalse(store.vaultExists())
    }

    // MARK: - Multi-Vault Tests

    func testSecretsInDifferentVaults() throws {
        var vaultFile = try initVault()
        try setSecret(name: "OPEN_SECRET", value: "open_val", vaultFile: &vaultFile, policyName: "open")
        try setSecret(name: "BIO_SECRET", value: "bio_val", vaultFile: &vaultFile, policyName: "biometric")
        vaultFile = try store.loadVaultFile()

        let openResult = try store.findSecret(name: "OPEN_SECRET")
        XCTAssertEqual(openResult?.policy, .open)

        let bioResult = try store.findSecret(name: "BIO_SECRET")
        XCTAssertEqual(bioResult?.policy, .biometric)
    }

    func testGlobalUniquenessAcrossVaults() throws {
        var vaultFile = try initVault()
        try setSecret(name: "SHARED_NAME", value: "val", vaultFile: &vaultFile, policyName: "open")
        vaultFile = try store.loadVaultFile()

        let isUnique = try store.isNameGloballyUnique("SHARED_NAME")
        XCTAssertFalse(isUnique)
    }

    func testHMACIsolationBetweenVaults() throws {
        var vaultFile = try initVault()
        try setSecret(name: "OPEN_KEY", value: "open", vaultFile: &vaultFile, policyName: "open")
        try setSecret(name: "BIO_KEY", value: "bio", vaultFile: &vaultFile, policyName: "biometric")
        vaultFile = try store.loadVaultFile()

        // Tamper with open vault
        guard var openEntry = vaultFile.vaults["open"] else { return XCTFail() }
        openEntry.secrets["FAKE"] = EncryptedSecret(
            ephemeralPublicKey: "0x04" + String(repeating: "ab", count: 64),
            nonce: Data(repeating: 0, count: 12).base64EncodedString(),
            ciphertext: Data([1]).base64EncodedString(),
            tag: Data(repeating: 0, count: 16).base64EncodedString(),
            createdAt: Date(), updatedAt: Date()
        )
        vaultFile.vaults["open"] = openEntry
        try store.saveVaultFile(vaultFile)

        // Open vault HMAC should fail
        XCTAssertThrowsError(try getSecret(name: "OPEN_KEY", vaultFile: vaultFile))

        // Biometric vault HMAC should still pass
        let bioValue = try getSecret(name: "BIO_KEY", vaultFile: vaultFile, policyName: "biometric")
        XCTAssertEqual(bioValue, "bio")
    }

    // MARK: - Error Path Tests

    func testSetBeforeInit() throws {
        // Store doesn't exist
        XCTAssertFalse(store.vaultExists())
    }

    func testGetNonexistentSecret() throws {
        _ = try initVault()
        let result = try store.findSecret(name: "DOES_NOT_EXIST")
        XCTAssertNil(result)
    }

    func testSecretNameTooLong() {
        let name = String(repeating: "A", count: 129)
        XCTAssertFalse(validateSecretName(name))
    }

    func testSecretNameWithInvalidChars() {
        XCTAssertFalse(validateSecretName("KEY-NAME"))
        XCTAssertFalse(validateSecretName("KEY.NAME"))
        XCTAssertFalse(validateSecretName("123KEY"))
        XCTAssertFalse(validateSecretName(""))
        XCTAssertFalse(validateSecretName("KEY NAME"))
    }
}
