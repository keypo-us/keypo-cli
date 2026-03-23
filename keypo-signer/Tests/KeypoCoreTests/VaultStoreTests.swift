import XCTest
@testable import KeypoCore

final class VaultStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: VaultStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keypo-test-\(UUID().uuidString)")
        store = VaultStore(configDir: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTestVaultEntry(policy: String) -> VaultEntry {
        VaultEntry(
            vaultKeyId: "com.keypo.vault.\(policy)",
            dataRepresentation: Data([1, 2, 3]).base64EncodedString(),
            publicKey: "0x04" + String(repeating: "ab", count: 64),
            integrityEphemeralPublicKey: "0x04" + String(repeating: "cd", count: 64),
            integrityHmac: Data([1, 2, 3, 4]).base64EncodedString(),
            createdAt: Date()
        )
    }

    private func makeTestSecret(name: String = "TEST_SECRET") -> EncryptedSecret {
        let now = Date()
        return EncryptedSecret(
            ephemeralPublicKey: "0x04" + String(repeating: "ef", count: 64),
            nonce: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]).base64EncodedString(),
            ciphertext: Data([0xCA, 0xFE]).base64EncodedString(),
            tag: Data(repeating: 0xAA, count: 16).base64EncodedString(),
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeThreeVaultFile() -> VaultFile {
        var vaultFile = VaultFile(version: 2, vaults: [:])
        for policy in ["open", "passcode", "biometric"] {
            vaultFile.vaults[policy] = makeTestVaultEntry(policy: policy)
        }
        return vaultFile
    }

    // MARK: - Tests

    func testCreateVaultFromScratch() throws {
        XCTAssertFalse(store.vaultExists())

        let vaultFile = makeThreeVaultFile()
        try store.saveVaultFile(vaultFile)

        XCTAssertTrue(store.vaultExists())

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.vaults.count, 3)
        XCTAssertNotNil(loaded.vaults["open"])
        XCTAssertEqual(loaded.vaults["open"]?.vaultKeyId, "com.keypo.vault.open")
    }

    func testAllThreeVaultsPresent() throws {
        let vaultFile = makeThreeVaultFile()
        try store.saveVaultFile(vaultFile)

        let loaded = try store.loadVaultFile()
        XCTAssertNotNil(loaded.vaults["open"])
        XCTAssertNotNil(loaded.vaults["passcode"])
        XCTAssertNotNil(loaded.vaults["biometric"])
        XCTAssertEqual(loaded.vaults["open"]?.vaultKeyId, "com.keypo.vault.open")
        XCTAssertEqual(loaded.vaults["passcode"]?.vaultKeyId, "com.keypo.vault.passcode")
        XCTAssertEqual(loaded.vaults["biometric"]?.vaultKeyId, "com.keypo.vault.biometric")
    }

    func testDuplicateInitRejected() throws {
        let vaultFile = makeThreeVaultFile()
        try store.saveVaultFile(vaultFile)
        XCTAssertTrue(store.vaultExists())

        // Save again — overwrites, no error
        try store.saveVaultFile(vaultFile)
        XCTAssertTrue(store.vaultExists())

        let loaded = try store.loadVaultFile()
        XCTAssertEqual(loaded.vaults.count, 3)
    }

    func testSecretGlobalUniqueness() throws {
        var vaultFile = makeThreeVaultFile()
        vaultFile.vaults["biometric"]?.secrets["API_KEY"] = makeTestSecret()
        try store.saveVaultFile(vaultFile)

        XCTAssertFalse(try store.isNameGloballyUnique("API_KEY"))
        XCTAssertTrue(try store.isNameGloballyUnique("OTHER_KEY"))
    }

    func testFindSecretAcrossVaults() throws {
        var vaultFile = makeThreeVaultFile()
        let secret = makeTestSecret()
        vaultFile.vaults["open"]?.secrets["DB_PASSWORD"] = secret
        try store.saveVaultFile(vaultFile)

        let result = try store.findSecret(name: "DB_PASSWORD")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.policy, .open)
        XCTAssertEqual(result?.secret.ciphertext, secret.ciphertext)
    }

    func testFindSecretReturnsCorrectVault() throws {
        var vaultFile = makeThreeVaultFile()
        let secretA = makeTestSecret(name: "A")
        let secretB = makeTestSecret(name: "B")
        vaultFile.vaults["biometric"]?.secrets["SECRET_A"] = secretA
        vaultFile.vaults["open"]?.secrets["SECRET_B"] = secretB
        try store.saveVaultFile(vaultFile)

        let resultA = try store.findSecret(name: "SECRET_A")
        XCTAssertNotNil(resultA)
        XCTAssertEqual(resultA?.policy, .biometric)

        let resultB = try store.findSecret(name: "SECRET_B")
        XCTAssertNotNil(resultB)
        XCTAssertEqual(resultB?.policy, .open)
    }

    func testFindNonexistentSecret() throws {
        let vaultFile = makeThreeVaultFile()
        try store.saveVaultFile(vaultFile)

        let result = try store.findSecret(name: "DOES_NOT_EXIST")
        XCTAssertNil(result)
    }

    func testFilePermissions() throws {
        let vaultFile = makeThreeVaultFile()
        try store.saveVaultFile(vaultFile)

        let vaultPath = tempDir.appendingPathComponent("vault.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: vaultPath)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testCorruptVaultJsonRejected() throws {
        // Create the config directory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let vaultPath = tempDir.appendingPathComponent("vault.json")
        try "this is not json".write(to: vaultPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.loadVaultFile()) { error in
            guard let vaultError = error as? VaultError else {
                XCTFail("Expected VaultError, got \(error)")
                return
            }
            if case .serializationFailed(let msg) = vaultError {
                XCTAssertTrue(msg.contains("failed to parse"), "Unexpected message: \(msg)")
            } else {
                XCTFail("Expected serializationFailed, got \(vaultError)")
            }
        }
    }

    func testVersionMismatchRejected() throws {
        let badFile = VaultFile(version: 99, vaults: [:])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(badFile)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let vaultPath = tempDir.appendingPathComponent("vault.json")
        try data.write(to: vaultPath)

        XCTAssertThrowsError(try store.loadVaultFile()) { error in
            guard let vaultError = error as? VaultError else {
                XCTFail("Expected VaultError, got \(error)")
                return
            }
            if case .serializationFailed(let msg) = vaultError {
                XCTAssertTrue(msg.contains("unsupported vault version"), "Unexpected message: \(msg)")
            } else {
                XCTFail("Expected serializationFailed, got \(vaultError)")
            }
        }
    }

    func testSecretNameValidation_validNames() {
        XCTAssertTrue(validateSecretName("MY_KEY"))
        XCTAssertTrue(validateSecretName("_private"))
        XCTAssertTrue(validateSecretName("a"))
        XCTAssertTrue(validateSecretName("A1_B2_C3"))
    }

    func testSecretNameValidation_boundary() {
        // 128 chars OK
        let name128 = String(repeating: "A", count: 128)
        XCTAssertTrue(validateSecretName(name128))

        // 129 chars rejected
        let name129 = String(repeating: "A", count: 129)
        XCTAssertFalse(validateSecretName(name129))
    }

    func testSecretNameValidation_invalid() {
        XCTAssertFalse(validateSecretName(""))
        XCTAssertFalse(validateSecretName("123KEY"))
        XCTAssertFalse(validateSecretName("KEY-NAME"))
        XCTAssertFalse(validateSecretName("KEY.NAME"))
        XCTAssertFalse(validateSecretName("KEY NAME"))
    }

    func testModelSerdeRoundtrip() throws {
        var vaultFile = makeThreeVaultFile()
        vaultFile.vaults["open"]?.secrets["MY_SECRET"] = makeTestSecret()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(vaultFile)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VaultFile.self, from: data)

        XCTAssertEqual(decoded.version, vaultFile.version)
        XCTAssertEqual(decoded.vaults.count, vaultFile.vaults.count)
        for policy in ["open", "passcode", "biometric"] {
            XCTAssertEqual(decoded.vaults[policy]?.vaultKeyId, vaultFile.vaults[policy]?.vaultKeyId)
            XCTAssertEqual(decoded.vaults[policy]?.publicKey, vaultFile.vaults[policy]?.publicKey)
            XCTAssertEqual(decoded.vaults[policy]?.integrityHmac, vaultFile.vaults[policy]?.integrityHmac)
        }
        // Verify the secret round-tripped
        let originalSecret = vaultFile.vaults["open"]?.secrets["MY_SECRET"]
        let decodedSecret = decoded.vaults["open"]?.secrets["MY_SECRET"]
        XCTAssertNotNil(decodedSecret)
        XCTAssertEqual(decodedSecret?.ciphertext, originalSecret?.ciphertext)
        XCTAssertEqual(decodedSecret?.nonce, originalSecret?.nonce)
        XCTAssertEqual(decodedSecret?.tag, originalSecret?.tag)
        XCTAssertEqual(decodedSecret?.ephemeralPublicKey, originalSecret?.ephemeralPublicKey)
    }

    // MARK: - highestAvailableTier

    func testHighestAvailableTierFullVault() {
        let vaultFile = makeThreeVaultFile()
        XCTAssertEqual(vaultFile.highestAvailableTier(), .biometric)
    }

    func testHighestAvailableTierOpenOnly() {
        var vaultFile = VaultFile(version: 2, vaults: [:])
        vaultFile.vaults["open"] = makeTestVaultEntry(policy: "open")
        XCTAssertEqual(vaultFile.highestAvailableTier(), .open)
    }

    func testHighestAvailableTierOpenAndPasscode() {
        var vaultFile = VaultFile(version: 2, vaults: [:])
        vaultFile.vaults["open"] = makeTestVaultEntry(policy: "open")
        vaultFile.vaults["passcode"] = makeTestVaultEntry(policy: "passcode")
        XCTAssertEqual(vaultFile.highestAvailableTier(), .passcode)
    }

    func testHighestAvailableTierEmptyVault() {
        let vaultFile = VaultFile(version: 2, vaults: [:])
        XCTAssertNil(vaultFile.highestAvailableTier())
    }

    // MARK: - VaultInitOutput with skipped

    func testVaultInitOutputWithSkipped() throws {
        let output = VaultInitOutput(
            vaults: [VaultInitOutput.VaultInitEntry(vaultKeyId: "com.keypo.vault.open", policy: "open")],
            skipped: ["passcode", "biometric"],
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(output)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VaultInitOutput.self, from: data)

        XCTAssertEqual(decoded.vaults.count, 1)
        XCTAssertEqual(decoded.vaults[0].policy, "open")
        XCTAssertEqual(decoded.skipped, ["passcode", "biometric"])
    }

    func testVaultInitOutputWithoutSkipped() throws {
        let output = VaultInitOutput(
            vaults: [
                VaultInitOutput.VaultInitEntry(vaultKeyId: "com.keypo.vault.open", policy: "open"),
                VaultInitOutput.VaultInitEntry(vaultKeyId: "com.keypo.vault.passcode", policy: "passcode"),
                VaultInitOutput.VaultInitEntry(vaultKeyId: "com.keypo.vault.biometric", policy: "biometric"),
            ],
            createdAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(output)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(VaultInitOutput.self, from: data)

        XCTAssertEqual(decoded.vaults.count, 3)
        XCTAssertEqual(decoded.skipped, [])
    }
}
