import XCTest
import Security
@testable import KeypoCore

final class KeyMetadataMigratorTests: XCTestCase {
    private var tempDir: URL!
    private var fileStore: KeyMetadataStore!
    private var testService: String!
    private var keychainStore: KeychainMetadataStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("keypo-migrate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = KeyMetadataStore(configDir: tempDir)
        testService = "com.keypo.signer.keys.migrate-\(UUID().uuidString)"
        keychainStore = KeychainMetadataStore(configDir: tempDir, service: testService, accessGroup: nil)
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

    private func makeKey(
        keyId: String,
        dataRep: String? = nil,
        publicKey: String = "0x04aabb",
        signingCount: Int = 0,
        lastUsedAt: Date? = nil,
        previousPublicKeys: [String] = []
    ) -> KeyMetadata {
        KeyMetadata(
            keyId: keyId,
            applicationTag: "com.keypo.signer.\(keyId)",
            publicKey: publicKey,
            policy: .open,
            createdAt: Date(),
            signingCount: signingCount,
            lastUsedAt: lastUsedAt,
            previousPublicKeys: previousPublicKeys,
            dataRepresentation: dataRep ?? Data("token-\(keyId)".utf8).base64EncodedString()
        )
    }

    private func writeKeysToFile(_ keys: [KeyMetadata]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(keys)
        let keysFile = tempDir.appendingPathComponent("keys.json")
        try data.write(to: keysFile)
    }

    // MARK: - Migration Correctness

    func testMigrateMovesAllKeysToKeychain() throws {
        let keys = [makeKey(keyId: "m-a"), makeKey(keyId: "m-b"), makeKey(keyId: "m-c")]
        try writeKeysToFile(keys)

        let count = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 3)

        let kcKeys = try keychainStore.loadKeys()
        XCTAssertEqual(kcKeys.count, 3)
        let ids = Set(kcKeys.map { $0.keyId })
        XCTAssertEqual(ids, ["m-a", "m-b", "m-c"])
    }

    func testMigratePreservesDataRepresentation() throws {
        let knownRep = Data("specific-se-token-xyz".utf8).base64EncodedString()
        try writeKeysToFile([makeKey(keyId: "dr-test", dataRep: knownRep)])

        _ = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)

        let found = try keychainStore.findKey(keyId: "dr-test")!
        XCTAssertEqual(found.dataRepresentation, knownRep)
    }

    func testMigratePreservesAllMetadataFields() throws {
        let key = makeKey(
            keyId: "full-test",
            publicKey: "0x04fullkey",
            signingCount: 42,
            lastUsedAt: Date(timeIntervalSince1970: 1711324800),
            previousPublicKeys: ["0x04abc", "0x04def"]
        )
        try writeKeysToFile([key])

        _ = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)

        let found = try keychainStore.findKey(keyId: "full-test")!
        XCTAssertEqual(found.publicKey, "0x04fullkey")
        XCTAssertEqual(found.signingCount, 42)
        XCTAssertNotNil(found.lastUsedAt)
        XCTAssertEqual(found.lastUsedAt!.timeIntervalSince1970, 1711324800, accuracy: 1.0)
        XCTAssertEqual(found.previousPublicKeys, ["0x04abc", "0x04def"])
    }

    func testMigrateRenamesJsonFile() throws {
        try writeKeysToFile([makeKey(keyId: "rename-test")])

        _ = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)

        let keysFile = tempDir.appendingPathComponent("keys.json")
        let migratedFile = tempDir.appendingPathComponent("keys.json.migrated")
        XCTAssertFalse(FileManager.default.fileExists(atPath: keysFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedFile.path))
    }

    func testMigrateIdempotent() throws {
        let keys = [makeKey(keyId: "idem-a"), makeKey(keyId: "idem-b")]
        try writeKeysToFile(keys)

        let first = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(first, 2)

        // Re-create keys.json (simulating incomplete rename or manual restore)
        try writeKeysToFile(keys)

        let second = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(second, 0) // All keys already in Keychain

        let kcKeys = try keychainStore.loadKeys()
        XCTAssertEqual(kcKeys.count, 2) // No duplicates
    }

    func testMigrateSkipsKeysAlreadyInKeychain() throws {
        // Pre-add key "a" to Keychain with specific publicKey
        let preExisting = makeKey(keyId: "skip-a", publicKey: "0x04keychain-version")
        try keychainStore.addKey(preExisting)

        // File has "a" (different publicKey) and "b"
        let fileKeys = [
            makeKey(keyId: "skip-a", publicKey: "0x04file-version"),
            makeKey(keyId: "skip-b"),
        ]
        try writeKeysToFile(fileKeys)

        let count = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 1) // Only "b" migrated

        // "a" should keep Keychain version, not file version
        let foundA = try keychainStore.findKey(keyId: "skip-a")!
        XCTAssertEqual(foundA.publicKey, "0x04keychain-version")
    }

    func testMigrateWithEmptyFileReturnsZero() throws {
        // No keys.json exists
        let count = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 0)

        let kcKeys = try keychainStore.loadKeys()
        XCTAssertEqual(kcKeys.count, 0)
    }

    func testMigrateWithEmptyArrayReturnsZero() throws {
        try writeKeysToFile([])

        let count = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 0)
    }

    func testMigrateReturnsOnlyNewlyAddedCount() throws {
        // Pre-add "a" to Keychain
        try keychainStore.addKey(makeKey(keyId: "count-a"))

        // File has "a", "b", "c"
        try writeKeysToFile([
            makeKey(keyId: "count-a"),
            makeKey(keyId: "count-b"),
            makeKey(keyId: "count-c"),
        ])

        let count = try KeyMetadataMigrator.migrateIfNeeded(from: fileStore, to: keychainStore)
        XCTAssertEqual(count, 2) // Only "b" and "c" are new
    }

    // MARK: - Protocol Conformance

    func testFileStoreConformsToProtocol() throws {
        let proto: any KeyMetadataStoring = fileStore
        _ = try proto.loadKeys()
        _ = try proto.findKey(keyId: "nonexistent")
    }

    func testKeychainStoreConformsToProtocol() throws {
        let proto: any KeyMetadataStoring = keychainStore
        _ = try proto.loadKeys()
        _ = try proto.findKey(keyId: "nonexistent")
    }
}
