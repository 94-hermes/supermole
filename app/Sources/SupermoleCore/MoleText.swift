import Foundation

/// Reads the human-oriented values `mo` puts in its JSON, so the app can show
/// them in the Mac's own language and number format.
public enum MoleText {
    /// `mo status`'s health message: a rating, then the issues behind it,
    /// as in "Good: High CPU, Disk Almost Full" (cmd/status/metrics_health.go).
    public struct HealthMessage: Equatable, Sendable {
        public let rating: String
        public let issues: [String]
    }

    public static func healthMessage(_ message: String) -> HealthMessage {
        let parts = message.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let issues = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        return HealthMessage(rating: parts.first ?? "", issues: issues)
    }

    /// Decimal multipliers of `bytes_to_human` in lib/core/base.sh, like Finder.
    private static let unitMultipliers: [String: Double] = [
        "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
    ]

    /// Bytes from a size such as "8.40GB" or "571.9MB"; nil when unreadable.
    public static func bytes(fromHumanSize text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let unitStart = trimmed.firstIndex(where: { $0.isLetter }) else { return nil }
        let number = trimmed[..<unitStart].trimmingCharacters(in: .whitespaces)
        let unit = String(trimmed[unitStart...])
        guard let value = Double(number), let multiplier = unitMultipliers[unit] else { return nil }
        return Int64((value * multiplier).rounded())
    }

    /// `mo history` writes local times as "2026-10-29 15:59:02".
    public static func historyDate(_ text: String) -> Date? {
        historyDateFormatter.date(from: text)
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
