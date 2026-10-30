import Foundation

/// `mo analyze --json [path]`: the disk overview, or one folder's contents.
public struct AnalyzeResult: Decodable, Sendable, Equatable {
    public let scanStatus: String?
    public let path: String
    public let overview: Bool?
    public let entries: [Entry]?
    public let largeFiles: [LargeFile]?
    public let totalSize: Int64?

    public struct Entry: Decodable, Sendable, Equatable, Identifiable {
        public let scanStatus: String?
        public let name: String
        public let path: String
        public let size: Int64
        public let isDir: Bool
        /// A location `mo analyze` points out as worth a look (simulators, caches...).
        public let insight: Bool?
        public let cleanable: Bool?
        public let lastAccess: String?

        public var id: String { path }
    }

    public struct LargeFile: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let path: String
        public let size: Int64

        public var id: String { path }
    }

    /// `mo analyze` reports a partial scan with a zero exit status.
    public var isPartial: Bool { scanStatus == "partial" }

    /// Entries, largest first, as the app lists them.
    public var sortedEntries: [Entry] {
        (entries ?? []).sorted { $0.size > $1.size }
    }

    /// The arguments for an analysis; the flag must come before the path.
    public static func arguments(for path: String?) -> [String] {
        guard let path, !path.isEmpty else { return ["analyze", "--json"] }
        return ["analyze", "--json", path]
    }
}
