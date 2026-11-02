import XCTest
@testable import SupermoleCore

final class ResultCacheTests: XCTestCase {
    private struct Listing: Codable, Equatable, Sendable {
        let name: String
    }

    private var directory: URL!
    private var cache: ResultCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = ResultCache(directory: directory.appendingPathComponent("results"), limit: 3)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func json(_ name: String) -> Data {
        Data(#"{"name":"\#(name)"}"#.utf8)
    }

    func testAKeptResultReadsBackWithItsDate() async throws {
        let before = Date().addingTimeInterval(-1)
        try await cache.store(json("Safari"), for: ["uninstall", "--list"])

        let kept = await cache.kept(Listing.self, for: ["uninstall", "--list"])

        XCTAssertEqual(kept?.value, Listing(name: "Safari"))
        XCTAssertGreaterThan(try XCTUnwrap(kept?.savedAt), before)
    }

    func testEachCommandHasItsOwnResult() async throws {
        try await cache.store(json("overview"), for: ["analyze", "--json"])
        try await cache.store(json("library"), for: ["analyze", "--json", "/Users/someone/Library"])

        let overview = await cache.kept(Listing.self, for: ["analyze", "--json"])
        let library = await cache.kept(Listing.self, for: ["analyze", "--json", "/Users/someone/Library"])
        let unknown = await cache.kept(Listing.self, for: ["analyze", "--json", "/Applications"])
        XCTAssertEqual(overview?.value.name, "overview")
        XCTAssertEqual(library?.value.name, "library")
        XCTAssertNil(unknown)
        // Joining with a separator keeps ["a b"] apart from ["a", "b"].
        XCTAssertNotEqual(cache.file(for: ["a b"]), cache.file(for: ["a", "b"]))
    }

    func testAResultThatNoLongerDecodesIsDropped() async throws {
        try await cache.store(Data(#"{"other":1}"#.utf8), for: ["history", "--json"])

        let kept = await cache.kept(Listing.self, for: ["history", "--json"])

        XCTAssertNil(kept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.file(for: ["history", "--json"]).path))
    }

    func testTheOldestResultsGoPastTheLimit() async throws {
        let commands = (0..<5).map { ["analyze", "--json", "/folder\($0)"] }
        for (age, command) in commands.enumerated() {
            try await cache.store(json("\(age)"), for: command)
            // Older commands first: /folder0 is the oldest.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(age - 10) * 60)],
                ofItemAtPath: cache.file(for: command).path
            )
        }
        try await cache.store(json("latest"), for: ["history", "--json"])

        let remaining = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        XCTAssertEqual(remaining.count, 3)
        let latest = await cache.kept(Listing.self, for: ["history", "--json"])
        let newest = await cache.kept(Listing.self, for: commands[4])
        let oldest = await cache.kept(Listing.self, for: commands[0])
        XCTAssertNotNil(latest)
        XCTAssertNotNil(newest)
        XCTAssertNil(oldest)
    }

    func testRecentMeansYoungerThanTheInterval() {
        let now = Date()
        let kept = ResultCache.Kept(value: 1, savedAt: now.addingTimeInterval(-120))

        XCTAssertTrue(kept.isRecent(within: 300, now: now))
        XCTAssertFalse(kept.isRecent(within: 60, now: now))
    }

    func testTheRunnerKeepsWhatItDecodes() async throws {
        let script = directory.appendingPathComponent("mo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/bash\necho '{\"name\":\"Xcode\"}'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let listing = try await MoleRunner(executable: script)
            .decode(Listing.self, ["uninstall", "--list"], keepingIn: cache)

        XCTAssertEqual(listing, Listing(name: "Xcode"))
        let kept = await cache.kept(Listing.self, for: ["uninstall", "--list"])
        XCTAssertEqual(kept?.value, listing)
    }

    func testAFailedRunKeepsNothing() async throws {
        let script = directory.appendingPathComponent("mo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/bash\necho '{\"name\":\"half\"}'; exit 2\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        do {
            _ = try await MoleRunner(executable: script).decode(Listing.self, ["uninstall", "--list"], keepingIn: cache)
            XCTFail("a failed run decoded")
        } catch MoleError.failed(let status, _) {
            XCTAssertEqual(status, 2)
        }
        let kept = await cache.kept(Listing.self, for: ["uninstall", "--list"])
        XCTAssertNil(kept)
    }
}
