import Foundation

/// One row of `mo uninstall --list`, which prints JSON when its output is not
/// a terminal: an app `mo uninstall` can remove.
public struct InstalledApp: Decodable, Sendable, Equatable, Identifiable {
    public static let arguments = ["uninstall", "--list"]

    public let name: String
    public let bundleId: String
    /// App, or Homebrew for an app a cask installed.
    public let source: String
    public let path: String
    /// Null until `mo` has measured an app it sees for the first time; the
    /// next listing has it.
    public let sizeKb: Int64?
    /// When the app was last opened (Spotlight), or its last change.
    public let lastUsedEpoch: Int64?

    public var id: String { path }
    public var bytes: Int64? { sizeKb.map { $0 * 1024 } }
    public var lastUsed: Date? { lastUsedEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var isHomebrew: Bool { source == "Homebrew" }
}

/// Searching and ordering the installed apps as the Apps space lists them.
public enum InstalledApps {
    public enum Order: String, CaseIterable, Sendable {
        /// Largest first.
        case size
        case name
        /// Longest unused first: the likeliest to go.
        case lastUsed
    }

    /// Whether some app still has no size, so listing again soon is worth it.
    public static func lacksSizes(_ apps: [InstalledApp]) -> Bool {
        apps.contains { $0.sizeKb == nil }
    }

    /// The apps whose name contains the query, in the given order; an app
    /// without the value an order needs comes last.
    public static func arranged(_ apps: [InstalledApp], matching query: String, by order: Order) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matching = trimmed.isEmpty ? apps : apps.filter { $0.name.localizedStandardContains(trimmed) }
        return matching.sorted { first, second in
            switch order {
            case .size:
                return knownFirst(first.sizeKb, second.sizeKb, by: >) ?? byName(first, second)
            case .name:
                return byName(first, second)
            case .lastUsed:
                return knownFirst(first.lastUsedEpoch, second.lastUsedEpoch, by: <) ?? byName(first, second)
            }
        }
    }

    /// Known values in the given order, unknown ones last; nil when both are
    /// equal or unknown.
    private static func knownFirst(_ first: Int64?, _ second: Int64?, by isOrdered: (Int64, Int64) -> Bool) -> Bool? {
        switch (first, second) {
        case let (first?, second?) where first != second: return isOrdered(first, second)
        case (.some, nil): return true
        case (nil, .some): return false
        default: return nil
        }
    }

    private static func byName(_ first: InstalledApp, _ second: InstalledApp) -> Bool {
        first.name.localizedStandardCompare(second.name) == .orderedAscending
    }
}
