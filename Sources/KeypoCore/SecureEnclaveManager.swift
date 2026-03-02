import Foundation
import CryptoKit
import Security
import LocalAuthentication

public class SecureEnclaveManager {

    public init() {}

    // MARK: - Key Creation

    public func createKey(policy: KeyPolicy) throws -> (dataRepresentation: Data, publicKey: Data) {
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

        let privateKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            privateKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
        } catch {
            throw KeypoError.creationFailed("SE key generation failed: \(error.localizedDescription)")
        }

        let dataRep = privateKey.dataRepresentation
        let publicKeyBytes = Data(privateKey.publicKey.x963Representation)

        return (dataRepresentation: dataRep, publicKey: publicKeyBytes)
    }

    // MARK: - Key Lookup

    /// Check if a key exists in the Secure Enclave by trying to load it from dataRepresentation.
    /// CryptoKit SE keys are not visible via SecItemCopyMatching without Keychain entitlements,
    /// so we verify existence by attempting to reconstruct the key from its opaque token.
    public func lookupKeyByDataRep(_ base64DataRep: String) -> Bool {
        guard let dataRep = Data(base64Encoded: base64DataRep) else {
            return false
        }
        do {
            _ = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRep)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Key Loading

    public func loadPrivateKey(dataRepresentation: Data) throws -> SecureEnclave.P256.Signing.PrivateKey {
        do {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
        } catch {
            throw KeypoError.keyMissing("failed to load SE key: \(error.localizedDescription)")
        }
    }

    // MARK: - Signing

    public func signData(_ data: Data, dataRepresentation: Data) throws -> Data {
        let privateKey = try loadPrivateKey(dataRepresentation: dataRepresentation)
        do {
            // Pass raw input bytes — CryptoKit hashes with SHA-256 internally (standard ES256)
            let signature = try privateKey.signature(for: data)
            return signature.derRepresentation
        } catch {
            throw KeypoError.signingFailed(error.localizedDescription)
        }
    }

    // MARK: - Key Deletion

    /// "Delete" a CryptoKit SE key. Since CryptoKit keys aren't visible via SecItemDelete
    /// without Keychain entitlements, the actual SE key can't be deleted via the Security
    /// framework. The dataRepresentation token becomes the only reference — when metadata
    /// is removed, the key becomes inaccessible (orphaned in the SE).
    /// For keys created with Keychain entitlements, SecItemDelete would work.
    public func deleteKey(dataRepresentation base64DataRep: String) {
        // Attempt to delete via Security framework in case entitlements are available.
        // This is best-effort — without entitlements, the key remains in the SE.
        guard let dataRep = Data(base64Encoded: base64DataRep) else { return }
        guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRep) else { return }

        let publicKeySHA1 = Data(Insecure.SHA1.hash(data: key.publicKey.x963Representation))
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationLabel as String: publicKeySHA1 as CFData,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Availability

    public func isAvailable() -> Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - System Info

    public func getChipName() -> String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var result = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &result, &size, nil, 0)
            return String(cString: result)
        }
        // Fallback to hw.chip (Apple Silicon)
        size = 0
        sysctlbyname("hw.chip", nil, &size, nil, 0)
        if size > 0 {
            var result = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.chip", &result, &size, nil, 0)
            return String(cString: result)
        }
        return "Unknown"
    }

    public func getMacOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion != 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}
