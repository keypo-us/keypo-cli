import Foundation

/// Convert [String: EncryptedSecret] to [String: EncryptedSecretData] for HMAC computation.
public func buildSecretDataMap(from secrets: [String: EncryptedSecret]) throws -> [String: EncryptedSecretData] {
    var map: [String: EncryptedSecretData] = [:]
    for (name, secret) in secrets {
        map[name] = try secret.toEncryptedSecretData()
    }
    return map
}

public class VaultStore: VaultStoring {
    public let configDir: URL

    public init(configDir: URL) {
        self.configDir = configDir
    }

    public convenience init(configPath: String? = nil) {
        let dir: URL
        if let path = configPath {
            let expanded = NSString(string: path).expandingTildeInPath
            dir = URL(fileURLWithPath: expanded)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".keypo")
        }
        self.init(configDir: dir)
    }

    private var vaultFilePath: URL {
        configDir.appendingPathComponent("vault.json")
    }

    private var lockFilePath: String {
        configDir.appendingPathComponent("vault.json.lock").path
    }

    // MARK: - File Operations

    public func vaultExists() -> Bool {
        FileManager.default.fileExists(atPath: vaultFilePath.path)
    }

    public func loadVaultFile() throws -> VaultFile {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vaultFilePath.path) else {
            throw VaultError.integrityCheckFailed("vault not initialized")
        }
        let data = try Data(contentsOf: vaultFilePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let vaultFile: VaultFile
        do {
            vaultFile = try decoder.decode(VaultFile.self, from: data)
        } catch {
            throw VaultError.serializationFailed("failed to parse vault.json: \(error.localizedDescription)")
        }
        guard vaultFile.version == 2 else {
            throw VaultError.serializationFailed("unsupported vault version: \(vaultFile.version)")
        }
        return vaultFile
    }

    public func saveVaultFile(_ file: VaultFile) throws {
        try withLock {
            try ensureConfigDir()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)

            let tempPath = configDir.appendingPathComponent("vault.json.tmp")
            try data.write(to: tempPath, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: vaultFilePath.path) {
                _ = try fm.replaceItemAt(vaultFilePath, withItemAt: tempPath)
            } else {
                try fm.moveItem(at: tempPath, to: vaultFilePath)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultFilePath.path)
        }
    }

    public func deleteVaultFile() throws {
        try withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: vaultFilePath.path) else { return }
            try fm.removeItem(at: vaultFilePath)
        }
    }

    // findSecret, allSecretNames, isNameGloballyUnique are provided
    // by the VaultStoring protocol extension.

    // MARK: - Private Helpers

    private func ensureConfigDir() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: configDir.path, isDirectory: &isDir) {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try ensureConfigDir()
        let fd = open(lockFilePath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw VaultError.serializationFailed("failed to open lock file")
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)
        return try body()
    }
}
