import Foundation

/// `mo clean --dry-run --json`: what a cleanup would do, by section.
///
/// Sizes are in KiB, as `mo` measures them. A row inside another listed row
/// names it in `coveredBy` and adds nothing to the totals, which already hold
/// its bytes through the ancestor. `lines` are the "would ..." lines the
/// terminal preview prints, owner commands (brew, npm...) included: some of
/// them have no row, so they are the full account of what a cleanup does.
public struct CleanPreview: Decodable, Sendable, Equatable {
    public static let arguments = ["clean", "--dry-run", "--json"]
    /// The real run. Without a terminal it starts at once and skips the
    /// system section unless an administrator session already exists.
    public static let cleanArguments = ["clean"]

    /// complete, timeout, interrupted or incomplete.
    public let status: String
    /// Whether the system section was previewed; the real run decides again.
    public let systemIncluded: Bool?
    public let totalSizeKb: Int64
    public let sizePartial: Bool
    public let items: Int
    public let categories: Int
    public let entries: [Entry]
    public let sections: [Section]
    public let lines: [Line]?

    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public let section: String
        public let path: String
        public let sizeKb: Int64
        public let sizeKnown: Bool
        public let count: Int
        public let coveredBy: String

        public var id: String { "\(section)\u{0}\(path)" }
        public var bytes: Int64 { sizeKb * 1024 }
    }

    public struct Section: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let sizeKb: Int64
        public let items: Int

        public var id: String { name }
        public var bytes: Int64 { sizeKb * 1024 }
    }

    public struct Line: Decodable, Sendable, Equatable {
        public let section: String
        public let text: String
    }

    /// One category as the app lists it: its size and rows, and what the
    /// cleanup prints for it.
    public struct Summary: Sendable, Equatable, Identifiable {
        public let name: String
        public let bytes: Int64
        public let items: Int
        public let lines: [String]

        public var id: String { name }
    }

    public var totalBytes: Int64 { totalSizeKb * 1024 }

    /// Every section with something to free or something to do, largest
    /// first; a section of owner commands alone has no size but still shows.
    public var summaries: [Summary] {
        var order: [String] = []
        var linesBySection: [String: [String]] = [:]
        for line in lines ?? [] {
            if linesBySection[line.section] == nil { order.append(line.section) }
            linesBySection[line.section, default: []].append(line.text)
        }
        let sized = Dictionary(sections.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for section in sections where section.items > 0 && linesBySection[section.name] == nil {
            order.append(section.name)
        }
        return order.map { name in
            Summary(
                name: name,
                bytes: sized[name]?.bytes ?? 0,
                items: sized[name]?.items ?? 0,
                lines: linesBySection[name] ?? []
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    public var isComplete: Bool { status == "complete" }

    /// Sections with something to free, largest first.
    public var sortedSections: [Section] {
        sections.filter { $0.items > 0 }.sorted { $0.sizeKb > $1.sizeKb }
    }

    /// A section's own rows, largest first; rows counted under another stay
    /// out, since the ancestor already lists them.
    public func entries(in section: String) -> [Entry] {
        entries.filter { $0.section == section && $0.coveredBy.isEmpty }.sorted { $0.sizeKb > $1.sizeKb }
    }

    /// Whether the cleanup empties the Trash, which `mo clean` does unless the
    /// Trash row is whitelisted.
    public func emptiesTrash(home: String) -> Bool {
        let trash = home + "/.Trash"
        return entries.contains { $0.path == trash || $0.path.hasPrefix(trash + "/") }
    }
}

/// Reads a cleanup's progress from `mo clean`'s output, whose sections start
/// with a "➤ Name" line. It only drives the progress display; nothing relies
/// on it for what gets removed.
public enum CleanProgress {
    private static let sectionMarker = "➤ "

    /// The section a line opens, if it opens one.
    public static func section(in line: String) -> String? {
        let text = TerminalText.clean(line)
        guard text.hasPrefix(sectionMarker) else { return nil }
        let name = text.dropFirst(sectionMarker.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
