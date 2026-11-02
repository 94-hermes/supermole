import XCTest
@testable import SupermoleCore

final class EngineVersionTests: XCTestCase {
    func testReadsReleaseNumbersWithOrWithoutDecorations() {
        XCTAssertEqual(EngineVersion("1.66.0")?.components, [1, 66, 0])
        XCTAssertEqual(EngineVersion("V1.65.1")?.components, [1, 65, 1])
        XCTAssertEqual(EngineVersion(" 1.66.0-dev ")?.components, [1, 66, 0])
        XCTAssertEqual(EngineVersion("1.66.0+build.7")?.components, [1, 66, 0])
    }

    func testRefusesWhatIsNotANumber() {
        XCTAssertNil(EngineVersion(""))
        XCTAssertNil(EngineVersion("main"))
        XCTAssertNil(EngineVersion("1..2"))
        XCTAssertNil(EngineVersion("1.x.0"))
    }

    func testComparesNumberByNumber() throws {
        let older = try XCTUnwrap(EngineVersion("1.9.2"))
        let newer = try XCTUnwrap(EngineVersion("1.10.0"))

        XCTAssertLessThan(older, newer)
        XCTAssertLessThan(try XCTUnwrap(EngineVersion("1.65.1")), try XCTUnwrap(EngineVersion("1.66.0")))
        XCTAssertEqual(EngineVersion("1.66"), EngineVersion("1.66.0"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(EngineVersion("1.66.0")), try XCTUnwrap(EngineVersion("1.66")))
    }

    func testFindsTheVersionInWhatMoVersionPrints() {
        let output = """
        Mole version 1.65.1
        macOS: 27.0.1
        Architecture: arm64
        """

        XCTAssertEqual(EngineVersion(versionOutput: output)?.description, "1.65.1")
        XCTAssertNil(EngineVersion(versionOutput: "usage: mo [command]"))
        XCTAssertNil(EngineVersion(versionOutput: "Mole version"))
    }
}
