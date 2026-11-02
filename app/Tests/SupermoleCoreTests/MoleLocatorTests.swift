import XCTest
@testable import SupermoleCore

final class MoleLocatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, executable: Bool) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    /// Versions keyed by path, standing in for `mo --version`.
    private func versions(_ table: [URL: String]) -> @Sendable (URL) async throws -> EngineVersion {
        { url in
            guard let text = table[url], let version = EngineVersion(text) else {
                throw MoleError.unreadableOutput("no version")
            }
            return version
        }
    }

    private static func neverAsked(_ url: URL) async throws -> EngineVersion {
        XCTFail("asked \(url.path) for its version")
        throw MoleError.unreadableOutput("not asked")
    }

    func testWithoutAMinimumTheFirstExecutableCandidateWins() async throws {
        let missing = directory.appendingPathComponent("missing")
        let notExecutable = try file("plain", executable: false)
        let first = try file("first", executable: true)
        let second = try file("second", executable: true)

        let locator = MoleLocator(candidates: [missing, notExecutable, first, second])

        let choice = await locator.choose(minimum: nil, versionOf: Self.neverAsked)
        XCTAssertEqual(choice, .found(first))
    }

    func testAnOverrideComesBeforeTheUsualPlacesWhateverItsVersion() async throws {
        let checkout = try file("mole", executable: true)

        let choice = await MoleLocator(home: directory, override: checkout.path)
            .choose(minimum: EngineVersion("99.0.0"), versionOf: Self.neverAsked)
        XCTAssertEqual(choice, .found(checkout))
    }

    func testAnOlderMoIsPassedOverForANewerOne() async throws {
        let release = try file("release", executable: true)
        let user = try file("user", executable: true)

        let choice = await MoleLocator(candidates: [release, user])
            .choose(minimum: EngineVersion("1.66.0"), versionOf: versions([release: "1.65.1", user: "1.66.0"]))
        XCTAssertEqual(choice, .found(user))
    }

    func testANewerMoThanTheAppIsTaken() async throws {
        let release = try file("release", executable: true)

        let choice = await MoleLocator(candidates: [release])
            .choose(minimum: EngineVersion("1.66.0"), versionOf: versions([release: "1.67.2"]))
        XCTAssertEqual(choice, .found(release))
    }

    func testOnlyOlderMosMeanOutdatedWithTheFirstOnesVersion() async throws {
        let release = try file("release", executable: true)
        let user = try file("user", executable: true)

        let choice = await MoleLocator(candidates: [release, user])
            .choose(minimum: EngineVersion("1.66.0"), versionOf: versions([release: "1.65.1", user: "1.64.0"]))
        XCTAssertEqual(choice, .outdated(release, EngineVersion("1.65.1")))
    }

    func testAMoThatReportsNoVersionCountsAsOutdated() async throws {
        let silent = try file("silent", executable: true)

        let choice = await MoleLocator(candidates: [silent])
            .choose(minimum: EngineVersion("1.66.0"), versionOf: versions([:]))
        XCTAssertEqual(choice, .outdated(silent, nil))
    }

    func testNoCandidateMeansMoIsMissing() async {
        let choice = await MoleLocator(candidates: [directory.appendingPathComponent("mo")])
            .choose(minimum: EngineVersion("1.66.0"), versionOf: Self.neverAsked)
        XCTAssertEqual(choice, .missing)
    }

    func testTheAppInstallsIntoTheUsersLocalBin() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(MoleLocator.userInstallDirectory(home: home).path, "/Users/test/.local/bin")
    }

    func testTheInstallerRunsTheForksInstallScriptIntoThatFolder() {
        let installer = MoleInstaller(home: URL(fileURLWithPath: "/Users/test"), environment: [:])

        XCTAssertEqual(installer.arguments.last, "/Users/test/.local/bin")
        XCTAssertEqual(installer.arguments.dropLast().last, "https://raw.githubusercontent.com/94-hermes/supermole/main/install.sh")
        XCTAssertTrue(installer.arguments[1].hasPrefix("set -o pipefail;"))
    }
}
