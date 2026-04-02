import XCTest
import Security
@testable import KeypoCore

final class SessionKeychainStoreTests: XCTestCase {
    private var testService: String!
    private var store: SessionKeychainStore!

    override func setUp() {
        super.setUp()
        testService = "com.keypo.session.test-\(UUID().uuidString)"
        store = SessionKeychainStore(service: testService, accessGroup: nil)
    }

    override func tearDown() {
        // Delete all metadata items
        let metaQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService!,
        ]
        SecItemDelete(metaQuery as CFDictionary)

        // Delete secret items (we use predictable session names in tests)
        for name in ["test-session", "session-one", "session-two", "session-three", "dup-test"] {
            let secretQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "\(testService!).\(name)",
            ]
            SecItemDelete(secretQuery as CFDictionary)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeMetadata(
        name: String = "test-session",
        secrets: [String] = ["SECRET_A", "SECRET_B"],
        originalTiers: [String: String] = ["SECRET_A": "open", "SECRET_B": "open"],
        maxUses: Int? = 50,
        usesRemaining: Int? = 50
    ) -> SessionMetadata {
        SessionMetadata(
            name: name,
            secrets: secrets,
            originalTiers: originalTiers,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(1800),
            maxUses: maxUses,
            usesRemaining: usesRemaining,
            tempKeyPublicKey: "0x04abcdef1234567890"
        )
    }

    private func makeEncryptedSecret() -> EncryptedSecret {
        EncryptedSecret(
            ephemeralPublicKey: "0x04aabbccdd",
            nonce: Data("test-nonce-12".utf8).base64EncodedString(),
            ciphertext: Data("encrypted-value".utf8).base64EncodedString(),
            tag: Data("tag-16-bytes-xx!".utf8).base64EncodedString(),
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - S6.1: Save/load session metadata roundtrip

    func testSaveLoadSessionMetadataRoundtrip() throws {
        let metadata = makeMetadata()
        let tempKeyData = Data("fake-se-key-data".utf8)

        try store.saveSession(metadata, tempKeyDataRep: tempKeyData)

        let loaded = store.loadSession(name: "test-session")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.metadata.name, "test-session")
        XCTAssertEqual(loaded!.metadata.secrets, ["SECRET_A", "SECRET_B"])
        XCTAssertEqual(loaded!.metadata.maxUses, 50)
        XCTAssertEqual(loaded!.metadata.usesRemaining, 50)
        XCTAssertEqual(loaded!.metadata.tempKeyPublicKey, "0x04abcdef1234567890")
        XCTAssertEqual(loaded!.tempKeyDataRep, tempKeyData)
    }

    // MARK: - S6.2: Save/load session secret roundtrip

    func testSaveLoadSessionSecretRoundtrip() throws {
        let secret = makeEncryptedSecret()
        try store.saveSessionSecret(sessionName: "test-session", secretName: "API_KEY", encrypted: secret)

        let loaded = store.loadSessionSecret(sessionName: "test-session", secretName: "API_KEY")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.ephemeralPublicKey, secret.ephemeralPublicKey)
        XCTAssertEqual(loaded!.ciphertext, secret.ciphertext)
    }

    // MARK: - S6.3: Delete session removes metadata item

    func testDeleteSessionRemovesMetadata() throws {
        let metadata = makeMetadata()
        try store.saveSession(metadata, tempKeyDataRep: Data("key".utf8))

        store.deleteSession(name: "test-session")

        let loaded = store.loadSession(name: "test-session")
        XCTAssertNil(loaded)
    }

    // MARK: - S6.4: Delete session removes all associated secret items

    func testDeleteSessionRemovesSecrets() throws {
        let metadata = makeMetadata()
        try store.saveSession(metadata, tempKeyDataRep: Data("key".utf8))
        try store.saveSessionSecret(sessionName: "test-session", secretName: "SECRET_A", encrypted: makeEncryptedSecret())
        try store.saveSessionSecret(sessionName: "test-session", secretName: "SECRET_B", encrypted: makeEncryptedSecret())

        store.deleteSession(name: "test-session")

        let secrets = store.loadAllSessionSecrets(sessionName: "test-session")
        XCTAssertTrue(secrets.isEmpty)
    }

    // MARK: - S6.5: List sessions returns only session items

    func testListSessionsReturnsOnlySessionItems() throws {
        let m1 = makeMetadata(name: "session-one", secrets: ["A"])
        let m2 = makeMetadata(name: "session-two", secrets: ["B"])

        try store.saveSession(m1, tempKeyDataRep: Data("k1".utf8))
        try store.saveSession(m2, tempKeyDataRep: Data("k2".utf8))

        let sessions = try store.listSessions()
        XCTAssertEqual(sessions.count, 2)
        let names = Set(sessions.map { $0.metadata.name })
        XCTAssertTrue(names.contains("session-one"))
        XCTAssertTrue(names.contains("session-two"))
    }

    // MARK: - S6.6: Multiple sessions coexist independently

    func testMultipleSessionsCoexist() throws {
        let m1 = makeMetadata(name: "session-one", secrets: ["A"])
        let m2 = makeMetadata(name: "session-two", secrets: ["B"])

        try store.saveSession(m1, tempKeyDataRep: Data("k1".utf8))
        try store.saveSession(m2, tempKeyDataRep: Data("k2".utf8))
        try store.saveSessionSecret(sessionName: "session-one", secretName: "A", encrypted: makeEncryptedSecret())
        try store.saveSessionSecret(sessionName: "session-two", secretName: "B", encrypted: makeEncryptedSecret())

        // Delete one, verify other is unaffected
        store.deleteSession(name: "session-one")

        XCTAssertNil(store.loadSession(name: "session-one"))
        XCTAssertNotNil(store.loadSession(name: "session-two"))
        XCTAssertNotNil(store.loadSessionSecret(sessionName: "session-two", secretName: "B"))
    }

    // MARK: - S6.7: Upsert semantics on duplicate save

    func testUpsertSemantics() throws {
        let m1 = makeMetadata(name: "dup-test", usesRemaining: 50)
        try store.saveSession(m1, tempKeyDataRep: Data("k1".utf8))

        // Save again with different usesRemaining
        var m2 = makeMetadata(name: "dup-test", usesRemaining: 42)
        m2.maxUses = 50
        try store.saveSession(m2, tempKeyDataRep: Data("k2".utf8))

        let loaded = store.loadSession(name: "dup-test")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.metadata.usesRemaining, 42)
        XCTAssertEqual(loaded!.tempKeyDataRep, Data("k2".utf8))
    }

    // MARK: - Update metadata

    func testUpdateSessionMetadata() throws {
        var metadata = makeMetadata(usesRemaining: 50)
        try store.saveSession(metadata, tempKeyDataRep: Data("key".utf8))

        metadata.usesRemaining = 49
        try store.updateSessionMetadata(metadata)

        let loaded = store.loadSession(name: "test-session")
        XCTAssertEqual(loaded!.metadata.usesRemaining, 49)
    }

    // MARK: - Load all secrets

    func testLoadAllSessionSecrets() throws {
        try store.saveSessionSecret(sessionName: "test-session", secretName: "A", encrypted: makeEncryptedSecret())
        try store.saveSessionSecret(sessionName: "test-session", secretName: "B", encrypted: makeEncryptedSecret())

        let secrets = store.loadAllSessionSecrets(sessionName: "test-session")
        XCTAssertEqual(secrets.count, 2)
        XCTAssertNotNil(secrets["A"])
        XCTAssertNotNil(secrets["B"])
    }

    // MARK: - Load non-existent session

    func testLoadNonExistentSessionReturnsNil() {
        let loaded = store.loadSession(name: "nonexistent")
        XCTAssertNil(loaded)
    }

    // MARK: - Empty list

    func testListSessionsEmpty() throws {
        let sessions = try store.listSessions()
        XCTAssertTrue(sessions.isEmpty)
    }
}
