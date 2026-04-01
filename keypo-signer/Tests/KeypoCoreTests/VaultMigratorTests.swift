import XCTest
import Security
@testable import KeypoCore

final class VaultMigratorTests: XCTestCase {
    private var tempDir: URL!
    private var fileStore: VaultStore!
    private var testService: String!
    private var keychainStore: KeychainVaultStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("keypo-vmigrate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultStore(configDir: tempDir)
        testService = "com.keypo.vault.migrate-\(UUID().uuidString)"
        keychainStore = KeychainVaultStore(configDir: tempDir, service: testService, accessGroup: nil)
    }

    override func tearDown() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService!,
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTestSecret(name: String = "secret") -> EncryptedSecret {
        EncryptedSecret(
            ephemeralPublicKey: "0x04" + String(repeating: "ab", count: 64),
            nonce: Data("nonce-\(name)".utf8).base64EncodedString(),
            ciphertext: Data("cipher-\(name)".utf8).base64EncodedString(),
            tag: Data("tag-\(name)-padded".utf8).base64EncodedString(),
            createdAt: Date(timeIntervalSince1970: 1711324800),
            updatedAt: Date(timeIntervalSince1970: 1711324800)
        )
    }

    private func makeTestEntry(policy: String, secrets: [String: EncryptedSecret] = [:]) -> VaultEntry {
        VaultEntry(
            vaultKeyId: UUID().uuidString,
            dataRepresentation: Data("token-\(policy)".utf8).base64EncodedString(),
            publicKey: "0x04" + String(repeating: "cd", count: 64),
            integrityEphemeralPublicKey: "0x04" + String(repeating: "ef", count: 64),
            integrityHmac: Data("hmac-\(policy)".utf8).base64EncodedString(),
            createdAt: Date(timeIntervalSince1970: 1711324800),
            secrets: secrets
        )
    }

    private func makeThreeVaultFile(secrets: [String: EncryptedSecret] = [:]) -> VaultFile {
        VaultFile(version: 2, vaults: [
            "open": makeTestEntry(policy: "open", secrets: secrets),
            "passcode": makeTestEntry(policy: "passcode"),
            "biometric": makeTestEntry(policy: "biometric"),
        ])
    }

    private func saveFileStoreVault(_ file: VaultFile) throws {
        try fileStore.saveVaultFile(file)
    }

    // MARK: - Migration Correctness

    func testMigrateMovesAllTiersToKeychain() throws {
        try saveFileStoreVault(makeThreeVaultFile())

        let count = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 3)

        let loaded = try keychainStore.loadVaultFile()
        XCTAssertEqual(loaded.vaults.count, 3)
        XCTAssertNotNil(loaded.vaults["open"])
        XCTAssertNotNil(loaded.vaults["passcode"])
        XCTAssertNotNil(loaded.vaults["biometric"])
    }

    func testMigratePreservesSecrets() throws {
        let secrets = ["API_KEY": makeTestSecret(name: "api"), "DB_PASS": makeTestSecret(name: "db")]
        try saveFileStoreVault(makeThreeVaultFile(secrets: secrets))

        _ = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)

        let loaded = try keychainStore.loadVaultFile()
        let openSecrets = loaded.vaults["open"]!.secrets
        XCTAssertEqual(openSecrets.count, 2)
        XCTAssertEqual(openSecrets["API_KEY"]!.ciphertext, secrets["API_KEY"]!.ciphertext)
        XCTAssertEqual(openSecrets["DB_PASS"]!.nonce, secrets["DB_PASS"]!.nonce)
    }

    func testMigratePreservesDataRepresentation() throws {
        var file = makeThreeVaultFile()
        let knownToken = Data("known-vault-se-token".utf8).base64EncodedString()
        file.vaults["open"]!.dataRepresentation = knownToken
        try saveFileStoreVault(file)

        _ = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)

        let loaded = try keychainStore.loadVaultFile()
        XCTAssertEqual(loaded.vaults["open"]!.dataRepresentation, knownToken)
    }

    func testMigratePreservesIntegrityEnvelope() throws {
        var file = makeThreeVaultFile()
        let hmac = Data("specific-integrity-hmac".utf8).base64EncodedString()
        let ephKey = "0x04" + String(repeating: "77", count: 64)
        file.vaults["passcode"]!.integrityHmac = hmac
        file.vaults["passcode"]!.integrityEphemeralPublicKey = ephKey
        try saveFileStoreVault(file)

        _ = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)

        let loaded = try keychainStore.loadVaultFile()
        XCTAssertEqual(loaded.vaults["passcode"]!.integrityHmac, hmac)
        XCTAssertEqual(loaded.vaults["passcode"]!.integrityEphemeralPublicKey, ephKey)
    }

    func testMigrateRenamesVaultJson() throws {
        try saveFileStoreVault(makeThreeVaultFile())

        _ = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)

        let vaultJson = tempDir.appendingPathComponent("vault.json")
        let migratedFile = tempDir.appendingPathComponent("vault.json.migrated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultJson.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedFile.path))
    }

    func testMigrateIdempotent() throws {
        try saveFileStoreVault(makeThreeVaultFile())

        let first = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(first, 3)

        // Re-create vault.json (simulating manual restore)
        try saveFileStoreVault(makeThreeVaultFile())

        let second = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(second, 0) // Already exists in Keychain
    }

    func testMigrateSkipsWhenKeychainAlreadyHasVault() throws {
        // Pre-populate Keychain
        try keychainStore.saveVaultFile(makeThreeVaultFile())

        // Create different vault.json
        var differentFile = makeThreeVaultFile()
        differentFile.vaults["open"]!.secrets["NEW"] = makeTestSecret(name: "new")
        try saveFileStoreVault(differentFile)

        let count = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 0)

        // Keychain should still have original (no secrets in open tier)
        let loaded = try keychainStore.loadVaultFile()
        XCTAssertTrue(loaded.vaults["open"]!.secrets.isEmpty)
    }

    func testMigrateWithNoVaultJsonReturnsZero() throws {
        let count = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 0)
        XCTAssertFalse(keychainStore.vaultExists())
    }

    func testMigrateWithCorruptVaultJsonReturnsZero() throws {
        // Write corrupt data to vault.json
        let vaultJsonPath = tempDir.appendingPathComponent("vault.json")
        try "not valid json".write(to: vaultJsonPath, atomically: true, encoding: .utf8)

        let count = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 0)
    }

    func testMigrateReturnsNumberOfTiersMigrated() throws {
        // Only 2 tiers
        let file = VaultFile(version: 2, vaults: [
            "open": makeTestEntry(policy: "open"),
            "passcode": makeTestEntry(policy: "passcode"),
        ])
        try saveFileStoreVault(file)

        let count = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 2)
    }

    func testMigrateHandlesExistingMigratedFile() throws {
        // Create existing vault.json.migrated
        let migratedURL = tempDir.appendingPathComponent("vault.json.migrated")
        try "old migrated data".write(to: migratedURL, atomically: true, encoding: .utf8)

        try saveFileStoreVault(makeThreeVaultFile())

        let count = try VaultMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 3)

        // Both old .migrated should be replaced
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("vault.json").path))
    }

    func testMigrateRollsBackOnVerificationFailure() throws {
        // Use a custom store that fails verification by overriding loadVaultFile to throw after first save
        let failingStore = FailOnLoadVaultStore(service: testService + "-fail", accessGroup: nil)
        try saveFileStoreVault(makeThreeVaultFile())

        // Migration should fail and roll back
        XCTAssertThrowsError(try VaultMigrator.migrateIfNeeded(from: fileStore, to: failingStore))

        // After rollback, no orphaned data
        XCTAssertFalse(failingStore.vaultExists())

        // vault.json should still exist (not renamed)
        let vaultJson = tempDir.appendingPathComponent("vault.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultJson.path))

        // Clean up
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService! + "-fail",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Test Double

/// A KeychainVaultStore subclass that throws on loadVaultFile after the first save.
/// Used to test migration rollback.
private class FailOnLoadVaultStore: KeychainVaultStore {
    private var saveCount = 0

    override func saveVaultFile(_ file: VaultFile) throws {
        try super.saveVaultFile(file)
        saveCount += 1
    }

    override func loadVaultFile() throws -> VaultFile {
        if saveCount > 0 {
            throw VaultError.integrityCheckFailed("simulated verification failure")
        }
        return try super.loadVaultFile()
    }
}
