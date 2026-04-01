import XCTest
import Security
@testable import KeypoCore

final class KeychainMetadataStoreTests: XCTestCase {
    private var testService: String!
    private var store: KeychainMetadataStore!

    override func setUp() {
        super.setUp()
        testService = "com.keypo.signer.keys.test-\(UUID().uuidString)"
        store = KeychainMetadataStore(service: testService, accessGroup: nil)
    }

    override func tearDown() {
        // SecItemDelete deletes all matching items by default (no kSecMatchLimit needed)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService!,
        ]
        SecItemDelete(query as CFDictionary)
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeKey(
        keyId: String = "test-key",
        dataRep: String? = nil,
        publicKey: String = "0x04aabb",
        policy: KeyPolicy = .open,
        signingCount: Int = 0,
        lastUsedAt: Date? = nil,
        previousPublicKeys: [String] = []
    ) -> KeyMetadata {
        KeyMetadata(
            keyId: keyId,
            applicationTag: "com.keypo.signer.\(keyId)",
            publicKey: publicKey,
            policy: policy,
            createdAt: Date(),
            signingCount: signingCount,
            lastUsedAt: lastUsedAt,
            previousPublicKeys: previousPublicKeys,
            dataRepresentation: dataRep ?? Data("fake-se-token-\(keyId)".utf8).base64EncodedString()
        )
    }

    // MARK: - Storage Correctness

    func testAddThenFindReturnsExactMetadata() throws {
        let key = makeKey(
            keyId: "exact-test",
            publicKey: "0x04deadbeef",
            policy: .passcode,
            signingCount: 5,
            lastUsedAt: Date(),
            previousPublicKeys: ["0x04old1", "0x04old2"]
        )
        try store.addKey(key)

        let found = try store.findKey(keyId: "exact-test")
        XCTAssertNotNil(found)
        XCTAssertEqual(found!.keyId, key.keyId)
        XCTAssertEqual(found!.applicationTag, key.applicationTag)
        XCTAssertEqual(found!.publicKey, key.publicKey)
        XCTAssertEqual(found!.policy, key.policy)
        XCTAssertEqual(found!.signingCount, key.signingCount)
        XCTAssertEqual(found!.previousPublicKeys, key.previousPublicKeys)
        XCTAssertEqual(found!.dataRepresentation, key.dataRepresentation)
        // lastUsedAt within 1 second (ISO 8601 whole-second precision)
        XCTAssertNotNil(found!.lastUsedAt)
        XCTAssertEqual(found!.lastUsedAt!.timeIntervalSince1970, key.lastUsedAt!.timeIntervalSince1970, accuracy: 1.0)
    }

    func testAddThenFindPreservesDataRepresentation() throws {
        let knownDataRep = Data("specific-opaque-token-bytes-12345".utf8).base64EncodedString()
        let key = makeKey(keyId: "datarep-test", dataRep: knownDataRep)
        try store.addKey(key)

        let found = try store.findKey(keyId: "datarep-test")
        XCTAssertNotNil(found)
        XCTAssertEqual(found!.dataRepresentation, knownDataRep)
    }

    func testFindNonexistentKeyReturnsNil() throws {
        let found = try store.findKey(keyId: "does-not-exist")
        XCTAssertNil(found)
    }

    func testAddDuplicateKeyIdThrows() throws {
        let key1 = makeKey(keyId: "dup-test")
        try store.addKey(key1)

        let key2 = makeKey(keyId: "dup-test", publicKey: "0x04different")
        XCTAssertThrowsError(try store.addKey(key2)) { error in
            guard case KeypoError.storeError(let msg) = error else {
                XCTFail("Expected storeError, got \(error)")
                return
            }
            XCTAssert(msg.contains("already exists"))
        }
    }

    func testLoadKeysReturnsAllAdded() throws {
        try store.addKey(makeKey(keyId: "load-a"))
        try store.addKey(makeKey(keyId: "load-b"))
        try store.addKey(makeKey(keyId: "load-c"))

        let all = try store.loadKeys()
        XCTAssertEqual(all.count, 3)
        let ids = Set(all.map { $0.keyId })
        XCTAssertEqual(ids, ["load-a", "load-b", "load-c"])
    }

    func testLoadKeysEmptyReturnsEmptyArray() throws {
        let all = try store.loadKeys()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Mutations

    func testRemoveKeyDeletesOnlyTargetKey() throws {
        let keyA = makeKey(keyId: "rm-a")
        let keyB = makeKey(keyId: "rm-b")
        try store.addKey(keyA)
        try store.addKey(keyB)

        try store.removeKey(keyId: "rm-a")

        XCTAssertNil(try store.findKey(keyId: "rm-a"))
        let foundB = try store.findKey(keyId: "rm-b")
        XCTAssertNotNil(foundB)
        XCTAssertEqual(foundB!.publicKey, keyB.publicKey)
    }

    func testRemoveNonexistentKeyDoesNotThrow() throws {
        XCTAssertNoThrow(try store.removeKey(keyId: "nonexistent"))
    }

    func testUpdateKeyModifiesFields() throws {
        var key = makeKey(keyId: "upd-test", publicKey: "0x04original", policy: .open)
        try store.addKey(key)

        key.signingCount = 5
        key.publicKey = "0x04updated"
        try store.updateKey(key)

        let found = try store.findKey(keyId: "upd-test")!
        XCTAssertEqual(found.signingCount, 5)
        XCTAssertEqual(found.publicKey, "0x04updated")
        XCTAssertEqual(found.policy, .open)
    }

    func testUpdatePreservesDataRepresentation() throws {
        let originalDataRep = Data("original-token".utf8).base64EncodedString()
        var key = makeKey(keyId: "upd-dr-test", dataRep: originalDataRep)
        try store.addKey(key)

        // Modify only metadata, keep same dataRepresentation
        key.signingCount = 10
        try store.updateKey(key)

        let found = try store.findKey(keyId: "upd-dr-test")!
        XCTAssertEqual(found.dataRepresentation, originalDataRep)
    }

    func testIncrementSignCountFromZero() throws {
        let key = makeKey(keyId: "inc-test")
        XCTAssertEqual(key.signingCount, 0)
        XCTAssertNil(key.lastUsedAt)
        try store.addKey(key)

        try store.incrementSignCount(keyId: "inc-test")

        let found = try store.findKey(keyId: "inc-test")!
        XCTAssertEqual(found.signingCount, 1)
        XCTAssertNotNil(found.lastUsedAt)
        XCTAssertEqual(found.lastUsedAt!.timeIntervalSinceNow, 0, accuracy: 2.0)
    }

    func testIncrementSignCountMultipleTimes() throws {
        try store.addKey(makeKey(keyId: "inc-multi"))

        try store.incrementSignCount(keyId: "inc-multi")
        try store.incrementSignCount(keyId: "inc-multi")
        try store.incrementSignCount(keyId: "inc-multi")

        let found = try store.findKey(keyId: "inc-multi")!
        XCTAssertEqual(found.signingCount, 3)
    }

    func testIncrementSignCountPreservesOtherFields() throws {
        let key = makeKey(
            keyId: "inc-preserve",
            publicKey: "0x04specific",
            policy: .biometric,
            previousPublicKeys: ["0x04old"]
        )
        try store.addKey(key)

        try store.incrementSignCount(keyId: "inc-preserve")

        let found = try store.findKey(keyId: "inc-preserve")!
        XCTAssertEqual(found.publicKey, "0x04specific")
        XCTAssertEqual(found.policy, .biometric)
        XCTAssertEqual(found.previousPublicKeys, ["0x04old"])
    }

    func testReplaceKeyChangesDataRep() throws {
        let originalRep = Data("token-A".utf8).base64EncodedString()
        let newRep = Data("token-B".utf8).base64EncodedString()

        try store.addKey(makeKey(keyId: "rot-test", dataRep: originalRep))

        let updated = makeKey(keyId: "rot-test", dataRep: newRep, publicKey: "0x04new")
        try store.replaceKey(updated)

        let found = try store.findKey(keyId: "rot-test")!
        XCTAssertEqual(found.dataRepresentation, newRep)
        XCTAssertEqual(found.publicKey, "0x04new")
    }

    // MARK: - Error Paths

    func testUpdateNonexistentKeyThrows() throws {
        let key = makeKey(keyId: "no-such-key")
        XCTAssertThrowsError(try store.updateKey(key)) { error in
            guard case KeypoError.storeError(let msg) = error else {
                XCTFail("Expected storeError, got \(error)")
                return
            }
            XCTAssert(msg.contains("not found"))
        }
    }

    func testIncrementSignCountNonexistentKeyThrows() throws {
        XCTAssertThrowsError(try store.incrementSignCount(keyId: "ghost")) { error in
            guard case KeypoError.storeError(let msg) = error else {
                XCTFail("Expected storeError, got \(error)")
                return
            }
            XCTAssert(msg.contains("not found"))
        }
    }

    // MARK: - Isolation & Dates

    func testDifferentServiceNamesAreIsolated() throws {
        let storeA = KeychainMetadataStore(service: testService + "-A", accessGroup: nil)
        let storeB = KeychainMetadataStore(service: testService + "-B", accessGroup: nil)

        try storeA.addKey(makeKey(keyId: "iso-key"))

        XCTAssertNotNil(try storeA.findKey(keyId: "iso-key"))
        XCTAssertNil(try storeB.findKey(keyId: "iso-key"))

        // Clean up store A
        let queryA: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService! + "-A",
        ]
        SecItemDelete(queryA as CFDictionary)
    }

    func testCreatedAtRoundTripsWithSecondPrecision() throws {
        let specificDate = Date(timeIntervalSince1970: 1711324800) // 2024-03-25 00:00:00 UTC
        var key = makeKey(keyId: "date-test")
        key.createdAt = specificDate
        try store.addKey(key)

        let found = try store.findKey(keyId: "date-test")!
        // .iso8601 truncates to whole seconds
        XCTAssertEqual(found.createdAt.timeIntervalSince1970, specificDate.timeIntervalSince1970, accuracy: 1.0)
    }
}
