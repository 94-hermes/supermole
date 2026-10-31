import XCTest
@testable import SupermoleCore

final class CleanPreviewTests: XCTestCase {
    private func preview() throws -> CleanPreview {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "clean_preview", withExtension: "json", subdirectory: "Fixtures"))
        return try MoleJSON.decode(CleanPreview.self, from: Data(contentsOf: url))
    }

    func testThePreviewReadsTotalsInBytes() throws {
        let preview = try preview()

        XCTAssertEqual(preview.totalBytes, 5172 * 1024)
        XCTAssertTrue(preview.sizePartial)
        XCTAssertFalse(preview.isComplete)
        XCTAssertEqual(CleanPreview.arguments, ["clean", "--dry-run", "--json"])
    }

    func testSectionsWithNothingToFreeAreLeftOutAndTheRestSortedBySize() throws {
        XCTAssertEqual(try preview().sortedSections.map(\.name), ["User essentials", "Developer tools"])
    }

    func testARowCountedUnderAnotherStaysOutOfItsSection() throws {
        let rows = try preview().entries(in: "Developer tools")

        XCTAssertEqual(rows.map(\.path), ["/Users/test/Library/Developer/Xcode/DerivedData"])
    }

    func testTheTrashIsNamedWhenTheCleanupEmptiesIt() throws {
        XCTAssertTrue(try preview().emptiesTrash(home: "/Users/test"))
        XCTAssertFalse(try preview().emptiesTrash(home: "/Users/other"))
    }

    func testSectionHeadersMarkProgressAndNothingElseDoes() {
        XCTAssertEqual(CleanProgress.section(in: "➤ User essentials"), "User essentials")
        XCTAssertEqual(CleanProgress.section(in: "\u{1B}[1;35m➤ Browsers\u{1B}[0m"), "Browsers")
        XCTAssertNil(CleanProgress.section(in: "  ✓ Removed 12 items"))
        XCTAssertNil(CleanProgress.section(in: "➤ "))
    }
}

final class CleanPreviewSummaryTests: XCTestCase {
    private func preview() throws -> CleanPreview {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "clean_preview", withExtension: "json", subdirectory: "Fixtures"))
        return try MoleJSON.decode(CleanPreview.self, from: Data(contentsOf: url))
    }

    func testEverySectionWithLinesShowsEvenWithoutASize() throws {
        let summaries = try preview().summaries

        XCTAssertEqual(summaries.map(\.name), ["User essentials", "Developer tools", "Browsers"])
        XCTAssertEqual(summaries.last?.bytes, 0)
        XCTAssertEqual(summaries.last?.lines, ["Chrome old versions · would remove 2 old versions"])
    }

    func testOwnerCommandLinesStayWithTheirSection() throws {
        let tools = try XCTUnwrap(try preview().summaries.first { $0.name == "Developer tools" })

        XCTAssertEqual(tools.lines, ["npm cache · would clean", "Homebrew cleanup · would free 80MB"])
        XCTAssertEqual(tools.bytes, 100 * 1024)
    }

    func testThePreviewSaysWhetherSystemCachesWereIncluded() throws {
        XCTAssertEqual(try preview().systemIncluded, false)
    }
}
