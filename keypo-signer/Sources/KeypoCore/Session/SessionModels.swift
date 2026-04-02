import Foundation

// MARK: - Session Metadata

public struct SessionMetadata: Codable {
    public var name: String
    public var secrets: [String]                  // sorted
    public var originalTiers: [String: String]     // secret name -> policy
    public var createdAt: Date
    public var expiresAt: Date
    public var maxUses: Int?
    public var usesRemaining: Int?
    public var tempKeyPublicKey: String            // hex 0x04...

    public init(
        name: String,
        secrets: [String],
        originalTiers: [String: String],
        createdAt: Date,
        expiresAt: Date,
        maxUses: Int?,
        usesRemaining: Int?,
        tempKeyPublicKey: String
    ) {
        self.name = name
        self.secrets = secrets.sorted()
        self.originalTiers = originalTiers
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.usesRemaining = usesRemaining
        self.tempKeyPublicKey = tempKeyPublicKey
    }
}

// MARK: - Session Output Structs

public struct SessionStartOutput: Codable {
    public let session: String
    public let secrets: [String]
    public let expiresAt: String
    public let maxUses: Int?
    public let ttl: String

    public init(session: String, secrets: [String], expiresAt: String, maxUses: Int?, ttl: String) {
        self.session = session
        self.secrets = secrets
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.ttl = ttl
    }
}

public struct SessionEndOutput: Codable {
    public let ended: [String]
    public let count: Int

    public init(ended: [String]) {
        self.ended = ended
        self.count = ended.count
    }
}

public struct SessionListEntry: Codable {
    public let name: String
    public let secrets: [String]
    public let expiresAt: String
    public let usesRemaining: Int?
    public let status: String

    public init(name: String, secrets: [String], expiresAt: String, usesRemaining: Int?, status: String) {
        self.name = name
        self.secrets = secrets
        self.expiresAt = expiresAt
        self.usesRemaining = usesRemaining
        self.status = status
    }
}

public struct SessionListOutput: Codable {
    public let sessions: [SessionListEntry]
    public let cleaned: Int

    public init(sessions: [SessionListEntry], cleaned: Int) {
        self.sessions = sessions
        self.cleaned = cleaned
    }
}

public struct SessionStatusOutput: Codable {
    public let name: String
    public let secrets: [String]
    public let originalTiers: [String: String]
    public let createdAt: String
    public let expiresAt: String
    public let maxUses: Int?
    public let usesRemaining: Int?
    public let status: String

    public init(name: String, secrets: [String], originalTiers: [String: String],
                createdAt: String, expiresAt: String, maxUses: Int?,
                usesRemaining: Int?, status: String) {
        self.name = name
        self.secrets = secrets
        self.originalTiers = originalTiers
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.usesRemaining = usesRemaining
        self.status = status
    }
}

public struct SessionRefreshOutput: Codable {
    public let session: String
    public let expiresAt: String
    public let maxUses: Int?
    public let usesRemaining: Int?

    public init(session: String, expiresAt: String, maxUses: Int?, usesRemaining: Int?) {
        self.session = session
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.usesRemaining = usesRemaining
    }
}

// MARK: - Session Errors

public enum SessionError: Error, CustomStringConvertible {
    case sessionNotFound(String)
    case sessionExpired(String)
    case sessionExhausted(String)
    case duplicateSession(String)
    case validationError(String)
    case keychainError(String)

    public var description: String {
        switch self {
        case .sessionNotFound(let name): return "session '\(name)' not found"
        case .sessionExpired(let name): return "session '\(name)' has expired"
        case .sessionExhausted(let name): return "session '\(name)' has no remaining uses"
        case .duplicateSession(let name): return "a session with identical secrets already exists: '\(name)'"
        case .validationError(let msg): return msg
        case .keychainError(let msg): return "keychain error: \(msg)"
        }
    }
}
