import XCTest
@testable import SupermoleCore

final class MoleTextTests: XCTestCase {
    func testAHealthMessageSplitsIntoARatingAndItsIssues() {
        XCTAssertEqual(MoleText.healthMessage("Excellent"), .init(rating: "Excellent", issues: []))
        XCTAssertEqual(
            MoleText.healthMessage("Good: High CPU, Disk Almost Full"),
            .init(rating: "Good", issues: ["High CPU", "Disk Almost Full"])
        )
        XCTAssertEqual(MoleText.healthMessage(""), .init(rating: "", issues: []))
    }

    func testHumanSizesReadBackInDecimalUnitsLikeFinder() {
        XCTAssertEqual(MoleText.bytes(fromHumanSize: "8.40GB"), 8_400_000_000)
        XCTAssertEqual(MoleText.bytes(fromHumanSize: "571.9MB"), 571_900_000)
        XCTAssertEqual(MoleText.bytes(fromHumanSize: "12KB"), 12_000)
        XCTAssertEqual(MoleText.bytes(fromHumanSize: "0B"), 0)
        XCTAssertNil(MoleText.bytes(fromHumanSize: "lots"))
        XCTAssertNil(MoleText.bytes(fromHumanSize: "3PB"))
    }

    func testHistoryTimesReadAsLocalDates() throws {
        let date = try XCTUnwrap(MoleText.historyDate("2026-10-29 15:59:02"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2026, 10, 29, 15, 59, 2])
        XCTAssertNil(MoleText.historyDate(""))
    }
}
