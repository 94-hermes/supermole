import XCTest
@testable import SupermoleCore

final class ExplainRequestTests: XCTestCase {
    func testTheRequestPassesItsRowsAsOneJSONArgument() throws {
        let request = ExplainRequest(items: [.init(path: "/Users/test/My \"odd\" folder", label: "Odd", size: 42)])

        let arguments = try request.arguments()

        XCTAssertEqual(Array(arguments.prefix(2)), ["analyze", "--explain"])
        let items = try JSONSerialization.jsonObject(with: Data(arguments[2].utf8)) as? [[String: Any]]
        XCTAssertEqual(items?.first?["path"] as? String, "/Users/test/My \"odd\" folder")
        XCTAssertEqual(items?.first?["size"] as? Int, 42)
        XCTAssertEqual(arguments.count, 3)
    }

    func testADeepLookAddsTheFlag() throws {
        let request = ExplainRequest(items: [.init(path: "/x", label: "x", size: 1)], deep: true)

        XCTAssertEqual(try request.arguments().last, "--deep")
    }

    func testRowsAreSplitIntoBatchesMoAccepts() {
        let items = (0..<23).map { ExplainRequest.Item(path: "/p\($0)", label: "p", size: 1) }

        XCTAssertEqual(ExplainRequest.batches(of: items).map(\.items.count), [10, 10, 3])
    }

    func testTheReportReadsAnswersAndErrors() throws {
        let json = #"{"answers":{"/a":{"verdict":"safe","what":"Un cache.","if_deleted":"Rien.","advice":"Vas-y.","needs_exploration":true,"explored":false,"provider":"Claude","is_dir":true,"mod_time":"2026-10-01T10:00:00Z","answered_at":"2026-10-31T12:08:16.356675+01:00"}},"errors":{"/b":"claude is logged out"}}"#

        let report = try MoleJSON.decode(ExplainReport.self, from: Data(json.utf8))

        XCTAssertEqual(report.answers["/a"]?.provider, "Claude")
        XCTAssertEqual(report.answers["/a"]?.needsExploration, true)
        XCTAssertNotNil(report.answers["/a"]?.answeredDate)
        XCTAssertEqual(report.errors["/b"], "claude is logged out")
    }
}
