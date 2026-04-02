import Foundation
import Security

/// Keychain-backed storage for session metadata and re-wrapped secrets.
/// Follows the same patterns as KeychainMetadataStore.
public class SessionKeychainStore {
    private let service: String
    private let accessGroup: String?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        service: String = "com.keypo.session",
        accessGroup: String? = "FWJKHZ4TZD.com.keypo.signer"
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Query Helpers

    private func baseQuery(account: String? = nil, service serviceOverride: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceOverride ?? service,
        ]
        if let ag = accessGroup { q[kSecAttrAccessGroup as String] = ag }
        if let acct = account { q[kSecAttrAccount as String] = acct }
        return q
    }

    private func secretService(sessionName: String) -> String {
        "\(service).\(sessionName)"
    }

    // MARK: - Session Metadata CRUD

    /// Save session metadata with the temp SE key's dataRepresentation.
    /// kSecValueData = JSON-encoded SessionMetadata
    /// kSecAttrGeneric = raw Data (temp key dataRepresentation)
    public func saveSession(_ metadata: SessionMetadata, tempKeyDataRep: Data) throws {
        let metadataJSON = try Self.encoder.encode(metadata)

        var q = baseQuery(account: metadata.name)
        q[kSecValueData as String] = metadataJSON
        q[kSecAttrGeneric as String] = tempKeyDataRep
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(q as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Upsert: update existing item
            let query = baseQuery(account: metadata.name)
            let attrs: [String: Any] = [
                kSecValueData as String: metadataJSON,
                kSecAttrGeneric as String: tempKeyDataRep,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SessionError.keychainError("update session failed: OSStatus \(updateStatus)")
            }
            return
        }
        guard status == errSecSuccess else {
            throw SessionError.keychainError("save session failed: OSStatus \(status)")
        }
    }

    /// Load session metadata and temp key dataRepresentation by name.
    public func loadSession(name: String) -> (metadata: SessionMetadata, tempKeyDataRep: Data)? {
        var query = baseQuery(account: name)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let item = result as? [String: Any],
              let valueData = item[kSecValueData as String] as? Data,
              let genericData = item[kSecAttrGeneric as String] as? Data else {
            return nil
        }

        guard let metadata = try? Self.decoder.decode(SessionMetadata.self, from: valueData) else {
            return nil
        }

        return (metadata: metadata, tempKeyDataRep: genericData)
    }

    /// Update session metadata (e.g., decrement usesRemaining).
    public func updateSessionMetadata(_ metadata: SessionMetadata) throws {
        let metadataJSON = try Self.encoder.encode(metadata)
        let query = baseQuery(account: metadata.name)
        let attrs: [String: Any] = [kSecValueData as String: metadataJSON]

        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw SessionError.sessionNotFound(metadata.name)
            }
            throw SessionError.keychainError("update session metadata failed: OSStatus \(status)")
        }
    }

    /// List all sessions (attributes-only query, then fetch individually).
    public func listSessions() throws -> [(metadata: SessionMetadata, tempKeyDataRep: Data)] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return [] }
            throw SessionError.keychainError("list sessions failed: OSStatus \(status)")
        }
        guard let result = result else { return [] }

        // kSecMatchLimitAll returns [[String: Any]] for multiple, [String: Any] for one
        var items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let single = result as? [String: Any] {
            items = [single]
        } else {
            return []
        }

        // Fetch full data for each session individually
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            return loadSession(name: account)
        }
    }

    // MARK: - Session Secret CRUD

    /// Save one re-wrapped secret for a session.
    public func saveSessionSecret(sessionName: String, secretName: String, encrypted: EncryptedSecret) throws {
        let secretJSON = try Self.encoder.encode(encrypted)
        let svc = secretService(sessionName: sessionName)

        var q = baseQuery(account: secretName, service: svc)
        q[kSecValueData as String] = secretJSON
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(q as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let query = baseQuery(account: secretName, service: svc)
            let attrs: [String: Any] = [kSecValueData as String: secretJSON]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SessionError.keychainError("update session secret failed: OSStatus \(updateStatus)")
            }
            return
        }
        guard status == errSecSuccess else {
            throw SessionError.keychainError("save session secret failed: OSStatus \(status)")
        }
    }

    /// Load one re-wrapped secret.
    public func loadSessionSecret(sessionName: String, secretName: String) -> EncryptedSecret? {
        let svc = secretService(sessionName: sessionName)
        var query = baseQuery(account: secretName, service: svc)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = try? Self.decoder.decode(EncryptedSecret.self, from: data) else {
            return nil
        }
        return secret
    }

    /// Load all re-wrapped secrets for a session.
    public func loadAllSessionSecrets(sessionName: String) -> [String: EncryptedSecret] {
        let svc = secretService(sessionName: sessionName)
        var query = baseQuery(service: svc)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let result = result else { return [:] }

        var items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let single = result as? [String: Any] {
            items = [single]
        } else {
            return [:]
        }

        var secrets: [String: EncryptedSecret] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            if let secret = loadSessionSecret(sessionName: sessionName, secretName: account) {
                secrets[account] = secret
            }
        }
        return secrets
    }

    // MARK: - Deletion

    /// Delete a session: remove all secret items first, then metadata item.
    /// macOS SecItemDelete may only delete one item per broad query — iterate per secret.
    public func deleteSession(name: String) {
        // First, load metadata to get the list of secret names
        if let session = loadSession(name: name) {
            let svc = secretService(sessionName: name)
            for secretName in session.metadata.secrets {
                let q = baseQuery(account: secretName, service: svc)
                SecItemDelete(q as CFDictionary)
            }
        } else {
            // Fallback: try broad delete on secret service (best effort)
            let secretQuery = baseQuery(service: secretService(sessionName: name))
            SecItemDelete(secretQuery as CFDictionary)
        }

        // Delete metadata item
        let metaQuery = baseQuery(account: name)
        SecItemDelete(metaQuery as CFDictionary)
    }
}
