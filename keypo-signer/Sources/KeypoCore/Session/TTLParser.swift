import Foundation

/// Parses duration strings like "30m", "2h", "1d", "90s" into TimeInterval.
/// No hard maximum — caller is responsible for emitting warnings if desired.
public enum TTLParser {
    /// Parse a duration string into seconds. Returns nil for invalid format or zero/negative values.
    public static func parse(_ string: String) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let suffixMultipliers: [(String, Double)] = [
            ("d", 86400),
            ("h", 3600),
            ("m", 60),
            ("s", 1),
        ]

        for (suffix, multiplier) in suffixMultipliers {
            if trimmed.hasSuffix(suffix) {
                let numberPart = String(trimmed.dropLast(suffix.count))
                guard let value = Double(numberPart), value > 0 else { return nil }
                return value * multiplier
            }
        }

        // No recognized suffix — try as raw seconds
        guard let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    /// Format a TimeInterval back to a human-readable duration string.
    public static func format(_ interval: TimeInterval) -> String {
        if interval >= 86400 && interval.truncatingRemainder(dividingBy: 86400) == 0 {
            return "\(Int(interval / 86400))d"
        } else if interval >= 3600 && interval.truncatingRemainder(dividingBy: 3600) == 0 {
            return "\(Int(interval / 3600))h"
        } else if interval >= 60 && interval.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval))s"
        }
    }
}
