import Foundation

/// `mo slim --dry-run --json`: the apps whose Intel code `mo slim` can remove
/// (bin/slim.sh), largest first. Slimming rebuilds each app on a verified
/// copy; the original goes to the Trash and an app update restores the code.
public struct SlimPreview: Decodable, Sendable, Equatable {
    public static let arguments = ["slim", "--dry-run", "--json"]

    public let apps: [App]
    public let totalIntelBytes: Int64

    /// Slims exactly these apps (bundle paths from the preview); nothing is
    /// ever preselected.
    public static func slimArguments(paths: [String]) -> [String] {
        ["slim", "--yes"] + paths
    }

    public struct App: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let path: String
        public let intelBytes: Int64
        /// Open now: slimming skips it until it is quit.
        public let running: Bool

        public var id: String { path }
    }
}
