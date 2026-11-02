import Foundation

/// A release number of `mo` or of the app, compared number by number, so
/// 1.10.0 comes after 1.9.2.
public struct EngineVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Reads "1.66.0", "V1.66.0" or "1.66.0-dev"; nil for anything else.
    public init?(_ text: String) {
        var number = Substring(text.trimmingCharacters(in: .whitespaces))
        if number.first == "v" || number.first == "V" { number = number.dropFirst() }
        if let suffix = number.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            number = number[..<suffix]
        }
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        let components = parts.compactMap { Int($0) }
        guard !parts.isEmpty, components.count == parts.count else { return nil }
        self.components = components
    }

    /// The version in what `mo --version` prints: "Mole version 1.65.1" on its
    /// first line, then details about the Mac.
    public init?(versionOutput: String) {
        let words = versionOutput.split(whereSeparator: \.isWhitespace)
        guard let marker = words.firstIndex(where: { $0.lowercased() == "version" }),
              marker + 1 < words.count else { return nil }
        self.init(String(words[marker + 1]))
    }

    /// Asks the `mo` behind `runner` for its version.
    public static func read(from runner: MoleRunner) async throws -> EngineVersion {
        let output = try await runner.run(["--version"])
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard output.succeeded, let version = EngineVersion(versionOutput: text) else {
            throw MoleError.unreadableOutput("mo --version printed no version: \(text.prefix(200))")
        }
        return version
    }

    public static func < (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        let length = max(lhs.components.count, rhs.components.count)
        for index in 0..<length {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// 1.66 and 1.66.0 are the same release.
    public static func == (lhs: EngineVersion, rhs: EngineVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
