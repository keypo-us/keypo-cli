import Foundation

public let keypoVersion = "0.1.5"

// MARK: - Key Policy

public enum KeyPolicy: String, Codable, CaseIterable, Sendable {
    case open = "open"
    case passcode = "passcode"
    case biometric = "biometric"
}

// MARK: - Key Metadata

public struct KeyMetadata: Codable {
    public var keyId: String
    public var applicationTag: String
    public var publicKey: String
    public var policy: KeyPolicy
    public var createdAt: Date
    public var signingCount: Int
    public var lastUsedAt: Date?
    public var previousPublicKeys: [String]
    public var dataRepresentation: String // Base64-encoded opaque CryptoKit SE key reference

    public init(
        keyId: String,
        applicationTag: String,
        publicKey: String,
        policy: KeyPolicy,
        createdAt: Date,
        signingCount: Int = 0,
        lastUsedAt: Date? = nil,
        previousPublicKeys: [String] = [],
        dataRepresentation: String
    ) {
        self.keyId = keyId
        self.applicationTag = applicationTag
        self.publicKey = publicKey
        self.policy = policy
        self.createdAt = createdAt
        self.signingCount = signingCount
        self.lastUsedAt = lastUsedAt
        self.previousPublicKeys = previousPublicKeys
        self.dataRepresentation = dataRepresentation
    }
}

// MARK: - Output Structs

public struct CreateOutput: Codable {
    public let keyId: String
    public let publicKey: String
    public let curve: String
    public let policy: String
    public let createdAt: Date
    public let storage: String

    public init(keyId: String, publicKey: String, policy: String, createdAt: Date) {
        self.keyId = keyId
        self.publicKey = publicKey
        self.curve = "P-256"
        self.policy = policy
        self.createdAt = createdAt
        self.storage = "secure-enclave"
    }
}

public struct ListKeyEntry: Codable {
    public let keyId: String
    public let publicKey: String
    public let policy: String
    public let status: String
    public let createdAt: Date
    public let signingCount: Int
    public let lastUsedAt: Date?

    public init(keyId: String, publicKey: String, policy: String, status: String,
                createdAt: Date, signingCount: Int, lastUsedAt: Date?) {
        self.keyId = keyId
        self.publicKey = publicKey
        self.policy = policy
        self.status = status
        self.createdAt = createdAt
        self.signingCount = signingCount
        self.lastUsedAt = lastUsedAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(policy, forKey: .policy)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(signingCount, forKey: .signingCount)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
    }
}

public struct ListOutput: Codable {
    public let keys: [ListKeyEntry]

    public init(keys: [ListKeyEntry]) {
        self.keys = keys
    }
}

public struct InfoOutput: Codable {
    public let keyId: String
    public let publicKey: String
    public let curve: String
    public let policy: String
    public let status: String
    public let createdAt: Date
    public let signingCount: Int
    public let lastUsedAt: Date?
    public let previousPublicKeys: [String]

    public init(keyId: String, publicKey: String, policy: String, status: String,
                createdAt: Date, signingCount: Int, lastUsedAt: Date?,
                previousPublicKeys: [String]) {
        self.keyId = keyId
        self.publicKey = publicKey
        self.curve = "P-256"
        self.policy = policy
        self.status = status
        self.createdAt = createdAt
        self.signingCount = signingCount
        self.lastUsedAt = lastUsedAt
        self.previousPublicKeys = previousPublicKeys
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyId, forKey: .keyId)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(curve, forKey: .curve)
        try container.encode(policy, forKey: .policy)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(signingCount, forKey: .signingCount)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encode(previousPublicKeys, forKey: .previousPublicKeys)
    }
}

public struct SignOutput: Codable {
    public let signature: String
    public let r: String
    public let s: String
    public let publicKey: String
    public let keyId: String
    public let algorithm: String

    public init(signature: String, r: String, s: String, publicKey: String, keyId: String) {
        self.signature = signature
        self.r = r
        self.s = s
        self.publicKey = publicKey
        self.keyId = keyId
        self.algorithm = "ES256"
    }
}

public struct DeleteOutput: Codable {
    public let keyId: String
    public let deleted: Bool
    public let deletedAt: Date

    public init(keyId: String, deletedAt: Date) {
        self.keyId = keyId
        self.deleted = true
        self.deletedAt = deletedAt
    }
}

public struct RotateOutput: Codable {
    public let keyId: String
    public let publicKey: String
    public let previousPublicKey: String
    public let policy: String
    public let rotatedAt: Date

    public init(keyId: String, publicKey: String, previousPublicKey: String, policy: String, rotatedAt: Date) {
        self.keyId = keyId
        self.publicKey = publicKey
        self.previousPublicKey = previousPublicKey
        self.policy = policy
        self.rotatedAt = rotatedAt
    }
}

public struct VerifyOutput: Codable {
    public let valid: Bool
    public let publicKey: String
    public let algorithm: String

    public init(valid: Bool, publicKey: String) {
        self.valid = valid
        self.publicKey = publicKey
        self.algorithm = "ES256"
    }
}

public struct SystemInfoOutput: Codable {
    public let secureEnclaveAvailable: Bool
    public let chip: String
    public let macosVersion: String
    public let keypoVersion: String
    public let configDir: String
    public let keyCount: Int

    public init(secureEnclaveAvailable: Bool, chip: String, macosVersion: String,
                configDir: String, keyCount: Int) {
        self.secureEnclaveAvailable = secureEnclaveAvailable
        self.chip = chip
        self.macosVersion = macosVersion
        self.keypoVersion = KeypoCore.keypoVersion
        self.configDir = configDir
        self.keyCount = keyCount
    }
}

// MARK: - Vault Models

public struct VaultFile: Codable {
    public var version: Int
    public var vaults: [String: VaultEntry]

    public init(version: Int = 2, vaults: [String: VaultEntry] = [:]) {
        self.version = version
        self.vaults = vaults
    }
}

public struct VaultEntry: Codable {
    public var vaultKeyId: String
    public var dataRepresentation: String  // Base64 SE key reference
    public var publicKey: String           // 0x04... uncompressed hex
    public var integrityEphemeralPublicKey: String  // 0x04... hex
    public var integrityHmac: String       // Base64
    public var createdAt: Date
    public var secrets: [String: EncryptedSecret]

    public init(vaultKeyId: String, dataRepresentation: String, publicKey: String,
                integrityEphemeralPublicKey: String, integrityHmac: String,
                createdAt: Date, secrets: [String: EncryptedSecret] = [:]) {
        self.vaultKeyId = vaultKeyId
        self.dataRepresentation = dataRepresentation
        self.publicKey = publicKey
        self.integrityEphemeralPublicKey = integrityEphemeralPublicKey
        self.integrityHmac = integrityHmac
        self.createdAt = createdAt
        self.secrets = secrets
    }
}

public struct EncryptedSecret: Codable, Equatable {
    public var ephemeralPublicKey: String  // 0x04... hex
    public var nonce: String              // Base64, 12 bytes
    public var ciphertext: String         // Base64
    public var tag: String                // Base64, 16 bytes
    public var createdAt: Date
    public var updatedAt: Date

    public init(ephemeralPublicKey: String, nonce: String, ciphertext: String,
                tag: String, createdAt: Date, updatedAt: Date) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Vault Output Structs

public struct VaultInitOutput: Codable {
    public let vaults: [VaultInitEntry]
    public let createdAt: Date

    public struct VaultInitEntry: Codable {
        public let vaultKeyId: String
        public let policy: String

        public init(vaultKeyId: String, policy: String) {
            self.vaultKeyId = vaultKeyId
            self.policy = policy
        }
    }

    public init(vaults: [VaultInitEntry], createdAt: Date) {
        self.vaults = vaults
        self.createdAt = createdAt
    }
}

public struct VaultSetOutput: Codable {
    public let name: String
    public let vault: String
    public let action: String
    public let createdAt: Date

    public init(name: String, vault: String, createdAt: Date) {
        self.name = name
        self.vault = vault
        self.action = "created"
        self.createdAt = createdAt
    }
}

public struct VaultGetOutput: Codable {
    public let name: String
    public let vault: String
    public let value: String

    public init(name: String, vault: String, value: String) {
        self.name = name
        self.vault = vault
        self.value = value
    }
}

public struct VaultUpdateOutput: Codable {
    public let name: String
    public let vault: String
    public let action: String
    public let updatedAt: Date

    public init(name: String, vault: String, updatedAt: Date) {
        self.name = name
        self.vault = vault
        self.action = "updated"
        self.updatedAt = updatedAt
    }
}

public struct VaultDeleteOutput: Codable {
    public let name: String
    public let vault: String
    public let deleted: Bool
    public let deletedAt: Date

    public init(name: String, vault: String, deletedAt: Date) {
        self.name = name
        self.vault = vault
        self.deleted = true
        self.deletedAt = deletedAt
    }
}

public struct VaultListOutput: Codable {
    public let vaults: [VaultListEntry]

    public struct VaultListEntry: Codable {
        public let policy: String
        public let vaultKeyId: String
        public let createdAt: Date
        public let secrets: [VaultListSecret]
        public let secretCount: Int

        public init(policy: String, vaultKeyId: String, createdAt: Date,
                    secrets: [VaultListSecret], secretCount: Int) {
            self.policy = policy
            self.vaultKeyId = vaultKeyId
            self.createdAt = createdAt
            self.secrets = secrets
            self.secretCount = secretCount
        }
    }

    public struct VaultListSecret: Codable {
        public let name: String
        public let createdAt: Date
        public let updatedAt: Date

        public init(name: String, createdAt: Date, updatedAt: Date) {
            self.name = name
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public init(vaults: [VaultListEntry]) {
        self.vaults = vaults
    }
}

public struct VaultImportOutput: Codable {
    public let vault: String
    public let imported: [VaultImportEntry]
    public let skipped: [VaultImportSkip]
    public let importedCount: Int
    public let skippedCount: Int

    public struct VaultImportEntry: Codable {
        public let name: String
        public let action: String

        public init(name: String, action: String) {
            self.name = name
            self.action = action
        }
    }

    public struct VaultImportSkip: Codable {
        public let name: String
        public let reason: String

        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    public init(vault: String, imported: [VaultImportEntry], skipped: [VaultImportSkip]) {
        self.vault = vault
        self.imported = imported
        self.skipped = skipped
        self.importedCount = imported.count
        self.skippedCount = skipped.count
    }
}

public struct VaultDestroyOutput: Codable {
    public let destroyed: Bool
    public let vaultsDestroyed: [String]
    public let totalSecretsDeleted: Int
    public let destroyedAt: Date

    public init(vaultsDestroyed: [String], totalSecretsDeleted: Int, destroyedAt: Date) {
        self.destroyed = true
        self.vaultsDestroyed = vaultsDestroyed
        self.totalSecretsDeleted = totalSecretsDeleted
        self.destroyedAt = destroyedAt
    }
}

// MARK: - Vault Helpers

public extension EncryptedSecret {
    /// Convert from internal crypto representation to serializable model
    init(from data: EncryptedSecretData) {
        self.init(
            ephemeralPublicKey: SignatureFormatter.formatHex(data.ephemeralPublicKey),
            nonce: data.nonce.base64EncodedString(),
            ciphertext: data.ciphertext.base64EncodedString(),
            tag: data.tag.base64EncodedString(),
            createdAt: data.createdAt,
            updatedAt: data.updatedAt
        )
    }

    /// Convert to internal crypto representation
    func toEncryptedSecretData() throws -> EncryptedSecretData {
        guard let nonceData = Data(base64Encoded: nonce) else {
            throw VaultError.decryptionFailed("invalid base64 nonce")
        }
        guard let ciphertextData = Data(base64Encoded: ciphertext) else {
            throw VaultError.decryptionFailed("invalid base64 ciphertext")
        }
        guard let tagData = Data(base64Encoded: tag) else {
            throw VaultError.decryptionFailed("invalid base64 tag")
        }
        let ephKeyData = try SignatureFormatter.parseHex(ephemeralPublicKey)
        return EncryptedSecretData(
            ephemeralPublicKey: ephKeyData,
            nonce: nonceData,
            ciphertext: ciphertextData,
            tag: tagData,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Secret Name Validation

public func validateSecretName(_ name: String) -> Bool {
    let pattern = "^[A-Za-z_][A-Za-z0-9_]{0,127}$"
    return name.range(of: pattern, options: .regularExpression) != nil
}

// MARK: - Errors

public enum KeypoError: Error, CustomStringConvertible {
    case invalidLabel(String)
    case duplicateLabel(String)
    case seUnavailable
    case keyNotFound(String)
    case invalidHex(String)
    case corruptMetadata(String)
    case signingFailed(String)
    case deletionFailed(String)
    case ambiguousKey([String])
    case keyMissing(String)
    case creationFailed(String)

    public var description: String {
        switch self {
        case .invalidLabel(let msg): return "invalid label: \(msg)"
        case .duplicateLabel(let label): return "label '\(label)' already exists"
        case .seUnavailable: return "Secure Enclave is not available on this device"
        case .keyNotFound(let keyId): return "key '\(keyId)' not found"
        case .invalidHex(let msg): return "invalid hex: \(msg)"
        case .corruptMetadata(let msg): return msg
        case .signingFailed(let msg): return "signing failed: \(msg)"
        case .deletionFailed(let msg): return "deletion failed: \(msg)"
        case .ambiguousKey(let keys): return "multiple keys exist, specify --key: \(keys.joined(separator: ", "))"
        case .keyMissing(let keyId): return "SE key for '\(keyId)' is missing from Secure Enclave"
        case .creationFailed(let msg): return "key creation failed: \(msg)"
        }
    }
}

// MARK: - Label Validation

public func validateLabel(_ label: String) -> Bool {
    let pattern = "^[a-z][a-z0-9-]{0,63}$"
    return label.range(of: pattern, options: .regularExpression) != nil
}
