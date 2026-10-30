import Foundation

/// Installs `mo` for the current user on the app's first launch.
///
/// It runs the fork's one-line installer, install.sh from `main`, which keeps
/// its checksum and attestation checks, into `~/.local/bin` so no
/// administrator password is needed.
public struct MoleInstaller: Sendable {
    /// The repository install.sh names in MOLE_REPO_SLUG; tests/scripts.bats
    /// keeps the two equal.
    public static let repositorySlug = "94-hermes/supermole"
    public static let installerURL = "https://raw.githubusercontent.com/\(repositorySlug)/main/install.sh"

    static let shell = URL(fileURLWithPath: "/bin/bash")
    // pipefail: a failed download pipes nothing into bash, which exits 0.
    static let pipeline = #"set -o pipefail; /usr/bin/curl -fsSL "$1" | /bin/bash -s -- --prefix "$2""#

    public let installDirectory: URL
    public let environment: [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = MoleRunner.defaultEnvironment()) {
        self.installDirectory = MoleLocator.userInstallDirectory(home: home)
        self.environment = environment
    }

    /// The command the install runs, split out for tests.
    public var arguments: [String] {
        ["-c", Self.pipeline, "supermole-install", Self.installerURL, installDirectory.path]
    }

    /// Streams the installer's output; finishes with an error when it fails.
    public func install() -> AsyncThrowingStream<String, Error> {
        MoleRunner(executable: Self.shell, environment: environment).lines(arguments, includeErrors: true)
    }
}
