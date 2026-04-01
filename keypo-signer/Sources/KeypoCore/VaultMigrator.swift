import Foundation

/// Migrates vault data from file-based storage (vault.json) to Keychain.
/// Idempotent — safe to re-run. Rolls back on verification failure.
public enum VaultMigrator {

    /// Migrate vault tiers from file store to Keychain store.
    /// - Returns: Number of tiers migrated (0-3).
    public static func migrateIfNeeded(
        from fileStore: any VaultStoring,
        to keychainStore: any VaultStoring
    ) throws -> Int {
        // No vault.json → nothing to migrate
        guard fileStore.vaultExists() else { return 0 }

        // Already migrated or independently initialized
        if keychainStore.vaultExists() { return 0 }

        // Load from file store. Catch errors → don't block Keychain store.
        let vaultFile: VaultFile
        do {
            vaultFile = try fileStore.loadVaultFile()
        } catch {
            return 0
        }

        guard !vaultFile.vaults.isEmpty else { return 0 }

        // Write to Keychain
        try keychainStore.saveVaultFile(vaultFile)

        // Verify tier count AND per-tier secret counts. Roll back on failure.
        do {
            let loaded = try keychainStore.loadVaultFile()
            guard loaded.vaults.count == vaultFile.vaults.count else {
                throw VaultError.integrityCheckFailed("tier count mismatch")
            }
            for (policy, entry) in vaultFile.vaults {
                guard loaded.vaults[policy]?.secrets.count == entry.secrets.count else {
                    throw VaultError.integrityCheckFailed("migration verification failed for \(policy)")
                }
            }
        } catch {
            // Roll back partial Keychain writes before propagating
            try? keychainStore.deleteVaultFile()
            throw error
        }

        // Rename vault.json → vault.json.migrated (only after verified success)
        let vaultFileURL = fileStore.configDir.appendingPathComponent("vault.json")
        let migratedURL = vaultFileURL.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: migratedURL) // Handle existing .migrated
        try FileManager.default.moveItem(at: vaultFileURL, to: migratedURL)

        return vaultFile.vaults.count
    }
}
