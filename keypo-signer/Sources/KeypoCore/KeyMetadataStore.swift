import Foundation

public class KeyMetadataStore: KeyMetadataStoring {
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

    private var keysFilePath: URL {
        configDir.appendingPathComponent("keys.json")
    }

    private var lockFilePath: String {
        configDir.appendingPathComponent("keys.json.lock").path
    }

    public func ensureConfigDir() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: configDir.path, isDirectory: &isDir) {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            // Set 700 permissions
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir.path)
        }
    }

    public func loadKeys() throws -> [KeyMetadata] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: keysFilePath.path) else {
            return []
        }
        let data = try Data(contentsOf: keysFilePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([KeyMetadata].self, from: data)
        } catch {
            throw KeypoError.corruptMetadata(
                "The metadata file is corrupted. Keys may still exist in the Secure Enclave. " +
                "Delete the metadata file and use keypo-signer create to re-register keys."
            )
        }
    }

    public func saveKeys(_ keys: [KeyMetadata]) throws {
        try ensureConfigDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(keys)

        let tempPath = configDir.appendingPathComponent("keys.json.tmp")
        try data.write(to: tempPath, options: .atomic)
        let fm = FileManager.default
        // Rename temp file over keys.json
        if fm.fileExists(atPath: keysFilePath.path) {
            _ = try fm.replaceItemAt(keysFilePath, withItemAt: tempPath)
        } else {
            try fm.moveItem(at: tempPath, to: keysFilePath)
        }
        // Set 600 permissions
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysFilePath.path)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try ensureConfigDir()
        let fd = open(lockFilePath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw KeypoError.corruptMetadata("Failed to open lock file")
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)
        return try body()
    }

    public func addKey(_ key: KeyMetadata) throws {
        try withLock {
            var keys = try loadKeys()
            guard !keys.contains(where: { $0.keyId == key.keyId }) else {
                throw KeypoError.storeError("key '\(key.keyId)' already exists")
            }
            keys.append(key)
            try saveKeys(keys)
        }
    }

    public func removeKey(keyId: String) throws {
        try withLock {
            var keys = try loadKeys()
            keys.removeAll { $0.keyId == keyId }
            try saveKeys(keys)
        }
    }

    public func updateKey(_ key: KeyMetadata) throws {
        try withLock {
            var keys = try loadKeys()
            guard let idx = keys.firstIndex(where: { $0.keyId == key.keyId }) else {
                throw KeypoError.storeError("key '\(key.keyId)' not found")
            }
            guard keys[idx].dataRepresentation == key.dataRepresentation else {
                throw KeypoError.storeError(
                    "cannot update dataRepresentation for '\(key.keyId)' — use replaceKey"
                )
            }
            keys[idx] = key
            try saveKeys(keys)
        }
    }

    public func replaceKey(_ key: KeyMetadata) throws {
        try withLock {
            var keys = try loadKeys()
            guard let idx = keys.firstIndex(where: { $0.keyId == key.keyId }) else {
                throw KeypoError.storeError("key '\(key.keyId)' not found")
            }
            keys[idx] = key
            try saveKeys(keys)
        }
    }

    /// Atomically increment signing count and update lastUsedAt.
    /// Reads the current value inside the lock to avoid lost updates under concurrency.
    public func incrementSignCount(keyId: String) throws {
        try withLock {
            var keys = try loadKeys()
            guard let idx = keys.firstIndex(where: { $0.keyId == keyId }) else {
                throw KeypoError.storeError("key '\(keyId)' not found")
            }
            keys[idx].signingCount += 1
            keys[idx].lastUsedAt = Date()
            try saveKeys(keys)
        }
    }

    public func findKey(keyId: String) throws -> KeyMetadata? {
        let keys = try loadKeys()
        return keys.first { $0.keyId == keyId }
    }
}
