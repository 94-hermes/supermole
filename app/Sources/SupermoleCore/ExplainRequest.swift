import Foundation

/// `mo analyze --explain '<items>' [--deep]`: what the E key of `mo analyze`
/// asks the AI, for rows of the app's list. The answers also land in the
/// store the terminal reads.
public struct ExplainRequest: Sendable, Equatable {
    /// The terminal's batch size, which `mo` enforces.
    public static let maxItems = 10

    public struct Item: Encodable, Sendable, Equatable {
        public let path: String
        public let label: String
        public let size: Int64

        public init(path: String, label: String, size: Int64) {
            self.path = path
            self.label = label
            self.size = size
        }
    }

    public let items: [Item]
    /// Let the AI read inside the one item, read-only.
    public let deep: Bool

    public init(items: [Item], deep: Bool = false) {
        self.items = items
        self.deep = deep
    }

    public func arguments() throws -> [String] {
        let data = try JSONEncoder().encode(items)
        let json = String(decoding: data, as: UTF8.self)
        return ["analyze", "--explain", json] + (deep ? ["--deep"] : [])
    }

    /// Splits rows into requests `mo` accepts.
    public static func batches(of items: [Item]) -> [ExplainRequest] {
        stride(from: 0, to: items.count, by: maxItems).map {
            ExplainRequest(items: Array(items[$0..<min($0 + maxItems, items.count)]))
        }
    }
}

/// What `mo analyze --explain` prints.
public struct ExplainReport: Decodable, Sendable, Equatable {
    public let answers: [String: ExplainAnswers.Answer]
    public let errors: [String: String]
}
