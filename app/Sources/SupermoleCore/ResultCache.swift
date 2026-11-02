import CryptoKit
import Foundation
import os

/// Keeps the JSON of read-only `mo` commands between launches, so a space
/// shows its last result at once while a fresh one is read.
///
/// Only listings and measurements go here, never a preview a deletion acts
/// on: those are always read fresh. One file per command, named by a digest of
/// its arguments, dated by its modification time; past `limit` files the
/// oldest go.
public struct ResultCache: Sendable {
    public static let defaultLimit = 200
    private static let fallbackBundleIdentifier = "com.airkul.supermole"
    static let logger = Logger(subsystem: fallbackBundleIdentifier, category: "ResultCache")

    /// A result read back, with when `mo` produced it.
    public struct Kept<Value: Sendable>: Sendable {
        public let value: Value
        public let savedAt: Date

        public func isRecent(within interval: TimeInterval, now: Date = .now) -> Bool {
            now.timeIntervalSince(savedAt) < interval
        }
    }

    public let directory: URL
    public let limit: Int

    public init(directory: URL = ResultCache.defaultDirectory(), limit: Int = ResultCache.defaultLimit) {
        self.directory = directory
        self.limit = limit
    }

    /// `~/Library/Caches/<bundle id>/results`.
    public static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier, isDirectory: true)
            .appendingPathComponent("results", isDirectory: true)
    }

    /// The kept output of `arguments`, decoded; nil when there is none or it
    /// no longer decodes (an older `mo`'s shape), which is then removed.
    public func kept<Value: Decodable & Sendable>(_ type: Value.Type, for arguments: [String]) async -> Kept<Value>? {
        let file = file(for: arguments)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let value = try MoleJSON.decode(type, from: Data(contentsOf: file))
            let savedAt = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return Kept(value: value, savedAt: savedAt)
        } catch {
            Self.logger.notice("Dropping an unreadable kept result: \(error.localizedDescription, privacy: .public)")
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                Self.logger.error("Could not drop it: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    /// Keeps `data` as the output of `arguments`, then trims the oldest files.
    public func store(_ data: Data, for arguments: [String]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(for: arguments), options: .atomic)
        try trim()
    }

    func file(for arguments: [String]) -> URL {
        let digest = SHA256.hash(data: Data(arguments.joined(separator: "\u{0}").utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func trim() throws {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            .filter { $0.pathExtension == "json" }
        guard files.count > limit else { return }
        let dated = try files.map { ($0, try $0.resourceValues(forKeys: Set(keys)).contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

extension MoleRunner {
    /// Like `decode`, keeping the output in `cache` for the next launch. A
    /// result that cannot be kept is still returned; the failure is logged.
    public func decode<Value: Decodable>(
        _ type: Value.Type,
        _ arguments: [String],
        keepingIn cache: ResultCache
    ) async throws -> Value {
        let data = try await succeededOutput(arguments)
        let value = try MoleJSON.decode(type, from: data)
        do {
            try await cache.store(data, for: arguments)
        } catch {
            ResultCache.logger.error("Could not keep a result: \(error.localizedDescription, privacy: .public)")
        }
        return value
    }
}
