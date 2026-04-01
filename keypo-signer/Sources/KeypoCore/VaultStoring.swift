import Foundation

/// Protocol for vault persistence. Both file-based and Keychain-based stores conform.
public protocol VaultStoring {
    /// The config directory (e.g. ~/.keypo). Used by BackupStateManager.
    var configDir: URL { get }

    /// Returns true if at least one vault tier exists.
    /// Non-throwing — returns false on errors (matching file store's behavior).
    func vaultExists() -> Bool

    func loadVaultFile() throws -> VaultFile
    func saveVaultFile(_ file: VaultFile) throws
    func deleteVaultFile() throws
}

// MARK: - Shared Lookup Methods

public extension VaultStoring {
    /// Search for a secret by name across all vault tiers (biometric > passcode > open).
    func findSecret(name: String) throws -> (policy: KeyPolicy, secret: EncryptedSecret)? {
        let vaultFile = try loadVaultFile()
        for policyName in ["biometric", "passcode", "open"] {
            guard let entry = vaultFile.vaults[policyName] else { continue }
            if let secret = entry.secrets[name] {
                guard let policy = KeyPolicy(rawValue: policyName) else { continue }
                return (policy: policy, secret: secret)
            }
        }
        return nil
    }

    /// List all secret names across all vault tiers, sorted by name within each policy.
    func allSecretNames() throws -> [(name: String, policy: KeyPolicy)] {
        let vaultFile = try loadVaultFile()
        var result: [(name: String, policy: KeyPolicy)] = []
        for policyName in ["biometric", "passcode", "open"] {
            guard let entry = vaultFile.vaults[policyName],
                  let policy = KeyPolicy(rawValue: policyName) else { continue }
            for name in entry.secrets.keys.sorted() {
                result.append((name: name, policy: policy))
            }
        }
        return result
    }

    /// Check if a secret name is globally unique across all vault tiers.
    func isNameGloballyUnique(_ name: String) throws -> Bool {
        let vaultFile = try loadVaultFile()
        for (_, entry) in vaultFile.vaults {
            if entry.secrets[name] != nil {
                return false
            }
        }
        return true
    }
}
