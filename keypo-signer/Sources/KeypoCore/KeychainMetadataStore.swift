import Foundation
import Security

/// Keychain-backed implementation of KeyMetadataStoring.
/// Stores signing key metadata as kSecClassGenericPassword items scoped to the app's
/// code signing identity via kSecAttrAccessGroup.
public class KeychainMetadataStore: KeyMetadataStoring {
    public let configDir: URL
    private let service: String
    private let accessGroup: String?

    public init(
        configDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".keypo"),
        service: String = "com.keypo.signer.keys",
        accessGroup: String? = "FWJKHZ4TZD.com.keypo.signer"
    ) {
        self.configDir = configDir
        self.service = service
        self.accessGroup = accessGroup
        // Ensure config dir exists — BackupStateManager and other code assumes ~/.keypo exists
        try? FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Blob Encoding

    /// Metadata stored in kSecAttrGeneric as JSON-encoded Data.
    private struct KeyMetadataBlob: Codable {
        var publicKey: String
        var applicationTag: String
        var policy: KeyPolicy
        var createdAt: Date
        var signingCount: Int
        var lastUsedAt: Date?
        var previousPublicKeys: [String]

        /// Memberwise init from KeyMetadata.
        init(from key: KeyMetadata) {
            self.publicKey = key.publicKey
            self.applicationTag = key.applicationTag
            self.policy = key.policy
            self.createdAt = key.createdAt
            self.signingCount = key.signingCount
            self.lastUsedAt = key.lastUsedAt
            self.previousPublicKeys = key.previousPublicKeys
        }

        /// Forward-compatible decoder — future fields must be optional with defaults.
        /// Unknown keys are silently ignored by Codable (intentional for forward compat).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            publicKey = try c.decode(String.self, forKey: .publicKey)
            applicationTag = try c.decode(String.self, forKey: .applicationTag)
            policy = try c.decode(KeyPolicy.self, forKey: .policy)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            signingCount = try c.decodeIfPresent(Int.self, forKey: .signingCount) ?? 0
            lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
            previousPublicKeys = try c.decodeIfPresent([String].self, forKey: .previousPublicKeys) ?? []
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Query Helpers

    /// Base query for all Keychain operations.
    /// kSecAttrAccessible is NOT included — it's only valid on add/replaceKey, not in read queries.
    private func baseQuery(keyId: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // kSecAttrSynchronizable is intentionally omitted from queries.
            // By default, SecItemCopyMatching excludes synchronizable items,
            // which is what we want (our items are non-synchronizable).
            // Setting false explicitly can cause errSecParam (-50) on some macOS versions.
        ]
        if let ag = accessGroup { q[kSecAttrAccessGroup as String] = ag }
        if let kid = keyId { q[kSecAttrAccount as String] = kid }
        return q
    }

    /// Decode a Keychain item dictionary into KeyMetadata.
    /// Shared by loadKeys and findKey.
    private func decodeItem(_ item: [String: Any]) throws -> KeyMetadata {
        guard let account = item[kSecAttrAccount as String] as? String else {
            throw KeypoError.storeError("Keychain item missing kSecAttrAccount")
        }
        guard let valueData = item[kSecValueData as String] as? Data else {
            throw KeypoError.storeError("Keychain item '\(account)' missing kSecValueData")
        }
        guard let genericData = item[kSecAttrGeneric as String] as? Data else {
            throw KeypoError.storeError("Keychain item '\(account)' missing kSecAttrGeneric")
        }

        let blob: KeyMetadataBlob
        do {
            blob = try Self.decoder.decode(KeyMetadataBlob.self, from: genericData)
        } catch {
            throw KeypoError.storeError("Keychain item '\(account)' has corrupt metadata blob: \(error)")
        }

        return KeyMetadata(
            keyId: account,
            applicationTag: blob.applicationTag,
            publicKey: blob.publicKey,
            policy: blob.policy,
            createdAt: blob.createdAt,
            signingCount: blob.signingCount,
            lastUsedAt: blob.lastUsedAt,
            previousPublicKeys: blob.previousPublicKeys,
            dataRepresentation: valueData.base64EncodedString()
        )
    }

    // MARK: - KeyMetadataStoring

    public func loadKeys() throws -> [KeyMetadata] {
        // kSecReturnData + kSecMatchLimitAll returns errSecParam (-50) on some macOS versions.
        // Workaround: query for attributes only (to get account names), then fetch each individually.
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return [] }
            throw KeypoError.storeError("failed to load keys: OSStatus \(status)")
        }
        guard let result = result else { return [] }

        // kSecMatchLimitAll returns [[String: Any]] for multiple items,
        // but [String: Any] for exactly one item (macOS Keychain API quirk).
        var items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let single = result as? [String: Any] {
            items = [single]
        } else {
            throw KeypoError.storeError("unexpected Keychain result type")
        }

        // Fetch full data for each key individually
        return try items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return try findKey(keyId: account)
        }
    }

    public func addKey(_ key: KeyMetadata) throws {
        guard let tokenData = Data(base64Encoded: key.dataRepresentation) else {
            throw KeypoError.storeError("corrupt dataRepresentation for key '\(key.keyId)'")
        }
        let blobData = try Self.encoder.encode(KeyMetadataBlob(from: key))

        var q = baseQuery(keyId: key.keyId)
        q[kSecValueData as String] = tokenData
        q[kSecAttrGeneric as String] = blobData
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(q as CFDictionary, nil)

        if status == errSecDuplicateItem {
            throw KeypoError.storeError("key '\(key.keyId)' already exists")
        }
        if status == -34018 {
            throw KeypoError.storeError("Keychain access denied — missing entitlement (OSStatus -34018)")
        }
        guard status == errSecSuccess else {
            throw KeypoError.storeError("addKey failed: OSStatus \(status)")
        }
    }

    public func removeKey(keyId: String) throws {
        let query = baseQuery(keyId: keyId)
        let status = SecItemDelete(query as CFDictionary)

        if status == errSecItemNotFound {
            return // No-op per protocol contract
        }
        if status == -34018 {
            throw KeypoError.storeError("Keychain access denied — missing entitlement (OSStatus -34018)")
        }
        guard status == errSecSuccess else {
            throw KeypoError.storeError("removeKey failed: OSStatus \(status)")
        }
    }

    public func updateKey(_ key: KeyMetadata) throws {
        // No pre-read or dataRepresentation immutability check (avoids TOCTOU).
        // The protocol contract says callers must not change dataRepresentation.
        // The file store enforces this cheaply in-memory; Keychain store trusts the contract
        // since the only dataRep-changing caller (RotateCommand) uses replaceKey.
        let blobData = try Self.encoder.encode(KeyMetadataBlob(from: key))
        let query = baseQuery(keyId: key.keyId)
        let attrs: [String: Any] = [kSecAttrGeneric as String: blobData]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeypoError.storeError("key '\(key.keyId)' not found")
            }
            throw KeypoError.storeError("updateKey failed: OSStatus \(status)")
        }
    }

    public func replaceKey(_ key: KeyMetadata) throws {
        // No pre-check (avoids TOCTOU). Single SecItemUpdate with both kSecValueData
        // and kSecAttrGeneric. kSecAttrAccessible defensively re-asserted on rotation.
        guard let tokenData = Data(base64Encoded: key.dataRepresentation) else {
            throw KeypoError.storeError("corrupt dataRepresentation for key '\(key.keyId)'")
        }
        let blobData = try Self.encoder.encode(KeyMetadataBlob(from: key))
        let query = baseQuery(keyId: key.keyId)
        let attrs: [String: Any] = [
            kSecValueData as String: tokenData,
            kSecAttrGeneric as String: blobData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeypoError.storeError("key '\(key.keyId)' not found")
            }
            throw KeypoError.storeError("replaceKey failed: OSStatus \(status)")
        }
    }

    public func incrementSignCount(keyId: String) throws {
        guard var key = try findKey(keyId: keyId) else {
            throw KeypoError.storeError("key '\(keyId)' not found")
        }
        key.signingCount += 1
        key.lastUsedAt = Date()

        let blobData = try Self.encoder.encode(KeyMetadataBlob(from: key))
        let query = baseQuery(keyId: keyId)
        let attrs: [String: Any] = [kSecAttrGeneric as String: blobData]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

        guard status == errSecSuccess else {
            throw KeypoError.storeError("incrementSignCount failed: OSStatus \(status)")
        }
    }

    public func findKey(keyId: String) throws -> KeyMetadata? {
        var query = baseQuery(keyId: keyId)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeypoError.storeError("findKey failed: OSStatus \(status)")
        }
        guard let item = result as? [String: Any] else {
            return nil
        }

        return try decodeItem(item)
    }
}
