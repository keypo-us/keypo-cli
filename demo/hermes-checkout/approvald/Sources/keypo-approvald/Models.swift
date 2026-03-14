import Foundation

// MARK: - Request Messages

struct IncomingMessage: Codable {
    let action: String
    let request_id: String?
    let vault_label: String?
    let bio_reason: String?
    let manifest: JSONValue?
}

struct ResponseMessage: Codable {
    let status: String
    let request_id: String?
    var exit_code: Int?
    var stdout: String?
    var stderr: String?
    var error: String?
}

// MARK: - Staged Request

struct StagedRequest {
    let requestId: String
    let vaultLabel: String
    let bioReason: String
    let manifest: JSONValue
    let stagedAt: Date
}

// MARK: - Generic JSON Value (opaque manifest handling)

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    func toJSONData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
