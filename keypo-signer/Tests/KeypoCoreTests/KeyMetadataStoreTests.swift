import XCTest
@testable import KeypoCore

/// Tests for file store behavioral changes: duplicate guard, throw-on-missing, dataRep immutability, replaceKey.
final class KeyMetadataStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: KeyMetadataStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("keypo-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = KeyMetadataStore(configDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeKey(
        keyId: String = "test-key",
        dataRep: String? = nil,
        publicKey: String = "0x04aabb"
    ) -> KeyMetadata {
        KeyMetadata(
            keyId: keyId,
            applicationTag: "com.keypo.signer.\(keyId)",
            publicKey: publicKey,
            policy: .open,
            createdAt: Date(),
            signingCount: 0,
            lastUsedAt: nil,
            previousPublicKeys: [],
            dataRepresentation: dataRep ?? Data("token-\(keyId)".utf8).base64EncodedString()
        )
    }

    func testFileStoreAddDuplicateThrows() throws {
        try store.addKey(makeKey(keyId: "dup"))
        XCTAssertThrowsError(try store.addKey(makeKey(keyId: "dup"))) { error in
            guard case KeypoError.storeError(let msg) = error else {
                XCTFail("Expected storeError, got \(error)")
                return
            }
            XCTAssert(msg.contains("already exists"))
        }
    }

    func testFileStoreUpdateMissingKeyThrows() throws {
        let key = makeKey(keyId: "missing")
        XCTAssertThrowsError(try store.updateKey(key)) { error in
            guard case KeypoError.storeError(let msg) = error else {
                XCTFail("Expected storeError, got \(error)")
                return
            }
            XCTAssert(msg.contains("not found"))
        }
    }

    func testFileStoreUpdateChangedDataRepThrows() throws {
        let original = makeKey(keyId: "immutable", dataRep: Data("token-A".utf8).base64EncodedString())
        try store.addKey(original)

        var modified = original
        modified.dataRepresentation = Data("token-B".utf8).base64EncodedString()
        XCTAssertThrowsError(try store.updateKey(modified)) { error in
            guard case KeypoError.storeError(let msg) = error else {
                XCTFail("Expected storeError, got \(error)")
                return
            }
            XCTAssert(msg.contains("replaceKey"))
        }
    }

    func testFileStoreIncrementMissingKeyThrows() throws {
        XCTAssertThrowsError(try store.incrementSignCount(keyId: "ghost")) { error in
            guard case KeypoError.storeError(let msg) = error else {
                XCTFail("Expected storeError, got \(error)")
                return
            }
            XCTAssert(msg.contains("not found"))
        }
    }

    func testFileStoreReplaceKeyChangesDataRep() throws {
        let original = makeKey(keyId: "rotate", dataRep: Data("old-token".utf8).base64EncodedString())
        try store.addKey(original)

        var rotated = original
        rotated.dataRepresentation = Data("new-token".utf8).base64EncodedString()
        rotated.publicKey = "0x04newkey"
        try store.replaceKey(rotated)

        let found = try store.findKey(keyId: "rotate")!
        XCTAssertEqual(found.dataRepresentation, rotated.dataRepresentation)
        XCTAssertEqual(found.publicKey, "0x04newkey")
    }
}
