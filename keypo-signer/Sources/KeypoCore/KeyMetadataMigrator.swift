import Foundation

/// Migrates signing key metadata from file-based storage (keys.json) to Keychain.
/// Idempotent — safe to re-run. Keys already in Keychain are skipped.
public enum KeyMetadataMigrator {

    /// Migrate all keys from file store to Keychain store.
    /// - Returns: Number of keys newly added to Keychain (excludes already-existing).
    public static func migrateIfNeeded(
        from fileStore: KeyMetadataStore,
        to keychainStore: KeychainMetadataStore
    ) throws -> Int {
        // Load keys from file store. Handle corrupt keys.json gracefully.
        let fileKeys: [KeyMetadata]
        do {
            fileKeys = try fileStore.loadKeys()
        } catch KeypoError.corruptMetadata {
            return 0 // Corrupt keys.json — skip migration, don't block Keychain store
        }
        guard !fileKeys.isEmpty else { return 0 }

        // Build set of existing keychain keyIds
        let existingKeys = try keychainStore.loadKeys()
        let existingKeyIds = Set(existingKeys.map { $0.keyId })

        // Migrate keys not already in Keychain
        var migratedCount = 0
        for key in fileKeys where !existingKeyIds.contains(key.keyId) {
            try keychainStore.addKey(key)
            migratedCount += 1
        }

        // Verification: all expected keys must exist in Keychain
        let postKeyIds = Set(try keychainStore.loadKeys().map { $0.keyId })
        let expectedKeyIds = existingKeyIds.union(Set(fileKeys.map { $0.keyId }))
        guard expectedKeyIds.isSubset(of: postKeyIds) else {
            throw KeypoError.storeError("migration verification failed")
        }

        // Rename keys.json → keys.json.migrated (handle existing .migrated)
        let keysFileURL = fileStore.configDir.appendingPathComponent("keys.json")
        let migratedURL = keysFileURL.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: migratedURL)
        try FileManager.default.moveItem(at: keysFileURL, to: migratedURL)

        return migratedCount
    }
}
