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

    func testTheFirstExecutableCandidateWins() throws {
        let missing = directory.appendingPathComponent("missing")
        let notExecutable = try file("plain", executable: false)
        let first = try file("first", executable: true)
        let second = try file("second", executable: true)

        let locator = MoleLocator(candidates: [missing, notExecutable, first, second])

        XCTAssertEqual(locator.locate(), first)
    }

    func testNoCandidateMeansMoIsMissing() {
        XCTAssertNil(MoleLocator(candidates: [directory.appendingPathComponent("mo")]).locate())
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
