import Foundation

// MARK: - Per-event Detail Structs

public struct SessionStartDetails: Codable {
    public var secrets: [String]
    public var tiers: [String: String]
    public var ttl: String
    public var maxUses: Int?
    public var expiresAt: String

    public init(secrets: [String], tiers: [String: String], ttl: String, maxUses: Int?, expiresAt: String) {
        self.secrets = secrets
        self.tiers = tiers
        self.ttl = ttl
        self.maxUses = maxUses
        self.expiresAt = expiresAt
    }
}

public struct SessionExecDetails: Codable {
    public var command: String
    public var secretsInjected: [String]
    public var usesRemaining: Int?
    public var childPid: Int

    public init(command: String, secretsInjected: [String], usesRemaining: Int?, childPid: Int) {
        self.command = command
        self.secretsInjected = secretsInjected
        self.usesRemaining = usesRemaining
        self.childPid = childPid
    }
}

public struct SessionExecDeniedDetails: Codable {
    public var reason: String
    public var command: String

    public init(reason: String, command: String) {
        self.reason = reason
        self.command = command
    }
}

public struct SessionEndDetails: Codable {
    public var trigger: String
    public var usesConsumed: Int

    public init(trigger: String, usesConsumed: Int) {
        self.trigger = trigger
        self.usesConsumed = usesConsumed
    }
}

public struct SessionRefreshDetails: Codable {
    public var oldExpiresAt: String
    public var newExpiresAt: String
    public var oldMaxUses: Int?
    public var newMaxUses: Int?

    public init(oldExpiresAt: String, newExpiresAt: String, oldMaxUses: Int?, newMaxUses: Int?) {
        self.oldExpiresAt = oldExpiresAt
        self.newExpiresAt = newExpiresAt
        self.oldMaxUses = oldMaxUses
        self.newMaxUses = newMaxUses
    }
}

// MARK: - AuditDetails Enum

public enum AuditDetails: Codable {
    case start(SessionStartDetails)
    case exec(SessionExecDetails)
    case execDenied(SessionExecDeniedDetails)
    case end(SessionEndDetails)
    case refresh(SessionRefreshDetails)

    // Custom Codable: encode as flat JSON object (no discriminator tag).
    // The `event` field on AuditEntry determines which case to decode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .start(let d): try container.encode(d)
        case .exec(let d): try container.encode(d)
        case .execDenied(let d): try container.encode(d)
        case .end(let d): try container.encode(d)
        case .refresh(let d): try container.encode(d)
        }
    }

    public init(from decoder: Decoder) throws {
        // Decoding requires knowing the event type from the parent AuditEntry.
        // This init attempts each type in order — the parent's decode(forEvent:) is preferred.
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(SessionStartDetails.self), d.secrets.count > 0 {
            self = .start(d)
        } else if let d = try? container.decode(SessionExecDetails.self), !d.command.isEmpty {
            self = .exec(d)
        } else if let d = try? container.decode(SessionExecDeniedDetails.self), !d.reason.isEmpty {
            self = .execDenied(d)
        } else if let d = try? container.decode(SessionEndDetails.self), !d.trigger.isEmpty {
            self = .end(d)
        } else {
            self = .refresh(try container.decode(SessionRefreshDetails.self))
        }
    }

    /// Decode details given the event type string.
    public static func decode(from data: Data, forEvent event: String) throws -> AuditDetails {
        let decoder = JSONDecoder()
        switch event {
        case "session.start":
            return .start(try decoder.decode(SessionStartDetails.self, from: data))
        case "session.exec":
            return .exec(try decoder.decode(SessionExecDetails.self, from: data))
        case "session.exec_denied":
            return .execDenied(try decoder.decode(SessionExecDeniedDetails.self, from: data))
        case "session.end":
            return .end(try decoder.decode(SessionEndDetails.self, from: data))
        case "session.refresh":
            return .refresh(try decoder.decode(SessionRefreshDetails.self, from: data))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown event: \(event)"))
        }
    }
}

// MARK: - AuditEntry

public struct AuditEntry: Codable {
    public var timestamp: String
    public var event: String
    public var session: String
    public var details: AuditDetails

    public init(timestamp: String, event: String, session: String, details: AuditDetails) {
        self.timestamp = timestamp
        self.event = event
        self.session = session
        self.details = details
    }

    public init(event: String, session: String, details: AuditDetails) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: Date())
        self.event = event
        self.session = session
        self.details = details
    }
}

// MARK: - SessionAuditLog

public class SessionAuditLog {
    private let logURL: URL

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    public init(configDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".keypo")) {
        self.logURL = configDir.appendingPathComponent("session-audit.log")
        // Ensure config dir exists
        try? FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// Append an audit entry to the log file. Non-throwing — warnings go to stderr.
    public func log(_ entry: AuditEntry) {
        do {
            let data = try Self.encoder.encode(entry)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            guard let lineData = line.data(using: .utf8) else { return }

            let fd = open(logURL.path, O_APPEND | O_CREAT | O_WRONLY, 0o600)
            guard fd >= 0 else {
                FileHandle.standardError.write(Data("warning: could not open audit log: \(logURL.path)\n".utf8))
                return
            }
            defer { close(fd) }

            _ = lineData.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress!, buffer.count)
            }
        } catch {
            FileHandle.standardError.write(Data("warning: audit log write failed: \(error)\n".utf8))
        }
    }
}
