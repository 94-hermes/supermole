import Foundation

/// The last lines a `mo` run printed, without terminal codes, for the details
/// card under a run.
public struct RunLog: Sendable, Equatable {
    public static let defaultLength = 200

    public let length: Int
    public private(set) var lines: [String] = []

    public init(length: Int = defaultLength) {
        self.length = length
    }

    /// Keeps the line once cleaned; blank lines and spinner frames leave
    /// nothing.
    public mutating func append(_ line: String) {
        let text = TerminalText.clean(line)
        guard !text.isEmpty else { return }
        lines.append(text)
        if lines.count > length {
            lines.removeFirst(lines.count - length)
        }
    }

    public var isEmpty: Bool { lines.isEmpty }
}
