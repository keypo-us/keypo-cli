import Foundation

public struct EnvFileParser {

    public struct Entry {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// Extract just key names from a .env file (for vault exec --env)
    public static func parseKeyNames(from path: String) throws -> [String] {
        let entries = try parseEntries(from: path)
        // Deduplicate preserving order
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            if seen.insert(entry.key).inserted {
                result.append(entry.key)
            }
        }
        return result
    }

    /// Extract key-value pairs from a .env file (for vault import)
    public static func parseEntries(from path: String) throws -> [Entry] {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let rawData: Data
        do {
            rawData = try Data(contentsOf: url)
        } catch {
            throw VaultError.serializationFailed("cannot read file: \(path)")
        }

        var content: String
        // Strip UTF-8 BOM if present
        if rawData.count >= 3 && rawData[0] == 0xEF && rawData[1] == 0xBB && rawData[2] == 0xBF {
            content = String(data: rawData.dropFirst(3), encoding: .utf8) ?? ""
        } else {
            content = String(data: rawData, encoding: .utf8) ?? ""
        }

        var entries: [Entry] = []

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            // Handle \r from \r\n
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: "\r"))
            let stripped = trimmed.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if stripped.isEmpty || stripped.hasPrefix("#") {
                continue
            }

            // Must contain =
            guard let equalsIdx = stripped.firstIndex(of: "=") else {
                writeWarningToStderr("skipping line without '=': \(stripped)")
                continue
            }

            var key = String(stripped[stripped.startIndex..<equalsIdx])
                .trimmingCharacters(in: .whitespaces)

            // Strip export prefix
            if key.hasPrefix("export ") {
                key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if key == "export" {
                // export= is not valid
                writeWarningToStderr("skipping invalid line: \(stripped)")
                continue
            }

            let rawValue = String(stripped[stripped.index(after: equalsIdx)...])
                .trimmingCharacters(in: .whitespaces)

            // Strip surrounding quotes from value
            let value = stripQuotes(rawValue)

            entries.append(Entry(key: key, value: value))
        }

        return entries
    }

    /// Parse key names from string content (for testing)
    public static func parseKeyNamesFromString(_ content: String) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .init(charactersIn: "\r"))
            let stripped = trimmed.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || stripped.hasPrefix("#") { continue }
            guard let equalsIdx = stripped.firstIndex(of: "=") else { continue }
            var key = String(stripped[stripped.startIndex..<equalsIdx])
                .trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") {
                key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty && seen.insert(key).inserted {
                keys.append(key)
            }
        }
        return keys
    }

    private static func stripQuotes(_ value: String) -> String {
        if value.count >= 2 {
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                return String(value.dropFirst().dropLast())
            }
        }
        return value
    }

    private static func writeWarningToStderr(_ msg: String) {
        if let data = "warning: \(msg)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
