import XCTest
@testable import KeypoCore

/// Tests verifying VaultStoring protocol conformance and that the shared
/// lookup methods (protocol extension) work on both store implementations.
final class VaultStoreProtocolTests: XCTestCase {
    private var tempDir: URL!
    private var fileStore: VaultStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("keypo-vault-proto-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileStore = VaultStore(configDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeTestEntry(policy: String, secrets: [String: EncryptedSecret] = [:]) -> VaultEntry {
        VaultEntry(
            vaultKeyId: UUID().uuidString,
            dataRepresentation: Data("token-\(policy)".utf8).base64EncodedString(),
            publicKey: "0x04" + String(repeating: "ab", count: 64),
            integrityEphemeralPublicKey: "0x04" + String(repeating: "cd", count: 64),
            integrityHmac: Data("hmac-\(policy)".utf8).base64EncodedString(),
            createdAt: Date(),
            secrets: secrets
        )
    }

    private func makeTestSecret() -> EncryptedSecret {
        EncryptedSecret(
            ephemeralPublicKey: "0x04" + String(repeating: "ef", count: 64),
            nonce: Data("nonce-12byte".utf8).base64EncodedString(),
            ciphertext: Data("ciphertext".utf8).base64EncodedString(),
            tag: Data("tag-16-bytes-xx".utf8).base64EncodedString(),
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - Protocol Extension on File Store

    func testFileStoreFindSecretUsesProtocolExtension() throws {
        var entry = makeTestEntry(policy: "open")
        entry.secrets["MY_SECRET"] = makeTestSecret()
        let file = VaultFile(version: 2, vaults: ["open": entry])
        try fileStore.saveVaultFile(file)

        let result = try fileStore.findSecret(name: "MY_SECRET")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.policy, .open)
    }

    func testFileStoreAllSecretNamesUsesProtocolExtension() throws {
        var entry = makeTestEntry(policy: "open")
        entry.secrets["ALPHA"] = makeTestSecret()
        entry.secrets["BETA"] = makeTestSecret()
        let file = VaultFile(version: 2, vaults: ["open": entry])
        try fileStore.saveVaultFile(file)

        let names = try fileStore.allSecretNames()
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names[0].name, "ALPHA")
        XCTAssertEqual(names[1].name, "BETA")
    }

    func testFileStoreIsNameGloballyUniqueUsesProtocolExtension() throws {
        var entry = makeTestEntry(policy: "open")
        entry.secrets["EXISTS"] = makeTestSecret()
        let file = VaultFile(version: 2, vaults: ["open": entry])
        try fileStore.saveVaultFile(file)

        XCTAssertFalse(try fileStore.isNameGloballyUnique("EXISTS"))
        XCTAssertTrue(try fileStore.isNameGloballyUnique("ABSENT"))
    }

    // MARK: - Protocol Conformance

    func testFileStoreConformsToVaultStoring() throws {
        let proto: any VaultStoring = fileStore
        XCTAssertFalse(proto.vaultExists())
        _ = proto.configDir
    }

    func testKeychainStoreConformsToVaultStoring() throws {
        let keychainStore = KeychainVaultStore(
            service: "com.keypo.vault.proto-test-\(UUID().uuidString)",
            accessGroup: nil
        )
        let proto: any VaultStoring = keychainStore
        XCTAssertFalse(proto.vaultExists())
        _ = proto.configDir
    }
}
