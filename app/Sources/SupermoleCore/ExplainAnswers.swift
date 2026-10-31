import Foundation

/// The AI explanations `mo analyze` keeps in `~/.cache/mole/explain/answers.json`
/// (cmd/analyze/explain_store.go), keyed by absolute path.
public struct ExplainAnswers: Decodable, Sendable, Equatable {
    public static let supportedSchemaVersion = 1
    public static let relativePath = ".cache/mole/explain/answers.json"

    public let schemaVersion: Int?
    public let answers: [String: Answer]?

    public struct Answer: Decodable, Sendable, Equatable {
        /// safe, caution, keep or unknown.
        public let verdict: String?
        public let what: String?
        public let ifDeleted: String?
        public let advice: String?
        /// The AI would like to read inside before being sure.
        public let needsExploration: Bool?
        /// The answer came from reading the files (a deep look).
        public let explored: Bool?
        /// Claude or Codex.
        public let provider: String?
        public let answeredAt: String?

        /// When the answer was given, from the store's RFC 3339 timestamp.
        public var answeredDate: Date? {
            answeredAt.flatMap { Self.timestamp.date(from: $0) ?? Self.wholeSeconds.date(from: $0) }
        }

        nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        nonisolated(unsafe) private static let wholeSeconds = ISO8601DateFormatter()
    }

    public static func storeURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(relativePath)
    }

    /// The saved answers, or none when the store does not exist yet. A store
    /// of another schema version reads as empty rather than as wrong answers.
    public static func load(from url: URL = storeURL()) throws -> [String: Answer] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let store = try MoleJSON.decode(ExplainAnswers.self, from: Data(contentsOf: url))
        guard store.schemaVersion == supportedSchemaVersion else { return [:] }
        return store.answers ?? [:]
    }
}
