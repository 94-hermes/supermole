import Foundation

/// Finds the `mo` launcher this app drives.
///
/// The app installs `mo` into `~/.local/bin` when none is found, which needs no
/// administrator password. A release install in `/usr/local/bin` comes first,
/// and a Homebrew install (upstream Mole) last. A `mo` older than the app lacks
/// commands the app runs, so `choose` passes over it.
public struct MoleLocator: Sendable {
    public static let userPrefix = ".local/bin"
    public static let launcherName = "mo"

    /// A user-defaults key naming one `mo` to drive before any other, for
    /// trying the app against a checkout: `open Supermole.app --args
    /// -MolePath /path/to/mole`.
    public static let overrideKey = "MolePath"

    /// What `choose` settled on.
    public enum Choice: Equatable, Sendable {
        case found(URL)
        /// Every `mo` found is older than the app: the first of them, with the
        /// version it reported (nil when it reported none).
        case outdated(URL, EngineVersion?)
        case missing
    }

    private let override: URL?
    private let candidates: [URL]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        override: String? = UserDefaults.standard.string(forKey: MoleLocator.overrideKey)
    ) {
        self.init(override: override.map { URL(fileURLWithPath: $0) }, candidates: [
            URL(fileURLWithPath: "/usr/local/bin/\(Self.launcherName)"),
            Self.userInstallDirectory(home: home).appendingPathComponent(Self.launcherName),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(Self.launcherName)"),
        ])
    }

    public init(override: URL? = nil, candidates: [URL]) {
        self.override = override
        self.candidates = candidates
    }

    /// Where the app installs `mo` when none is found.
    public static func userInstallDirectory(home: URL) -> URL {
        home.appendingPathComponent(userPrefix, isDirectory: true)
    }

    /// The first `mo` at least as new as `minimum`. An override is taken as
    /// it is, being a checkout under test, and without a `minimum` the first
    /// `mo` found wins.
    public func choose(
        minimum: EngineVersion?,
        versionOf: @Sendable (URL) async throws -> EngineVersion
    ) async -> Choice {
        let found = executables
        guard let first = found.first else { return .missing }
        if let override, first == override { return .found(override) }
        guard let minimum else { return .found(first) }

        var firstVersion: EngineVersion?
        for (index, executable) in found.enumerated() {
            // A `mo` that cannot tell its version is not trusted with the
            // app's commands; it counts as outdated.
            let version = try? await versionOf(executable)
            if let version, version >= minimum { return .found(executable) }
            if index == 0 { firstVersion = version }
        }
        return .outdated(first, firstVersion)
    }

    private var executables: [URL] {
        ([override].compactMap { $0 } + candidates).filter {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
