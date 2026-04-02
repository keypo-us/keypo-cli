import XCTest
import Security
@testable import KeypoCore

final class SessionManagerTests: XCTestCase {
    private var testService: String!
    private var store: SessionKeychainStore!
    private var auditLog: SessionAuditLog!
    private var tempDir: URL!
    private var manager: SessionManager!

    override func setUp() {
        super.setUp()
        testService = "com.keypo.session.test-\(UUID().uuidString)"
        store = SessionKeychainStore(service: testService, accessGroup: nil)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("keypo-session-test-\(UUID().uuidString)")
        auditLog = SessionAuditLog(configDir: tempDir)
        manager = SessionManager(keychainStore: store, auditLog: auditLog, vaultManager: VaultManager())
    }

    override func tearDown() {
        // Clean up Keychain items
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService!,
        ]
        SecItemDelete(q as CFDictionary)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeMetadata(
        name: String = "test-session",
        secrets: [String] = ["A", "B"],
        expiresAt: Date = Date().addingTimeInterval(1800),
        maxUses: Int? = 50,
        usesRemaining: Int? = 50
    ) -> SessionMetadata {
        SessionMetadata(
            name: name,
            secrets: secrets,
            originalTiers: Dictionary(uniqueKeysWithValues: secrets.map { ($0, "open") }),
            createdAt: Date(),
            expiresAt: expiresAt,
            maxUses: maxUses,
            usesRemaining: usesRemaining,
            tempKeyPublicKey: "0x04abcdef"
        )
    }

    private func saveSession(_ metadata: SessionMetadata) throws {
        try store.saveSession(metadata, tempKeyDataRep: Data("fake-key".utf8))
    }

    // MARK: - S1.1-S1.3: generateSessionName

    func testGenerateSessionNameFormat() throws {
        let name = try manager.generateSessionName()
        let parts = name.split(separator: "-")
        XCTAssertEqual(parts.count, 2, "Session name should be two words joined by hyphen")
        XCTAssertTrue(name == name.lowercased(), "Session name should be lowercase")
        // Each part should be a real word (non-empty)
        XCTAssertTrue(parts[0].count >= 2)
        XCTAssertTrue(parts[1].count >= 2)
    }

    func testGenerateSessionNameUniqueness() throws {
        var names = Set<String>()
        for _ in 0..<20 {
            let name = try manager.generateSessionName()
            names.insert(name)
        }
        // With 2048^2 = ~4M possible names, 20 should all be unique
        XCTAssertEqual(names.count, 20)
    }

    // MARK: - S2.12, S2.14: isDuplicateSession

    func testIsDuplicateSessionIdenticalSets() throws {
        try saveSession(makeMetadata(name: "s1", secrets: ["A", "B"]))
        let result = try manager.isDuplicateSession(secrets: ["A", "B"])
        XCTAssertTrue(result.isDuplicate)
        XCTAssertEqual(result.existingName, "s1")
    }

    func testIsDuplicateSessionOrderIndependent() throws {
        try saveSession(makeMetadata(name: "s1", secrets: ["B", "A"]))
        let result = try manager.isDuplicateSession(secrets: ["A", "B"])
        XCTAssertTrue(result.isDuplicate)
    }

    // MARK: - S2.13: Overlapping non-identical sets allowed

    func testIsDuplicateSessionOverlappingAllowed() throws {
        try saveSession(makeMetadata(name: "s1", secrets: ["A", "B"]))
        let result = try manager.isDuplicateSession(secrets: ["B", "C"])
        XCTAssertFalse(result.isDuplicate)
    }

    // MARK: - S2.15: Subset/superset allowed

    func testIsDuplicateSessionSubsetAllowed() throws {
        try saveSession(makeMetadata(name: "s1", secrets: ["A", "B"]))
        let result = try manager.isDuplicateSession(secrets: ["A", "B", "C"])
        XCTAssertFalse(result.isDuplicate)
    }

    // MARK: - S2.16: Expired sessions ignored

    func testIsDuplicateSessionIgnoresExpired() throws {
        try saveSession(makeMetadata(name: "s1", secrets: ["A", "B"],
                                      expiresAt: Date().addingTimeInterval(-100)))
        let result = try manager.isDuplicateSession(secrets: ["A", "B"])
        XCTAssertFalse(result.isDuplicate)
    }

    // MARK: - isExpired / isExhausted / isActive

    func testIsExpired() {
        let expired = makeMetadata(expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(manager.isExpired(expired))

        let active = makeMetadata(expiresAt: Date().addingTimeInterval(100))
        XCTAssertFalse(manager.isExpired(active))
    }

    func testIsExhausted() {
        let exhausted = makeMetadata(usesRemaining: 0)
        XCTAssertTrue(manager.isExhausted(exhausted))

        let hasUses = makeMetadata(usesRemaining: 5)
        XCTAssertFalse(manager.isExhausted(hasUses))

        let unlimited = makeMetadata(maxUses: nil, usesRemaining: nil)
        XCTAssertFalse(manager.isExhausted(unlimited))
    }

    func testIsActive() {
        let active = makeMetadata()
        XCTAssertTrue(manager.isActive(active))

        let expired = makeMetadata(expiresAt: Date().addingTimeInterval(-1))
        XCTAssertFalse(manager.isActive(expired))

        let exhausted = makeMetadata(usesRemaining: 0)
        XCTAssertFalse(manager.isActive(exhausted))
    }

    // MARK: - S3.5: decrementUsage

    func testDecrementUsage() throws {
        let metadata = makeMetadata(usesRemaining: 50)
        try saveSession(metadata)

        let updated = try manager.decrementUsage(session: metadata)
        XCTAssertEqual(updated.usesRemaining, 49)

        // Verify persisted
        let loaded = store.loadSession(name: "test-session")
        XCTAssertEqual(loaded?.metadata.usesRemaining, 49)
    }

    func testDecrementUsageUnlimitedIsNoop() throws {
        let metadata = makeMetadata(maxUses: nil, usesRemaining: nil)
        try saveSession(metadata)

        let updated = try manager.decrementUsage(session: metadata)
        XCTAssertNil(updated.usesRemaining)
    }

    // MARK: - endSession

    func testEndSessionNonExistentIsNoop() {
        // Should not crash or throw
        manager.endSession(name: "nonexistent", trigger: "explicit")

        // Verify no audit entry was written
        let logPath = tempDir.appendingPathComponent("session-audit.log")
        let content = try? String(contentsOf: logPath, encoding: .utf8)
        XCTAssertTrue(content == nil || content!.isEmpty)
    }

    func testEndSessionComputesUsesConsumed() throws {
        var metadata = makeMetadata(maxUses: 50, usesRemaining: 42)
        try saveSession(metadata)

        manager.endSession(name: "test-session", trigger: "explicit")

        // Verify session is deleted
        XCTAssertNil(store.loadSession(name: "test-session"))

        // Verify audit entry
        let logPath = tempDir.appendingPathComponent("session-audit.log")
        let content = try String(contentsOf: logPath, encoding: .utf8)
        let json = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
        let details = json["details"] as! [String: Any]
        XCTAssertEqual(details["usesConsumed"] as? Int, 8)
        XCTAssertEqual(details["trigger"] as? String, "explicit")
    }

    func testEndSessionUnlimitedUsesConsumedIsZero() throws {
        let metadata = makeMetadata(maxUses: nil, usesRemaining: nil)
        try saveSession(metadata)

        manager.endSession(name: "test-session", trigger: "explicit")

        let logPath = tempDir.appendingPathComponent("session-audit.log")
        let content = try String(contentsOf: logPath, encoding: .utf8)
        let json = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
        let details = json["details"] as! [String: Any]
        XCTAssertEqual(details["usesConsumed"] as? Int, 0)
    }

    // MARK: - validateSession

    func testValidateSessionNotFound() throws {
        XCTAssertThrowsError(try manager.validateSession(name: "nonexistent")) { error in
            guard case SessionError.sessionNotFound = error else {
                XCTFail("Expected sessionNotFound, got \(error)")
                return
            }
        }
    }

    func testValidateSessionExpired() throws {
        let metadata = makeMetadata(expiresAt: Date().addingTimeInterval(-100))
        try saveSession(metadata)

        XCTAssertThrowsError(try manager.validateSession(name: "test-session")) { error in
            guard case SessionError.sessionExpired = error else {
                XCTFail("Expected sessionExpired, got \(error)")
                return
            }
        }
        // Expired session should be cleaned up
        XCTAssertNil(store.loadSession(name: "test-session"))
    }

    func testValidateSessionExhausted() throws {
        let metadata = makeMetadata(usesRemaining: 0)
        try saveSession(metadata)

        XCTAssertThrowsError(try manager.validateSession(name: "test-session")) { error in
            guard case SessionError.sessionExhausted = error else {
                XCTFail("Expected sessionExhausted, got \(error)")
                return
            }
        }
        // Exhausted session should be cleaned up
        XCTAssertNil(store.loadSession(name: "test-session"))
    }

    func testValidateSessionActive() throws {
        let metadata = makeMetadata()
        try saveSession(metadata)

        let result = try manager.validateSession(name: "test-session")
        XCTAssertEqual(result.name, "test-session")
    }

    // MARK: - S4.12: garbageCollect

    func testGarbageCollectRemovesExpired() throws {
        try saveSession(makeMetadata(name: "expired-1", expiresAt: Date().addingTimeInterval(-100)))
        try saveSession(makeMetadata(name: "expired-2", expiresAt: Date().addingTimeInterval(-200)))
        try saveSession(makeMetadata(name: "active-1"))

        let cleaned = try manager.garbageCollect()
        XCTAssertEqual(cleaned, 2)

        // Active session should remain
        XCTAssertNotNil(store.loadSession(name: "active-1"))
        XCTAssertNil(store.loadSession(name: "expired-1"))
        XCTAssertNil(store.loadSession(name: "expired-2"))
    }
}
