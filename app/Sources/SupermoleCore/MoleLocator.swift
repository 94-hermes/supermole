import Foundation

/// Finds the `mo` launcher this app drives.
///
/// The app installs `mo` into `~/.local/bin` when none is found, which needs no
/// administrator password. A release install in `/usr/local/bin` comes first,
/// and a Homebrew install (upstream Mole) last.
public struct MoleLocator: Sendable {
    public static let userPrefix = ".local/bin"
    public static let launcherName = "mo"

    /// A user-defaults key naming one `mo` to drive before any other, for
    /// trying the app against a checkout: `open Supermole.app --args
    /// -MolePath /path/to/mole`.
    public static let overrideKey = "MolePath"

    private let candidates: [URL]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        override: String? = UserDefaults.standard.string(forKey: MoleLocator.overrideKey)
    ) {
        let overrides = override.map { [URL(fileURLWithPath: $0)] } ?? []
        self.init(candidates: overrides + [
            URL(fileURLWithPath: "/usr/local/bin/\(Self.launcherName)"),
            Self.userInstallDirectory(home: home).appendingPathComponent(Self.launcherName),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(Self.launcherName)"),
        ])
    }

    public init(candidates: [URL]) {
        self.candidates = candidates
    }

    /// Where the app installs `mo` when none is found.
    public static func userInstallDirectory(home: URL) -> URL {
        home.appendingPathComponent(userPrefix, isDirectory: true)
    }

    public func locate() -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
