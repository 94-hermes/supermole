import XCTest
@testable import SupermoleCore

final class ExplainAnswersTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testAMissingStoreReadsAsNoAnswers() throws {
        XCTAssertEqual(try ExplainAnswers.load(from: directory.appendingPathComponent("answers.json")), [:])
    }

    func testTheStoreGivesEachPathItsVerdict() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "explain_answers", withExtension: "json", subdirectory: "Fixtures"))
        let answers = try ExplainAnswers.load(from: fixture)

        XCTAssertEqual(answers["/Users/test/Downloads/old.dmg"]?.verdict, "safe")
        XCTAssertEqual(answers["/Users/test/Downloads/old.dmg"]?.ifDeleted, "Nothing breaks.")
    }

    func testAnotherSchemaVersionReadsAsNoAnswers() throws {
        let store = directory.appendingPathComponent("answers.json")
        try Data(#"{"schema_version":2,"answers":{"/x":{"verdict":"safe"}}}"#.utf8).write(to: store)

        XCTAssertEqual(try ExplainAnswers.load(from: store), [:])
    }

    func testTheStoreLivesWhereMoAnalyzeWritesIt() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(ExplainAnswers.storeURL(home: home).path, "/Users/test/.cache/mole/explain/answers.json")
    }
}
