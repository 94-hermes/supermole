import XCTest
@testable import SupermoleCore

/// The real probes depend on the Mac's access, so these stand in for them with
/// places whose permissions refuse a read the way a missing access does.
final class FullDiskAccessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A place made unreadable must be opened again before it can be removed.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in contents {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.appendingPathComponent(name).path
            )
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func folder(_ name: String, readable: Bool) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o755 : 0o000], ofItemAtPath: url.path)
        return url
    }

    private func file(_ name: String, readable: Bool) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("probe".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: readable ? 0o644 : 0o000], ofItemAtPath: url.path)
        return url
    }

    func testAReadableProbeMeansGranted() throws {
        XCTAssertEqual(FullDiskAccess.status(probing: [try folder("Mail", readable: true)]), .granted)
        XCTAssertEqual(FullDiskAccess.status(probing: [try file("chat.db", readable: true)]), .granted)
    }

    func testProbesThatExistButRefuseMeanDenied() throws {
        let probes = [try folder("Mail", readable: false), try file("chat.db", readable: false)]

        XCTAssertEqual(FullDiskAccess.status(probing: probes), .denied)
    }

    func testOneReadableProbeIsEnough() throws {
        let probes = [try file("TCC.db", readable: false), try folder("Safari", readable: true)]

        XCTAssertEqual(FullDiskAccess.status(probing: probes), .granted)
    }

    func testMissingProbesAreSkipped() throws {
        let missing = directory.appendingPathComponent("missing")

        XCTAssertEqual(FullDiskAccess.status(probing: [missing]), .unknown)
        XCTAssertEqual(FullDiskAccess.status(probing: []), .unknown)
        XCTAssertEqual(FullDiskAccess.status(probing: [missing, try file("chat.db", readable: false)]), .denied)
    }

    func testTheDefaultProbesStartWithTheSystemDatabase() {
        let home = URL(fileURLWithPath: "/Users/someone")

        XCTAssertEqual(FullDiskAccess.defaultProbes(home: home).map(\.path), [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Users/someone/Library/Safari/LocalStorage",
            "/Users/someone/Library/Mail/V10",
            "/Users/someone/Library/Messages/chat.db",
        ])
    }
}
