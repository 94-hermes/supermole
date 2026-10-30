import Foundation

/// `mo history --json --limit N`: past runs and the files they removed.
public struct HistoryReport: Decodable, Sendable, Equatable {
    public let sessions: [Session]?
    public let deletions: [Deletion]?

    public static let defaultLimit = 50

    public static func arguments(limit: Int = defaultLimit) -> [String] {
        ["history", "--json", "--limit", String(limit)]
    }

    public struct Session: Decodable, Sendable, Equatable, Identifiable {
        public let command: String
        public let runId: String?
        public let startedAt: String?
        public let endedAt: String?
        public let items: Int?
        public let size: String?
        public let failedTasks: Int?
        public let actions: Actions?

        public var id: String { "\(command)-\(startedAt ?? "")-\(runId ?? "")" }
    }

    public struct Actions: Decodable, Sendable, Equatable {
        public let removed: Int?
        public let trashed: Int?
        public let skipped: Int?
        public let failed: Int?
    }

    public struct Deletion: Decodable, Sendable, Equatable, Identifiable {
        public let timestamp: String?
        public let mode: String?
        public let status: String?
        public let sizeKb: Int64?
        public let path: String

        public var id: String { "\(timestamp ?? "")-\(path)" }
    }
}
