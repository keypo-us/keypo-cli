import Foundation
import Security

/// Keychain-backed implementation of VaultStoring.
/// Stores one kSecClassGenericPassword item per policy tier, scoped to the app's
/// code signing identity via kSecAttrAccessGroup.
public class KeychainVaultStore: VaultStoring {
    public let configDir: URL
    private let service: String
    private let accessGroup: String?

    /// Conservative size limit per Keychain item (50 KB).
    /// A tier with 100 secrets is roughly 30-50 KB of JSON.
    private static let maxItemSize = 50_000

    public init(
        configDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".keypo"),
        service: String = "com.keypo.vault",
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

    // MARK: - Encoding

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
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
    /// kSecAttrAccessible and kSecAttrSynchronizable are NOT included — only set on add.
    private func baseQuery(policy: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let ag = accessGroup { q[kSecAttrAccessGroup as String] = ag }
        if let p = policy { q[kSecAttrAccount as String] = p }
        return q
    }

    /// Fetch a single VaultEntry by policy name.
    private func fetchEntry(policy: String) throws -> VaultEntry? {
        var query = baseQuery(policy: policy)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw VaultError.serializationFailed("failed to fetch vault entry '\(policy)': OSStatus \(status)")
        }
        guard let data = result as? Data else { return nil }

        do {
            return try Self.decoder.decode(VaultEntry.self, from: data)
        } catch {
            throw VaultError.serializationFailed("corrupt vault entry '\(policy)': \(error)")
        }
    }

    /// Get all policy names currently stored in Keychain.
    private func existingPolicies() -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result = result else { return [] }

        // kSecMatchLimitAll returns [[String: Any]] for multiple items,
        // but [String: Any] for exactly one item (macOS Keychain API quirk).
        var items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let single = result as? [String: Any] {
            items = [single]
        } else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - VaultStoring

    public func vaultExists() -> Bool {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    public func loadVaultFile() throws -> VaultFile {
        let policies = existingPolicies()
        guard !policies.isEmpty else {
            throw VaultError.integrityCheckFailed("vault not initialized")
        }

        var vaults: [String: VaultEntry] = [:]
        for policy in policies {
            if let entry = try fetchEntry(policy: policy) {
                vaults[policy] = entry
            }
        }

        guard !vaults.isEmpty else {
            throw VaultError.integrityCheckFailed("vault not initialized")
        }

        return VaultFile(version: 2, vaults: vaults)
    }

    public func saveVaultFile(_ file: VaultFile) throws {
        // Save/update each tier
        for (policyName, entry) in file.vaults {
            let data = try Self.encoder.encode(entry)

            // Size guard
            guard data.count <= Self.maxItemSize else {
                throw VaultError.serializationFailed(
                    "vault tier '\(policyName)' exceeds Keychain item size limit " +
                    "(\(data.count) bytes, max \(Self.maxItemSize))"
                )
            }

            // Try update first
            let query = baseQuery(policy: policyName)
            let attrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

            if updateStatus == errSecItemNotFound {
                // Item doesn't exist yet — add it
                var addQuery = baseQuery(policy: policyName)
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                // kSecAttrSynchronizable defaults to false — no need to set explicitly

                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                if addStatus == -34018 {
                    throw VaultError.serializationFailed("Keychain access denied — missing entitlement (OSStatus -34018)")
                }
                guard addStatus == errSecSuccess else {
                    throw VaultError.serializationFailed("failed to add vault tier '\(policyName)': OSStatus \(addStatus)")
                }
            } else if updateStatus != errSecSuccess {
                throw VaultError.serializationFailed("failed to update vault tier '\(policyName)': OSStatus \(updateStatus)")
            }
        }

        // Clean up stale tiers not in the new VaultFile
        let existing = existingPolicies()
        let newPolicies = Set(file.vaults.keys)
        for stale in existing where !newPolicies.contains(stale) {
            var query = baseQuery(policy: stale)
            query[kSecAttrSynchronizable as String] = false
            let status = SecItemDelete(query as CFDictionary)
            // Tolerate errSecItemNotFound (another process may have already cleaned up)
            // Log warning on unexpected errors — primary data was already written
            if status != errSecSuccess && status != errSecItemNotFound {
                // Best-effort cleanup; don't fail the save
            }
        }
    }

    public func deleteVaultFile() throws {
        // Delete each tier individually — SecItemDelete with a broad query
        // may only delete one item per call on some macOS versions.
        for policy in existingPolicies() {
            let query = baseQuery(policy: policy)
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw VaultError.serializationFailed("failed to delete vault tier '\(policy)': OSStatus \(status)")
            }
        }

        // Also remove vault.json.migrated from configDir if present (best-effort)
        let migratedURL = configDir.appendingPathComponent("vault.json.migrated")
        try? FileManager.default.removeItem(at: migratedURL)
    }
}
