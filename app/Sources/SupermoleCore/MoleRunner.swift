import Foundation

/// What a finished `mo` run left behind.
public struct MoleOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum MoleError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case failed(status: Int32, message: String)
    case unreadableOutput(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return reason
        case .failed(let status, let message):
            return message.isEmpty ? "mo exited with status \(status)" : message
        case .unreadableOutput(let reason):
            return reason
        }
    }
}

/// Runs the installed `mo` with no terminal attached.
///
/// Every run gets `NO_COLOR` and `TERM=dumb`, so the text a section shows has
/// no escape codes, and a PATH that also holds the folders `claude`, `codex`
/// and Homebrew live in, which a GUI app does not inherit from a shell.
public struct MoleRunner: Sendable {
    public let executable: URL
    public let environment: [String: String]

    public init(executable: URL, environment: [String: String] = MoleRunner.defaultEnvironment()) {
        self.executable = executable
        self.environment = environment
    }

    public static let extraSearchPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func defaultEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        // A deletion run must never become permanent through an inherited
        // variable; mo's default moves uninstalled apps to the Trash.
        environment.removeValue(forKey: "MOLE_DELETE_MODE")
        let userBin = MoleLocator.userInstallDirectory(home: home).path
        var path: [String] = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in [userBin] + extraSearchPaths where !path.contains(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    /// Runs `mo` to completion. A nonzero status is returned, not thrown, so
    /// callers can show what `mo` printed.
    public func run(_ arguments: [String]) async throws -> MoleOutput {
        let process = makeProcess(arguments)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: MoleError.launchFailed(error.localizedDescription))
                        return
                    }
                    // Drain both pipes while mo runs: a full pipe would block it.
                    let errorCollector = DataCollector()
                    let errorHandle = stderr.fileHandleForReading
                    errorHandle.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                        } else {
                            errorCollector.append(chunk)
                        }
                    }
                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    errorHandle.readabilityHandler = nil
                    errorCollector.append(errorHandle.readDataToEndOfFile())
                    continuation.resume(returning: MoleOutput(
                        status: process.terminationStatus,
                        stdout: outputData,
                        stderr: String(decoding: errorCollector.data, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs `mo` and decodes its JSON output.
    public func decode<Value: Decodable>(_ type: Value.Type, _ arguments: [String]) async throws -> Value {
        try MoleJSON.decode(type, from: await succeededOutput(arguments))
    }

    /// The standard output of a run that succeeded; a failed run throws what
    /// `mo` printed on standard error.
    func succeededOutput(_ arguments: [String]) async throws -> Data {
        let output = try await run(arguments)
        guard output.succeeded else {
            throw MoleError.failed(status: output.status, message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.stdout
    }

    /// Like `decode`, for commands that still print their JSON when they stop
    /// early (an incomplete clean preview exits nonzero with its report): any
    /// readable output wins, and only a run with none is an error.
    public func decodeReport<Value: Decodable>(_ type: Value.Type, _ arguments: [String]) async throws -> Value {
        let output = try await run(arguments)
        if output.stdout.contains(where: { !Self.isWhitespace($0) }) {
            return try MoleJSON.decode(type, from: output.stdout)
        }
        throw MoleError.failed(status: output.status, message: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// Streams the program's standard output line by line until it exits or
    /// the consumer stops listening, which terminates it. With
    /// `includeErrors`, standard error joins the stream; otherwise it is kept
    /// for the error a failed run finishes with.
    public func lines(_ arguments: [String], includeErrors: Bool = false) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = makeProcess(arguments)
            let stdout = Pipe()
            process.standardOutput = stdout
            let errorCollector = DataCollector()
            if includeErrors {
                process.standardError = stdout
            } else {
                let stderr = Pipe()
                process.standardError = stderr
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        errorCollector.append(chunk)
                    }
                }
            }
            let splitter = LineSplitter()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                for line in splitter.append(chunk) {
                    continuation.yield(line)
                }
            }
            process.terminationHandler = { finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                if let last = splitter.finish() {
                    continuation.yield(last)
                }
                if finished.terminationReason == .exit && finished.terminationStatus != 0 {
                    let message = String(decoding: errorCollector.data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(throwing: MoleError.failed(status: finished.terminationStatus, message: message))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: MoleError.launchFailed(error.localizedDescription))
            }
        }
    }

    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }
}

/// Collects a pipe's bytes from its reader thread.
final class DataCollector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Splits a byte stream into lines, from the pipe's reader thread.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        return lines
    }

    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return line
    }
}

public enum MoleJSON {
    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw MoleError.unreadableOutput("Could not read mo's JSON output: \(error)")
        }
    }
}
