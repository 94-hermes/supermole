import XCTest
@testable import SupermoleCore

final class TerminalTextTests: XCTestCase {
    func testColorsAndCursorCodesAreRemoved() {
        XCTAssertEqual(TerminalText.clean("\u{1B}[0;32m✓\u{1B}[0m Installed to /usr/local/bin"), "✓ Installed to /usr/local/bin")
        XCTAssertEqual(TerminalText.clean("\u{1B}[2K\u{1B}[1GDone"), "Done")
        XCTAssertEqual(TerminalText.clean("\u{1B}[?25lhidden cursor\u{1B}[?25h"), "hidden cursor")
    }

    func testASpinnerLineShowsItsLastState() {
        XCTAssertEqual(TerminalText.clean("⠋ Downloading...\r⠙ Downloading...\r✓ Downloaded"), "✓ Downloaded")
        XCTAssertEqual(TerminalText.clean("Verifying...\r"), "Verifying...")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(TerminalText.clean("Prêt ! supermole 1.65.1 est installé."), "Prêt ! supermole 1.65.1 est installé.")
        XCTAssertEqual(TerminalText.clean(""), "")
    }

    func testTheRunLogKeepsTheLastCleanedLinesAndDropsBlankOnes() {
        var log = RunLog(length: 2)
        log.append("\u{1B}[0;32m✓\u{1B}[0m Removed Slack")
        log.append("   ")
        log.append("Moved to Trash")
        log.append("Done")

        XCTAssertEqual(log.lines, ["Moved to Trash", "Done"])
        XCTAssertFalse(log.isEmpty)
        XCTAssertTrue(RunLog().isEmpty)
    }
}
