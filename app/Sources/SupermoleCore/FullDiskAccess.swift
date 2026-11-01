import Darwin
import Foundation

/// Whether macOS lets this app read the places it keeps behind Full Disk Access.
///
/// `mo` runs as the app's child, so macOS gives it the app's access: without
/// it a scan never sees Mail, Messages, Safari and some caches. The check reads
/// protected places, which never makes macOS ask, the way `mo`'s own
/// `has_full_disk_access` does (`lib/core/ui.sh`); it reads the system TCC
/// database first, since every Mac has one.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// None of the probed places exists, so nothing tells either way.
        case unknown
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private static let systemTCCDatabase = "/Library/Application Support/com.apple.TCC/TCC.db"
    private static let userProbes = ["Library/Safari/LocalStorage", "Library/Mail/V10", "Library/Messages/chat.db"]

    public static func defaultProbes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: systemTCCDatabase)] + userProbes.map { home.appendingPathComponent($0) }
    }

    /// Granted when any probe can be read, denied when some exist and none can.
    public static func status(probing probes: [URL] = defaultProbes()) -> Status {
        var probedAny = false
        for probe in probes {
            var isDirectory: ObjCBool = false
            // stat succeeds without the access; only reading the contents proves it.
            guard FileManager.default.fileExists(atPath: probe.path, isDirectory: &isDirectory) else { continue }
            probedAny = true
            if canRead(probe, isDirectory: isDirectory.boolValue) { return .granted }
        }
        return probedAny ? .denied : .unknown
    }

    /// A refusal here is the answer the check looks for, not an error to report.
    private static func canRead(_ url: URL, isDirectory: Bool) -> Bool {
        if isDirectory {
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
