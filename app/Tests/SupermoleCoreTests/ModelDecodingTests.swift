import XCTest
@testable import SupermoleCore

final class ModelDecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testStatusSnapshotReadsTheFieldsTheAppShowsAndToleratesNullLists() throws {
        let snapshot = try MoleJSON.decode(StatusSnapshot.self, from: fixture("status"))

        XCTAssertEqual(snapshot.healthScore, 86)
        XCTAssertEqual(snapshot.hardware?.cpuModel, "Apple M4")
        XCTAssertEqual(snapshot.memory?.total, 17_179_869_184)
        XCTAssertEqual(snapshot.batteries?.first?.cycleCount, 105)
        XCTAssertEqual(snapshot.topProcesses?.first?.memoryBytes, 71_155_712)
        // The startup volume, not the first disk listed.
        XCTAssertEqual(snapshot.startupDisk?.mount, "/")
        XCTAssertEqual(snapshot.startupDisk?.purgeable, 5_156_479_552)
    }

    func testAnalyzeResultListsEntriesLargestFirstAndFlagsAPartialScan() throws {
        let result = try MoleJSON.decode(AnalyzeResult.self, from: fixture("analyze"))

        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.sortedEntries.map(\.name), ["User Library", "Applications", "Xcode Simulators"])
        XCTAssertEqual(result.sortedEntries.last?.insight, true)
        XCTAssertEqual(result.largeFiles?.first?.size, 4_000_000_000)
    }

    func testAnalyzeArgumentsPutTheFlagBeforeThePath() {
        XCTAssertEqual(AnalyzeResult.arguments(for: nil), ["analyze", "--json"])
        XCTAssertEqual(AnalyzeResult.arguments(for: ""), ["analyze", "--json"])
        XCTAssertEqual(AnalyzeResult.arguments(for: "/Users/test/My Folder"), ["analyze", "--json", "/Users/test/My Folder"])
    }

    func testHistoryReportReadsSessionsAndDeletionsWithAMissingSize() throws {
        let report = try MoleJSON.decode(HistoryReport.self, from: fixture("history"))

        XCTAssertEqual(report.sessions?.first?.command, "clean")
        XCTAssertEqual(report.sessions?.first?.actions?.removed, 1102)
        XCTAssertNil(report.deletions?.first?.sizeKb)
        XCTAssertEqual(HistoryReport.arguments(limit: 5), ["history", "--json", "--limit", "5"])
    }

    func testUnreadableJSONSaysSoInsteadOfCrashing() {
        XCTAssertThrowsError(try MoleJSON.decode(StatusSnapshot.self, from: Data("not json".utf8))) { error in
            guard case MoleError.unreadableOutput = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}
