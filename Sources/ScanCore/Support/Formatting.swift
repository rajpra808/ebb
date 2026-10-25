import Foundation

/// Formats byte counts the way Finder does: decimal units, one decimal place
/// from megabytes up, e.g. `3.1 GB`, `412 KB`.
public enum ByteCount {
    public static func format(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        switch unit {
        case 0: return bytes == 1 ? "1 byte" : "\(bytes) bytes"
        case 1: return "\(Int(value.rounded())) KB"
        default:
            // 999.95 MB would print as "1000.0 MB"; promote it instead.
            if value >= 999.95, unit < units.count - 1 {
                return "1.0 \(units[unit + 1])"
            }
            return String(format: "%.1f %@", value, units[unit])
        }
    }

    /// Parses sizes typed on the command line: `50MB`, `1.5 GB`, `200k`,
    /// `1024` (bytes). Units are decimal, like `format`.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), value >= 0 else { return nil }
        let multipliers: [String: Double] = [
            "": 1, "b": 1,
            "k": 1e3, "kb": 1e3,
            "m": 1e6, "mb": 1e6,
            "g": 1e9, "gb": 1e9,
            "t": 1e12, "tb": 1e12,
        ]
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let multiplier = multipliers[unit] else { return nil }
        return Int64(value * multiplier)
    }
}

/// Short relative ages for reasons and tables: "3 hours", "41 days".
enum Age {
    static func describe(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days >= 2 { return "\(days) days" }
        if days == 1 { return "1 day" }
        if hours >= 2 { return "\(hours) hours" }
        if hours == 1 { return "1 hour" }
        return minutes <= 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func days(from date: Date, to now: Date) -> Int {
        Int(max(0, now.timeIntervalSince(date)) / 86_400)
    }
}
