import XCTest
@testable import KeypoCore

final class SessionAuditLogTests: XCTestCase {
    private var tempDir: URL!
    private var auditLog: SessionAuditLog!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("keypo-audit-test-\(UUID().uuidString)")
        auditLog = SessionAuditLog(configDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private var logPath: URL {
        tempDir.appendingPathComponent("session-audit.log")
    }

    // MARK: - S7.1: Log creates file if missing

    func testLogCreatesFileIfMissing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: logPath.path))

        let entry = AuditEntry(
            event: "session.start",
            session: "test-session",
            details: .start(SessionStartDetails(
                secrets: ["A"], tiers: ["A": "open"], ttl: "30m", maxUses: nil, expiresAt: "2026-01-01T00:00:00Z"
            ))
        )
        auditLog.log(entry)

        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath.path))
    }

    // MARK: - S7.2: Entry is valid JSON

    func testEntryIsValidJSON() throws {
        let entry = AuditEntry(
            event: "session.start",
            session: "test-session",
            details: .start(SessionStartDetails(
                secrets: ["A", "B"], tiers: ["A": "open", "B": "biometric"],
                ttl: "30m", maxUses: 50, expiresAt: "2026-01-01T00:30:00Z"
            ))
        )
        auditLog.log(entry)

        let content = try String(contentsOf: logPath, encoding: .utf8)
        let line = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8))
        XCTAssertTrue(json is [String: Any])

        let dict = json as! [String: Any]
        XCTAssertEqual(dict["event"] as? String, "session.start")
        XCTAssertEqual(dict["session"] as? String, "test-session")

        let details = dict["details"] as? [String: Any]
        XCTAssertNotNil(details)
        XCTAssertEqual(details?["ttl"] as? String, "30m")
        XCTAssertEqual(details?["maxUses"] as? Int, 50)
        XCTAssertEqual((details?["secrets"] as? [String])?.sorted(), ["A", "B"])
    }

    // MARK: - S7.3: Multiple entries produce JSONL

    func testMultipleEntriesProduceJSONL() {
        for i in 0..<3 {
            let entry = AuditEntry(
                event: "session.exec",
                session: "session-\(i)",
                details: .exec(SessionExecDetails(
                    command: "test", secretsInjected: ["A"], usesRemaining: 10 - i, childPid: 1000 + i
                ))
            )
            auditLog.log(entry)
        }

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            XCTFail("Could not read log file")
            return
        }

        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        // Each line is valid JSON
        for line in lines {
            let json = try? JSONSerialization.jsonObject(with: Data(line.utf8))
            XCTAssertNotNil(json)
        }
    }

    // MARK: - S7.4: File created with 0600 permissions

    func testFilePermissions() {
        let entry = AuditEntry(
            event: "session.end",
            session: "test-session",
            details: .end(SessionEndDetails(trigger: "explicit", usesConsumed: 5))
        )
        auditLog.log(entry)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
              let permissions = attrs[.posixPermissions] as? Int else {
            XCTFail("Could not read file attributes")
            return
        }

        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    // MARK: - S7.12: Logging failure is non-fatal

    func testLoggingFailureIsNonFatal() {
        // Point at a read-only directory
        let readOnlyDir = tempDir.appendingPathComponent("readonly")
        try? FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)

        // Create the log file as read-only
        let readOnlyLog = readOnlyDir.appendingPathComponent("session-audit.log")
        FileManager.default.createFile(atPath: readOnlyLog.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: readOnlyLog.path)

        let failLog = SessionAuditLog(configDir: readOnlyDir)

        // Should not crash
        let entry = AuditEntry(
            event: "session.start",
            session: "test",
            details: .start(SessionStartDetails(
                secrets: ["A"], tiers: ["A": "open"], ttl: "30m", maxUses: nil, expiresAt: "2026-01-01T00:00:00Z"
            ))
        )
        failLog.log(entry)

        // Restore permissions for cleanup
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyLog.path)
    }

    // MARK: - Detail struct roundtrips

    func testSessionStartDetailsRoundtrip() throws {
        let details = SessionStartDetails(
            secrets: ["A", "B"], tiers: ["A": "open", "B": "biometric"],
            ttl: "30m", maxUses: 50, expiresAt: "2026-01-01T00:30:00Z"
        )
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(SessionStartDetails.self, from: data)
        XCTAssertEqual(decoded.secrets, ["A", "B"])
        XCTAssertEqual(decoded.maxUses, 50)
    }

    func testSessionExecDetailsRoundtrip() throws {
        let details = SessionExecDetails(command: "python", secretsInjected: ["API_KEY"], usesRemaining: 49, childPid: 12345)
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(SessionExecDetails.self, from: data)
        XCTAssertEqual(decoded.command, "python")
        XCTAssertEqual(decoded.childPid, 12345)
    }

    func testSessionExecDeniedDetailsRoundtrip() throws {
        let details = SessionExecDeniedDetails(reason: "expired", command: "python")
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(SessionExecDeniedDetails.self, from: data)
        XCTAssertEqual(decoded.reason, "expired")
    }

    func testSessionEndDetailsRoundtrip() throws {
        let details = SessionEndDetails(trigger: "explicit", usesConsumed: 8)
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(SessionEndDetails.self, from: data)
        XCTAssertEqual(decoded.usesConsumed, 8)
    }

    func testSessionRefreshDetailsRoundtrip() throws {
        let details = SessionRefreshDetails(
            oldExpiresAt: "2026-01-01T00:30:00Z", newExpiresAt: "2026-01-01T01:00:00Z",
            oldMaxUses: 50, newMaxUses: 100
        )
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(SessionRefreshDetails.self, from: data)
        XCTAssertEqual(decoded.newMaxUses, 100)
    }

    // MARK: - AuditEntry encodes details as flat object

    func testAuditEntryEncodesDetailsFlat() throws {
        let entry = AuditEntry(
            timestamp: "2026-01-01T00:00:00Z",
            event: "session.start",
            session: "orbital-canvas",
            details: .start(SessionStartDetails(
                secrets: ["API_KEY"], tiers: ["API_KEY": "biometric"],
                ttl: "30m", maxUses: 50, expiresAt: "2026-01-01T00:30:00Z"
            ))
        )

        let data = try JSONEncoder().encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Details should be a flat dict, not wrapped in a discriminator
        let details = json["details"] as? [String: Any]
        XCTAssertNotNil(details)
        XCTAssertEqual(details?["ttl"] as? String, "30m")
        XCTAssertEqual(details?["maxUses"] as? Int, 50)
        // Should NOT have a discriminator key like "start" or "_type"
        XCTAssertNil(details?["start"])
        XCTAssertNil(details?["_type"])
    }

    // MARK: - End-to-end audit trail (S7.13)

    func testEndToEndAuditTrail() throws {
        let startEntry = AuditEntry(
            event: "session.start",
            session: "orbital-canvas",
            details: .start(SessionStartDetails(
                secrets: ["A"], tiers: ["A": "open"], ttl: "30m", maxUses: 10, expiresAt: "2026-01-01T00:30:00Z"
            ))
        )
        auditLog.log(startEntry)

        let execEntry = AuditEntry(
            event: "session.exec",
            session: "orbital-canvas",
            details: .exec(SessionExecDetails(command: "python", secretsInjected: ["A"], usesRemaining: 9, childPid: 42))
        )
        auditLog.log(execEntry)

        let endEntry = AuditEntry(
            event: "session.end",
            session: "orbital-canvas",
            details: .end(SessionEndDetails(trigger: "explicit", usesConsumed: 1))
        )
        auditLog.log(endEntry)

        let content = try String(contentsOf: logPath, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)

        // Parse each and verify events in order
        let events = try lines.map { line -> String in
            let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return json["event"] as! String
        }
        XCTAssertEqual(events, ["session.start", "session.exec", "session.end"])
    }
}
