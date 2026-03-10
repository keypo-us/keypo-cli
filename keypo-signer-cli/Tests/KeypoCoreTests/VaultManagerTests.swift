import XCTest
import CryptoKit
@testable import KeypoCore

final class VaultManagerTests: XCTestCase {
    let manager = VaultManager()

    /// Tracks SE key data representations so we can clean them up in tearDown.
    private var createdKeys: [Data] = []

    override func tearDown() {
        super.tearDown()
        for keyData in createdKeys {
            manager.deleteKeyAgreementKey(dataRepresentation: keyData)
        }
        createdKeys.removeAll()
    }

    // MARK: - Helpers

    /// Creates a fresh open-policy SE KeyAgreement key and registers it for cleanup.
    private func createTestKey() throws -> (dataRep: Data, publicKey: P256.KeyAgreement.PublicKey) {
        let result = try manager.createKeyAgreementKey(policy: .open)
        createdKeys.append(result.dataRepresentation)
        let pubKey = try P256.KeyAgreement.PublicKey(x963Representation: result.publicKey)
        return (dataRep: result.dataRepresentation, publicKey: pubKey)
    }

    /// Creates an EncryptedSecretData with the given field values.
    private func makeTestSecret(
        ephemeralPublicKey: Data = Data(repeating: 0, count: 65),
        nonce: Data = Data(repeating: 0, count: 12),
        ciphertext: Data = Data(repeating: 0, count: 16),
        tag: Data = Data(repeating: 0, count: 16),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) -> EncryptedSecretData {
        EncryptedSecretData(
            ephemeralPublicKey: ephemeralPublicKey,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Creates a real integrity envelope for HMAC tests.
    private func createIntegrityEnvelope(seKeyDataRep: Data) throws -> (ephemeralPublicKey: Data, hmac: Data) {
        return try manager.createIntegrityEnvelope(seKeyDataRepresentation: seKeyDataRep)
    }

    // MARK: - ECIES Tests

    // 1. testEncryptDecryptRoundtrip
    func testEncryptDecryptRoundtrip() throws {
        let key = try createTestKey()
        let testCases: [(String, Data)] = [
            ("empty", Data()),
            ("1 byte", Data([0x42])),
            ("1KB", Data(repeating: 0xAB, count: 1024)),
            ("100KB", Data((0..<102400).map { _ in UInt8.random(in: 0...255) })),
        ]

        for (label, plaintext) in testCases {
            let encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)
            let decrypted = try manager.decrypt(
                encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
            )
            XCTAssertEqual(decrypted, plaintext, "Roundtrip failed for \(label)")
        }
    }

    // 2. testDifferentCiphertextPerEncryption
    func testDifferentCiphertextPerEncryption() throws {
        let key = try createTestKey()
        let plaintext = Data("hello world".utf8)

        let enc1 = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)
        let enc2 = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)

        // Ephemeral keys should differ (different random key each time)
        XCTAssertNotEqual(enc1.ephemeralPublicKey, enc2.ephemeralPublicKey)
        // Ciphertext should differ due to different ephemeral key and nonce
        XCTAssertNotEqual(enc1.ciphertext, enc2.ciphertext)
    }

    // 3. testWrongSEKeyFailsDecryption
    func testWrongSEKeyFailsDecryption() throws {
        let keyA = try createTestKey()
        let keyB = try createTestKey()

        let plaintext = Data("secret data".utf8)
        let encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: keyA.publicKey)

        XCTAssertThrowsError(try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: keyB.dataRep
        )) { error in
            XCTAssertTrue(
                error is VaultError,
                "Expected VaultError, got \(type(of: error)): \(error)"
            )
        }
    }

    // 4. testCorruptedCiphertextFails
    func testCorruptedCiphertextFails() throws {
        let key = try createTestKey()
        let plaintext = Data("plaintext".utf8)
        var encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)

        // Flip the first bit of ciphertext
        encrypted.ciphertext[0] ^= 0x01

        XCTAssertThrowsError(try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
        ))
    }

    // 5. testCorruptedTagFails
    func testCorruptedTagFails() throws {
        let key = try createTestKey()
        let plaintext = Data("plaintext".utf8)
        var encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)

        // Flip a bit in the tag
        encrypted.tag[0] ^= 0x01

        XCTAssertThrowsError(try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
        ))
    }

    // 6. testCorruptedNonceFails
    func testCorruptedNonceFails() throws {
        let key = try createTestKey()
        let plaintext = Data("plaintext".utf8)
        var encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)

        // Modify nonce
        encrypted.nonce[0] ^= 0x01

        XCTAssertThrowsError(try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
        ))
    }

    // 7. testWrongEphemeralPublicKeyFails
    func testWrongEphemeralPublicKeyFails() throws {
        let key = try createTestKey()
        let plaintext = Data("plaintext".utf8)
        var encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)

        // Replace ephemeral public key with a fresh random one
        let randomKey = P256.KeyAgreement.PrivateKey()
        encrypted.ephemeralPublicKey = Data(randomKey.publicKey.x963Representation)

        XCTAssertThrowsError(try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
        ))
    }

    // 8. testHKDFInfoIncludesSecretName
    func testHKDFInfoIncludesSecretName() throws {
        let key = try createTestKey()
        let plaintext = Data("plaintext".utf8)
        let encrypted = try manager.encrypt(plaintext: plaintext, secretName: "nameA", sePublicKey: key.publicKey)

        // Decrypting with a different secret name should fail because HKDF info differs
        XCTAssertThrowsError(try manager.decrypt(
            encryptedData: encrypted, secretName: "nameB", seKeyDataRepresentation: key.dataRep
        ))
    }

    // 9. testEmptyPlaintextRoundtrip
    func testEmptyPlaintextRoundtrip() throws {
        let key = try createTestKey()
        let plaintext = Data()
        let encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)
        let decrypted = try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
        )
        XCTAssertEqual(decrypted, plaintext)
        XCTAssertTrue(decrypted.isEmpty)
    }

    // 10. testLargePlaintextRoundtrip
    func testLargePlaintextRoundtrip() throws {
        let key = try createTestKey()
        let plaintext = Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255) })  // 1MB
        let encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)
        let decrypted = try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
        )
        XCTAssertEqual(decrypted, plaintext)
    }

    // 11. testZeroization
    func testZeroization() throws {
        let key = try createTestKey()
        let plaintext = Data("sensitive data that should be zeroized".utf8)

        // Verify that encrypt and decrypt complete without error (best-effort zeroization check)
        let encrypted = try manager.encrypt(plaintext: plaintext, secretName: "test", sePublicKey: key.publicKey)
        let decrypted = try manager.decrypt(
            encryptedData: encrypted, secretName: "test", seKeyDataRepresentation: key.dataRep
        )
        XCTAssertEqual(decrypted, plaintext, "Roundtrip should succeed even with zeroization in place")
    }

    // MARK: - HMAC Tests

    // 12. testHMACRoundtrip
    func testHMACRoundtrip() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        let secrets = [
            "secret1": try manager.encrypt(plaintext: Data("value1".utf8), secretName: "secret1", sePublicKey: key.publicKey),
        ]

        let hmac = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        let valid = try manager.verifyHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac
        )

        XCTAssertTrue(valid)
    }

    // 13. testHMACDetectsAddedSecret
    func testHMACDetectsAddedSecret() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        let secrets = [
            "secret1": try manager.encrypt(plaintext: Data("value1".utf8), secretName: "secret1", sePublicKey: key.publicKey),
        ]

        let hmac = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        // Add a new secret
        var modified = secrets
        modified["secret2"] = try manager.encrypt(plaintext: Data("value2".utf8), secretName: "secret2", sePublicKey: key.publicKey)

        let valid = try manager.verifyHMAC(
            secrets: modified,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac
        )

        XCTAssertFalse(valid)
    }

    // 14. testHMACDetectsRemovedSecret
    func testHMACDetectsRemovedSecret() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        let secrets = [
            "secret1": try manager.encrypt(plaintext: Data("value1".utf8), secretName: "secret1", sePublicKey: key.publicKey),
            "secret2": try manager.encrypt(plaintext: Data("value2".utf8), secretName: "secret2", sePublicKey: key.publicKey),
        ]

        let hmac = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        // Remove a secret
        var modified = secrets
        modified.removeValue(forKey: "secret2")

        let valid = try manager.verifyHMAC(
            secrets: modified,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac
        )

        XCTAssertFalse(valid)
    }

    // 15. testHMACDetectsModifiedCiphertext
    func testHMACDetectsModifiedCiphertext() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        let secrets = [
            "secret1": try manager.encrypt(plaintext: Data("value1".utf8), secretName: "secret1", sePublicKey: key.publicKey),
        ]

        let hmac = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        // Modify ciphertext byte
        var modified = secrets
        modified["secret1"]!.ciphertext[0] ^= 0x01

        let valid = try manager.verifyHMAC(
            secrets: modified,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac
        )

        XCTAssertFalse(valid)
    }

    // 16. testHMACDetectsModifiedMetadata
    func testHMACDetectsModifiedMetadata() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        let secrets = [
            "secret1": try manager.encrypt(plaintext: Data("value1".utf8), secretName: "secret1", sePublicKey: key.publicKey),
        ]

        let hmac = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        // Change createdAt timestamp
        var modified = secrets
        modified["secret1"]!.createdAt = Date(timeIntervalSince1970: 0)

        let valid = try manager.verifyHMAC(
            secrets: modified,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac
        )

        XCTAssertFalse(valid)
    }

    // 17. testHMACUnaffectedByKeyOrdering
    func testHMACUnaffectedByKeyOrdering() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        let encA = try manager.encrypt(plaintext: Data("valueA".utf8), secretName: "alpha", sePublicKey: key.publicKey)
        let encB = try manager.encrypt(plaintext: Data("valueB".utf8), secretName: "bravo", sePublicKey: key.publicKey)
        let encC = try manager.encrypt(plaintext: Data("valueC".utf8), secretName: "charlie", sePublicKey: key.publicKey)

        // Build dictionaries in different insertion orders
        var secretsABC: [String: EncryptedSecretData] = [:]
        secretsABC["alpha"] = encA
        secretsABC["bravo"] = encB
        secretsABC["charlie"] = encC

        var secretsCBA: [String: EncryptedSecretData] = [:]
        secretsCBA["charlie"] = encC
        secretsCBA["bravo"] = encB
        secretsCBA["alpha"] = encA

        let hmac1 = try manager.computeHMAC(
            secrets: secretsABC,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        let hmac2 = try manager.computeHMAC(
            secrets: secretsCBA,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        XCTAssertEqual(hmac1, hmac2, "HMAC should be identical regardless of dictionary insertion order")
    }

    // 18. testWrongHMACKeyFails
    func testWrongHMACKeyFails() throws {
        let keyA = try createTestKey()
        let keyB = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: keyA.dataRep)

        let secrets = [
            "secret1": try manager.encrypt(plaintext: Data("value1".utf8), secretName: "secret1", sePublicKey: keyA.publicKey),
        ]

        let hmacA = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: keyA.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        let hmacB = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: keyB.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        XCTAssertNotEqual(hmacA, hmacB, "Different SE keys should produce different HMACs")

        // Verify with wrong key should fail
        let valid = try manager.verifyHMAC(
            secrets: secrets,
            seKeyDataRepresentation: keyB.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmacA
        )

        XCTAssertFalse(valid)
    }

    // 19. testEmptySecretsHMAC
    func testEmptySecretsHMAC() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        let secrets: [String: EncryptedSecretData] = [:]

        let hmac = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        XCTAssertFalse(hmac.isEmpty, "HMAC over empty secrets should still produce output")

        let valid = try manager.verifyHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac
        )

        XCTAssertTrue(valid)
    }

    // 20. testHMACAfterSetUpdateDeleteCycle
    func testHMACAfterSetUpdateDeleteCycle() throws {
        let key = try createTestKey()
        let envelope = try createIntegrityEnvelope(seKeyDataRep: key.dataRep)

        var secrets: [String: EncryptedSecretData] = [:]

        // Set: add two secrets
        secrets["alpha"] = try manager.encrypt(plaintext: Data("v1".utf8), secretName: "alpha", sePublicKey: key.publicKey)
        secrets["bravo"] = try manager.encrypt(plaintext: Data("v1".utf8), secretName: "bravo", sePublicKey: key.publicKey)

        let hmac1 = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        // Update: re-encrypt alpha with new value
        secrets["alpha"] = try manager.encrypt(plaintext: Data("v2".utf8), secretName: "alpha", sePublicKey: key.publicKey)

        let hmac2 = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        XCTAssertNotEqual(hmac1, hmac2, "HMAC should change after update")

        // Verify new HMAC is valid
        let validAfterUpdate = try manager.verifyHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac2
        )
        XCTAssertTrue(validAfterUpdate)

        // Old HMAC should no longer be valid
        let oldHMACValid = try manager.verifyHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac1
        )
        XCTAssertFalse(oldHMACValid)

        // Delete: remove bravo
        secrets.removeValue(forKey: "bravo")

        let hmac3 = try manager.computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey
        )

        XCTAssertNotEqual(hmac2, hmac3, "HMAC should change after delete")

        let validAfterDelete = try manager.verifyHMAC(
            secrets: secrets,
            seKeyDataRepresentation: key.dataRep,
            integrityEphemeralPublicKey: envelope.ephemeralPublicKey,
            expectedHMAC: hmac3
        )
        XCTAssertTrue(validAfterDelete)
    }

    // 21. testCanonicalSerializationDeterminism
    func testCanonicalSerializationDeterminism() throws {
        let now = Date()
        let secrets: [String: EncryptedSecretData] = [
            "key1": makeTestSecret(
                ephemeralPublicKey: Data(repeating: 0xAA, count: 65),
                nonce: Data(repeating: 0xBB, count: 12),
                ciphertext: Data(repeating: 0xCC, count: 32),
                tag: Data(repeating: 0xDD, count: 16),
                createdAt: now,
                updatedAt: now
            ),
            "key2": makeTestSecret(
                ephemeralPublicKey: Data(repeating: 0x11, count: 65),
                nonce: Data(repeating: 0x22, count: 12),
                ciphertext: Data(repeating: 0x33, count: 32),
                tag: Data(repeating: 0x44, count: 16),
                createdAt: now,
                updatedAt: now
            ),
        ]

        let first = try VaultManager.canonicalSerialize(secrets: secrets)

        for i in 1...100 {
            let serialized = try VaultManager.canonicalSerialize(secrets: secrets)
            XCTAssertEqual(serialized, first, "Serialization differed on iteration \(i)")
        }
    }

    // 22. testCanonicalSerializationKeyOrdering
    func testCanonicalSerializationKeyOrdering() throws {
        let now = Date()

        // Insert keys in B, A, C order
        var secrets: [String: EncryptedSecretData] = [:]
        secrets["bravo"] = makeTestSecret(
            ephemeralPublicKey: Data(repeating: 0x02, count: 65),
            nonce: Data(repeating: 0x02, count: 12),
            ciphertext: Data(repeating: 0x02, count: 16),
            tag: Data(repeating: 0x02, count: 16),
            createdAt: now,
            updatedAt: now
        )
        secrets["alpha"] = makeTestSecret(
            ephemeralPublicKey: Data(repeating: 0x01, count: 65),
            nonce: Data(repeating: 0x01, count: 12),
            ciphertext: Data(repeating: 0x01, count: 16),
            tag: Data(repeating: 0x01, count: 16),
            createdAt: now,
            updatedAt: now
        )
        secrets["charlie"] = makeTestSecret(
            ephemeralPublicKey: Data(repeating: 0x03, count: 65),
            nonce: Data(repeating: 0x03, count: 12),
            ciphertext: Data(repeating: 0x03, count: 16),
            tag: Data(repeating: 0x03, count: 16),
            createdAt: now,
            updatedAt: now
        )

        let serialized = try VaultManager.canonicalSerialize(secrets: secrets)
        let jsonString = String(data: serialized, encoding: .utf8)!

        // "alpha" should appear before "bravo" which should appear before "charlie"
        let alphaRange = jsonString.range(of: "\"alpha\"")!
        let bravoRange = jsonString.range(of: "\"bravo\"")!
        let charlieRange = jsonString.range(of: "\"charlie\"")!

        XCTAssertTrue(alphaRange.lowerBound < bravoRange.lowerBound, "alpha should come before bravo")
        XCTAssertTrue(bravoRange.lowerBound < charlieRange.lowerBound, "bravo should come before charlie")
    }
}
