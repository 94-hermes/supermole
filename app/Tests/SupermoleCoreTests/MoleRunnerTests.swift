import XCTest
@testable import SupermoleCore

final class MoleRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// A stand-in for `mo`: a shell script with the given body.
    private func fakeMo(_ body: String) throws -> MoleRunner {
        let script = directory.appendingPathComponent("mo")
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return MoleRunner(executable: script)
    }

    func testRunReturnsStatusOutputAndErrors() async throws {
        let runner = try fakeMo(#"echo "args:$*"; echo "warning" >&2; exit 3"#)

        let output = try await runner.run(["clean", "--dry-run"])

        XCTAssertEqual(output.status, 3)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "args:clean --dry-run\n")
        XCTAssertEqual(output.stderr, "warning\n")
    }

    func testRunDrainsOutputLargerThanAPipeBuffer() async throws {
        let runner = try fakeMo(#"head -c 300000 /dev/zero | tr '\0' x; head -c 100000 /dev/zero | tr '\0' y >&2"#)

        let output = try await runner.run([])

        XCTAssertEqual(output.stdout.count, 300_000)
        XCTAssertEqual(output.stderr.count, 100_000)
    }

    func testDecodeThrowsWhatMoPrintedWhenItFails() async throws {
        let runner = try fakeMo(#"echo "Path not found" >&2; exit 1"#)

        do {
            _ = try await runner.decode(HistoryReport.self, ["history", "--json"])
            XCTFail("decode succeeded")
        } catch let error as MoleError {
            XCTAssertEqual(error, .failed(status: 1, message: "Path not found"))
        }
    }

    func testRunsSeeNoColorAndADumbTerminal() async throws {
        let runner = try fakeMo(#"echo "$NO_COLOR|$TERM|${MOLE_DELETE_MODE:-unset}""#)
        let environment = MoleRunner.defaultEnvironment(base: ["PATH": "/usr/bin", "MOLE_DELETE_MODE": "permanent"])
        let output = try await MoleRunner(executable: runner.executable, environment: environment).run([])

        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "1|dumb|unset\n")
    }

    func testThePathGainsTheUserAndHomebrewFoldersOnce() {
        let home = URL(fileURLWithPath: "/Users/test")
        let environment = MoleRunner.defaultEnvironment(base: ["PATH": "/usr/bin:/opt/homebrew/bin"], home: home)
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []

        XCTAssertEqual(path.first, "/usr/bin")
        XCTAssertTrue(path.contains("/Users/test/.local/bin"))
        XCTAssertEqual(path.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }

    func testLinesStreamsEachLineAndTheLastOneWithoutANewline() async throws {
        let runner = try fakeMo(#"printf 'one\ntwo\nthree'"#)

        var lines: [String] = []
        for try await line in runner.lines([]) {
            lines.append(line)
        }

        XCTAssertEqual(lines, ["one", "two", "three"])
    }

    func testLinesFinishWithTheErrorMoPrinted() async throws {
        let runner = try fakeMo(#"echo partial; echo "no metrics collected" >&2; exit 1"#)

        var lines: [String] = []
        do {
            for try await line in runner.lines([]) {
                lines.append(line)
            }
            XCTFail("stream finished without an error")
        } catch let error as MoleError {
            XCTAssertEqual(error, .failed(status: 1, message: "no metrics collected"))
        }
        XCTAssertEqual(lines, ["partial"])
    }

    func testLinesCanCarryStandardError() async throws {
        let runner = try fakeMo(#"echo out; echo err >&2"#)

        var lines: [String] = []
        for try await line in runner.lines([], includeErrors: true) {
            lines.append(line)
        }

        XCTAssertEqual(Set(lines), ["out", "err"])
    }

    func testStoppingTheStreamStopsMo() async throws {
        let marker = directory.appendingPathComponent("still-running")
        let runner = try fakeMo("echo first; sleep 5; touch '\(marker.path)'")

        for try await _ in runner.lines([]) {
            break
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

final class MoleRunnerReportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fakeMo(_ body: String) throws -> MoleRunner {
        let script = directory.appendingPathComponent("mo")
        try Data("#!/bin/bash\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return MoleRunner(executable: script)
    }

    func testAReportPrintedBeforeAFailureIsStillRead() async throws {
        let runner = try fakeMo(#"echo '{"sessions": [], "deletions": []}'; exit 124"#)

        let report = try await runner.decodeReport(HistoryReport.self, [])

        XCTAssertEqual(report.sessions, [])
    }

    func testARunWithNoReportFailsWithWhatMoSaid() async throws {
        let runner = try fakeMo(#"echo "only describes a preview" >&2; exit 1"#)

        do {
            _ = try await runner.decodeReport(HistoryReport.self, [])
            XCTFail("decodeReport succeeded without output")
        } catch let error as MoleError {
            XCTAssertEqual(error, .failed(status: 1, message: "only describes a preview"))
        }
    }
}
