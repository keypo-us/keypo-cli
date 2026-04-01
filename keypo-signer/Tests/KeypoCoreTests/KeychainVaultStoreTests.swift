import XCTest
import Security
@testable import KeypoCore

final class KeychainVaultStoreTests: XCTestCase {
    private var testService: String!
    private var store: KeychainVaultStore!

    override func setUp() {
        super.setUp()
        testService = "com.keypo.vault.test-\(UUID().uuidString)"
        store = KeychainVaultStore(service: testService, accessGroup: nil)
    }

    override func tearDown() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService!,
        ]
        SecItemDelete(query as CFDictionary)
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeTestSecret(name: String = "secret") -> EncryptedSecret {
        EncryptedSecret(
            ephemeralPublicKey: "0x04" + String(repeating: "ab", count: 64),
            nonce: Data("test-nonce-12".utf8).base64EncodedString(),
            ciphertext: Data("encrypted-\(name)".utf8).base64EncodedString(),
            tag: Data("0123456789abcdef".utf8).base64EncodedString(),
            createdAt: Date(timeIntervalSince1970: 1711324800),
            updatedAt: Date(timeIntervalSince1970: 1711324800)
        )
    }

    private func makeTestEntry(
        policy: String = "open",
        secrets: [String: EncryptedSecret]? = nil
    ) -> VaultEntry {
        VaultEntry(
            vaultKeyId: UUID().uuidString,
            dataRepresentation: Data("fake-se-token-\(policy)".utf8).base64EncodedString(),
            publicKey: "0x04" + String(repeating: "cd", count: 64),
            integrityEphemeralPublicKey: "0x04" + String(repeating: "ef", count: 64),
            integrityHmac: Data("fake-hmac-\(policy)".utf8).base64EncodedString(),
            createdAt: Date(timeIntervalSince1970: 1711324800),
            secrets: secrets ?? [:]
        )
    }

    private func makeThreeVaultFile(secrets: [String: EncryptedSecret] = [:]) -> VaultFile {
        VaultFile(version: 2, vaults: [
            "open": makeTestEntry(policy: "open", secrets: secrets),
            "passcode": makeTestEntry(policy: "passcode"),
            "biometric": makeTestEntry(policy: "biometric"),
        ])
    }

    // MARK: - Storage Correctness

    func testSaveAndLoadRoundTripsThreeTiers() throws {
        let file = makeThreeVaultFile()
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.vaults.count, 3)
        XCTAssertNotNil(loaded.vaults["open"])
        XCTAssertNotNil(loaded.vaults["passcode"])
        XCTAssertNotNil(loaded.vaults["biometric"])
    }

    func testSavePreservesSecrets() throws {
        let secrets = ["API_KEY": makeTestSecret(name: "api"), "DB_PASS": makeTestSecret(name: "db"), "TOKEN": makeTestSecret(name: "tok")]
        let file = makeThreeVaultFile(secrets: secrets)
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        let openEntry = loaded.vaults["open"]!
        XCTAssertEqual(openEntry.secrets.count, 3)
        XCTAssertEqual(openEntry.secrets["API_KEY"]!.ciphertext, secrets["API_KEY"]!.ciphertext)
        XCTAssertEqual(openEntry.secrets["DB_PASS"]!.nonce, secrets["DB_PASS"]!.nonce)
        XCTAssertEqual(openEntry.secrets["TOKEN"]!.tag, secrets["TOKEN"]!.tag)
        XCTAssertEqual(openEntry.secrets["API_KEY"]!.ephemeralPublicKey, secrets["API_KEY"]!.ephemeralPublicKey)
    }

    func testSavePreservesDataRepresentation() throws {
        let knownToken = Data("specific-vault-se-token".utf8).base64EncodedString()
        var file = makeThreeVaultFile()
        file.vaults["open"]!.dataRepresentation = knownToken
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.vaults["open"]!.dataRepresentation, knownToken)
    }

    func testSavePreservesIntegrityEnvelope() throws {
        let hmac = Data("known-hmac-value".utf8).base64EncodedString()
        let ephKey = "0x04" + String(repeating: "99", count: 64)
        var file = makeThreeVaultFile()
        file.vaults["open"]!.integrityHmac = hmac
        file.vaults["open"]!.integrityEphemeralPublicKey = ephKey
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.vaults["open"]!.integrityHmac, hmac)
        XCTAssertEqual(loaded.vaults["open"]!.integrityEphemeralPublicKey, ephKey)
    }

    func testSavePreservesDates() throws {
        let specificDate = Date(timeIntervalSince1970: 1711324800)
        var file = makeThreeVaultFile()
        file.vaults["open"]!.createdAt = specificDate
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.vaults["open"]!.createdAt.timeIntervalSince1970, specificDate.timeIntervalSince1970, accuracy: 1.0)
    }

    func testVaultExistsReturnsFalseWhenEmpty() {
        XCTAssertFalse(store.vaultExists())
    }

    func testVaultExistsReturnsTrueAfterSave() throws {
        try store.saveVaultFile(makeThreeVaultFile())
        XCTAssertTrue(store.vaultExists())
    }

    func testDeleteVaultFileRemovesAllTiers() throws {
        try store.saveVaultFile(makeThreeVaultFile())
        XCTAssertTrue(store.vaultExists())

        try store.deleteVaultFile()
        XCTAssertFalse(store.vaultExists())
    }

    func testDeleteThenLoadThrows() throws {
        try store.saveVaultFile(makeThreeVaultFile())
        try store.deleteVaultFile()

        XCTAssertThrowsError(try store.loadVaultFile()) { error in
            guard case VaultError.integrityCheckFailed = error else {
                XCTFail("Expected integrityCheckFailed, got \(error)")
                return
            }
        }
    }

    func testSaveOverwritesExistingEntry() throws {
        let file1 = makeThreeVaultFile()
        try store.saveVaultFile(file1)

        var file2 = file1
        file2.vaults["open"]!.secrets["NEW_SECRET"] = makeTestSecret(name: "new")
        try store.saveVaultFile(file2)

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.vaults["open"]!.secrets.count, 1)
        XCTAssertNotNil(loaded.vaults["open"]!.secrets["NEW_SECRET"])
    }

    func testSaveSingleTierOnly() throws {
        let file = VaultFile(version: 2, vaults: ["open": makeTestEntry(policy: "open")])
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.vaults.count, 1)
        XCTAssertNotNil(loaded.vaults["open"])
    }

    // MARK: - Save Semantics

    func testSaveRemovesStaleTier() throws {
        try store.saveVaultFile(makeThreeVaultFile())
        XCTAssertEqual(try store.loadVaultFile().vaults.count, 3)

        // Save with only 2 tiers — third should be removed
        let twoTierFile = VaultFile(version: 2, vaults: [
            "open": makeTestEntry(policy: "open"),
            "passcode": makeTestEntry(policy: "passcode"),
        ])
        try store.saveVaultFile(twoTierFile)

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.vaults.count, 2)
        XCTAssertNil(loaded.vaults["biometric"])
    }

    func testSaveEmptySecretsMap() throws {
        let file = VaultFile(version: 2, vaults: ["open": makeTestEntry(policy: "open", secrets: [:])])
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        XCTAssertTrue(loaded.vaults["open"]!.secrets.isEmpty)
    }

    // MARK: - Protocol Extension (Shared Lookup)

    func testFindSecretAcrossVaults() throws {
        var file = makeThreeVaultFile()
        file.vaults["biometric"]!.secrets["BIO_SECRET"] = makeTestSecret(name: "bio")
        try store.saveVaultFile(file)

        let result = try store.findSecret(name: "BIO_SECRET")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.policy, .biometric)
    }

    func testFindSecretReturnsNilWhenMissing() throws {
        try store.saveVaultFile(makeThreeVaultFile())
        let result = try store.findSecret(name: "NONEXISTENT")
        XCTAssertNil(result)
    }

    func testAllSecretNamesReturnsSorted() throws {
        var file = makeThreeVaultFile()
        file.vaults["open"]!.secrets["ZEBRA"] = makeTestSecret(name: "z")
        file.vaults["open"]!.secrets["ALPHA"] = makeTestSecret(name: "a")
        file.vaults["passcode"]!.secrets["BETA"] = makeTestSecret(name: "b")
        try store.saveVaultFile(file)

        let names = try store.allSecretNames()
        // passcode secrets first (biometric > passcode > open in iteration order), then open
        let nameList = names.map { $0.name }
        XCTAssertEqual(nameList.count, 3)
        XCTAssert(nameList.contains("ALPHA"))
        XCTAssert(nameList.contains("BETA"))
        XCTAssert(nameList.contains("ZEBRA"))
    }

    func testIsNameGloballyUniqueReturnsFalseWhenExists() throws {
        var file = makeThreeVaultFile()
        file.vaults["open"]!.secrets["EXISTS"] = makeTestSecret(name: "e")
        try store.saveVaultFile(file)

        XCTAssertFalse(try store.isNameGloballyUnique("EXISTS"))
    }

    func testIsNameGloballyUniqueReturnsTrueWhenAbsent() throws {
        try store.saveVaultFile(makeThreeVaultFile())
        XCTAssertTrue(try store.isNameGloballyUnique("ABSENT"))
    }

    // MARK: - Isolation & Edge Cases

    func testDifferentServiceNamesAreIsolated() throws {
        let storeA = KeychainVaultStore(service: testService + "-A", accessGroup: nil)
        let storeB = KeychainVaultStore(service: testService + "-B", accessGroup: nil)

        try storeA.saveVaultFile(makeThreeVaultFile())

        XCTAssertTrue(storeA.vaultExists())
        XCTAssertFalse(storeB.vaultExists())

        // Clean up store A
        let queryA: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService! + "-A",
        ]
        SecItemDelete(queryA as CFDictionary)
    }

    func testLoadEmptyVaultThrows() throws {
        XCTAssertThrowsError(try store.loadVaultFile()) { error in
            guard case VaultError.integrityCheckFailed = error else {
                XCTFail("Expected integrityCheckFailed, got \(error)")
                return
            }
        }
    }

    func testHighestAvailableTierFromKeychainStore() throws {
        try store.saveVaultFile(makeThreeVaultFile())
        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.highestAvailableTier(), .biometric)
    }

    // MARK: - Error Paths

    func testDeleteNonexistentVaultIsNoOp() throws {
        XCTAssertNoThrow(try store.deleteVaultFile())
    }

    func testSaveAndLoadPreservesEmptySecretsWithMetadata() throws {
        var entry = makeTestEntry(policy: "open", secrets: [:])
        entry.vaultKeyId = "specific-id"
        entry.integrityHmac = Data("specific-hmac".utf8).base64EncodedString()
        let file = VaultFile(version: 2, vaults: ["open": entry])
        try store.saveVaultFile(file)

        let loaded = try store.loadVaultFile()
        let loadedEntry = loaded.vaults["open"]!
        XCTAssertEqual(loadedEntry.vaultKeyId, "specific-id")
        XCTAssertEqual(loadedEntry.integrityHmac, entry.integrityHmac)
        XCTAssertTrue(loadedEntry.secrets.isEmpty)
    }

    func testSaveRejectsOversizedTier() throws {
        // Create enough secrets to exceed 50KB
        var secrets: [String: EncryptedSecret] = [:]
        for i in 0..<500 {
            secrets["SECRET_\(i)"] = makeTestSecret(name: "big-\(i)")
        }
        let file = VaultFile(version: 2, vaults: ["open": makeTestEntry(policy: "open", secrets: secrets)])

        XCTAssertThrowsError(try store.saveVaultFile(file)) { error in
            guard case VaultError.serializationFailed(let msg) = error else {
                XCTFail("Expected serializationFailed, got \(error)")
                return
            }
            XCTAssert(msg.contains("size limit"))
        }
    }
}
