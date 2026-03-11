import Foundation
import CryptoKit
import Security
import LocalAuthentication

// MARK: - Vault Errors

public enum VaultError: Error, CustomStringConvertible {
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidEphemeralKey(String)
    case integrityCheckFailed(String)
    case serializationFailed(String)
    case authenticationCancelled

    public var description: String {
        switch self {
        case .encryptionFailed(let msg): return "encryption failed: \(msg)"
        case .decryptionFailed(let msg): return "decryption failed: \(msg)"
        case .invalidEphemeralKey(let msg): return "invalid ephemeral key: \(msg)"
        case .integrityCheckFailed(let msg): return "integrity check failed: \(msg)"
        case .serializationFailed(let msg): return "serialization failed: \(msg)"
        case .authenticationCancelled: return "authentication was cancelled by the user"
        }
    }
}

// MARK: - Encrypted Secret Data

public struct EncryptedSecretData: Codable, Equatable {
    public var ephemeralPublicKey: Data  // x963 representation
    public var nonce: Data              // 12 bytes
    public var ciphertext: Data
    public var tag: Data                // 16 bytes
    public var createdAt: Date
    public var updatedAt: Date

    public init(ephemeralPublicKey: Data, nonce: Data, ciphertext: Data, tag: Data,
                createdAt: Date, updatedAt: Date) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Vault Manager

public class VaultManager {

    public init() {}

    // MARK: - SE KeyAgreement Key Creation

    public func createKeyAgreementKey(policy: KeyPolicy) throws -> (dataRepresentation: Data, publicKey: Data) {
        guard SecureEnclave.isAvailable else {
            throw KeypoError.seUnavailable
        }

        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        switch policy {
        case .open:
            break
        case .passcode:
            flags.insert(.devicePasscode)
        case .biometric:
            flags.insert(.biometryCurrentSet)
        }

        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        ) else {
            throw KeypoError.creationFailed("failed to create access control: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: accessControl)
        } catch {
            throw KeypoError.creationFailed("SE KeyAgreement key generation failed: \(error.localizedDescription)")
        }

        let dataRep = privateKey.dataRepresentation
        let publicKeyBytes = Data(privateKey.publicKey.x963Representation)

        return (dataRepresentation: dataRep, publicKey: publicKeyBytes)
    }

    // MARK: - SE KeyAgreement Key Deletion

    public func deleteKeyAgreementKey(dataRepresentation: Data) {
        guard let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: dataRepresentation) else {
            return
        }

        let publicKeySHA1 = Data(Insecure.SHA1.hash(data: key.publicKey.x963Representation))
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationLabel as String: publicKeySHA1 as CFData,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - ECIES Encryption

    public func encrypt(plaintext: Data, secretName: String, sePublicKey: P256.KeyAgreement.PublicKey) throws -> EncryptedSecretData {
        let ephemeralPrivate = P256.KeyAgreement.PrivateKey()

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: sePublicKey)
        } catch {
            throw VaultError.encryptionFailed("ECDH failed: \(error.localizedDescription)")
        }

        let info = Data("keypo-vault-v1".utf8) + Data(secretName.utf8)
        var symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        defer { symmetricKey = SymmetricKey(size: .bits256) }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
        } catch {
            throw VaultError.encryptionFailed("AES-GCM seal failed: \(error.localizedDescription)")
        }

        let now = Date()
        return EncryptedSecretData(
            ephemeralPublicKey: Data(ephemeralPrivate.publicKey.x963Representation),
            nonce: Data(sealedBox.nonce),
            ciphertext: Data(sealedBox.ciphertext),
            tag: Data(sealedBox.tag),
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - ECIES Decryption

    public func decrypt(encryptedData: EncryptedSecretData, secretName: String,
                        seKeyDataRepresentation: Data, authContext: LAContext? = nil) throws -> Data {
        let sePrivateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            if let context = authContext {
                sePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: seKeyDataRepresentation,
                    authenticationContext: context
                )
            } else {
                sePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: seKeyDataRepresentation
                )
            }
        } catch {
            if isAuthenticationCancelled(error) {
                throw VaultError.authenticationCancelled
            }
            throw KeypoError.keyMissing("failed to load SE KeyAgreement key: \(error.localizedDescription)")
        }

        let ephemeralPublicKey: P256.KeyAgreement.PublicKey
        do {
            ephemeralPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: encryptedData.ephemeralPublicKey)
        } catch {
            throw VaultError.invalidEphemeralKey("failed to reconstruct ephemeral public key: \(error.localizedDescription)")
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try sePrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        } catch {
            if isAuthenticationCancelled(error) {
                throw VaultError.authenticationCancelled
            }
            throw VaultError.decryptionFailed("ECDH failed: \(error.localizedDescription)")
        }

        let info = Data("keypo-vault-v1".utf8) + Data(secretName.utf8)
        var symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        defer { symmetricKey = SymmetricKey(size: .bits256) }

        let sealedBox: AES.GCM.SealedBox
        do {
            let nonce = try AES.GCM.Nonce(data: encryptedData.nonce)
            sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: encryptedData.ciphertext,
                tag: encryptedData.tag
            )
        } catch {
            throw VaultError.decryptionFailed("failed to reconstruct sealed box: \(error.localizedDescription)")
        }

        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw VaultError.decryptionFailed("AES-GCM open failed: \(error.localizedDescription)")
        }

        // Copy result before zeroizing
        let result = Data(plaintext)
        plaintext.resetBytes(in: 0..<plaintext.count)
        return result
    }

    // MARK: - Integrity Envelope Creation

    public func createIntegrityEnvelope(seKeyDataRepresentation: Data,
                                        authContext: LAContext? = nil) throws -> (ephemeralPublicKey: Data, hmac: Data) {
        let sePrivateKey = try loadSEKeyAgreementKey(dataRepresentation: seKeyDataRepresentation, authContext: authContext)

        let ephemeralPrivate = P256.KeyAgreement.PrivateKey()

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try sePrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPrivate.publicKey)
        } catch {
            if isAuthenticationCancelled(error) {
                throw VaultError.authenticationCancelled
            }
            throw VaultError.integrityCheckFailed("ECDH failed: \(error.localizedDescription)")
        }

        let info = Data("keypo-vault-integrity-v1".utf8)
        var hmacKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        defer { hmacKey = SymmetricKey(size: .bits256) }

        let emptySecrets: [String: EncryptedSecretData] = [:]
        let serialized = try VaultManager.canonicalSerialize(secrets: emptySecrets)
        let hmac = HMAC<SHA256>.authenticationCode(for: serialized, using: hmacKey)

        let ephemeralPublicKeyData = Data(ephemeralPrivate.publicKey.x963Representation)
        return (ephemeralPublicKey: ephemeralPublicKeyData, hmac: Data(hmac))
    }

    // MARK: - HMAC Computation

    public func computeHMAC(secrets: [String: EncryptedSecretData],
                            seKeyDataRepresentation: Data,
                            integrityEphemeralPublicKey: Data,
                            authContext: LAContext? = nil) throws -> Data {
        let sePrivateKey = try loadSEKeyAgreementKey(dataRepresentation: seKeyDataRepresentation, authContext: authContext)

        let ephemeralPublicKey: P256.KeyAgreement.PublicKey
        do {
            ephemeralPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: integrityEphemeralPublicKey)
        } catch {
            throw VaultError.invalidEphemeralKey("failed to reconstruct integrity ephemeral public key: \(error.localizedDescription)")
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try sePrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        } catch {
            if isAuthenticationCancelled(error) {
                throw VaultError.authenticationCancelled
            }
            throw VaultError.integrityCheckFailed("ECDH failed: \(error.localizedDescription)")
        }

        let info = Data("keypo-vault-integrity-v1".utf8)
        var hmacKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        defer { hmacKey = SymmetricKey(size: .bits256) }

        let serialized = try VaultManager.canonicalSerialize(secrets: secrets)
        let hmac = HMAC<SHA256>.authenticationCode(for: serialized, using: hmacKey)

        return Data(hmac)
    }

    // MARK: - HMAC Verification

    public func verifyHMAC(secrets: [String: EncryptedSecretData],
                           seKeyDataRepresentation: Data,
                           integrityEphemeralPublicKey: Data,
                           expectedHMAC: Data,
                           authContext: LAContext? = nil) throws -> Bool {
        let computed = try computeHMAC(
            secrets: secrets,
            seKeyDataRepresentation: seKeyDataRepresentation,
            integrityEphemeralPublicKey: integrityEphemeralPublicKey,
            authContext: authContext
        )
        // Constant-time comparison via CryptoKit
        return computed == expectedHMAC
    }

    // MARK: - Canonical Serialization

    public static func canonicalSerialize(secrets: [String: EncryptedSecretData]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(secrets)
        } catch {
            throw VaultError.serializationFailed("failed to serialize secrets: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func loadSEKeyAgreementKey(dataRepresentation: Data,
                                       authContext: LAContext? = nil) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        do {
            if let context = authContext {
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: dataRepresentation,
                    authenticationContext: context
                )
            } else {
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: dataRepresentation
                )
            }
        } catch {
            if isAuthenticationCancelled(error) {
                throw VaultError.authenticationCancelled
            }
            throw KeypoError.keyMissing("failed to load SE KeyAgreement key: \(error.localizedDescription)")
        }
    }

    private func isAuthenticationCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        // errSecUserCanceled (-128), LAError.userCancel (-2), or string match as fallback
        if nsError.code == -128 || nsError.code == -2 {
            return true
        }
        let desc = error.localizedDescription.lowercased()
        return desc.contains("cancel")
    }
}
