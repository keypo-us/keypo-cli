import Foundation

public let keypoVersion = "0.1.0"

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
