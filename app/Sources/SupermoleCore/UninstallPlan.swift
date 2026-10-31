import Foundation

/// `mo uninstall --dry-run --json <paths>`: what uninstalling the named apps
/// would remove (lib/uninstall/plan_json.sh). Sizes are in KiB, null when
/// unknown; `review_only` rows are listed for the person and never removed.
public struct UninstallPlan: Decodable, Sendable, Equatable {
    public let withData: Bool
    public let totalSizeKb: Int64?
    public let apps: [App]
    /// Apps that need their vendor's own uninstaller.
    public let blocked: [Blocked]
    /// Apps `mo` will not move from where they are; the person does it in Finder.
    public let manual: [Manual]

    /// The preview of uninstalling exactly these apps (bundle paths).
    public static func arguments(paths: [String], withData: Bool) -> [String] {
        ["uninstall", "--dry-run", "--json"] + dataFlag(withData) + paths
    }

    /// The real run, confirmed by the click on the preview: the apps go to
    /// the Trash with what the preview listed.
    public static func uninstallArguments(paths: [String], withData: Bool) -> [String] {
        ["uninstall", "--yes"] + dataFlag(withData) + paths
    }

    private static func dataFlag(_ withData: Bool) -> [String] {
        withData ? ["--with-data"] : []
    }

    public struct Row: Decodable, Sendable, Equatable, Identifiable {
        public let path: String
        public let sizeKb: Int64?

        public var id: String { path }
        public var bytes: Int64 { (sizeKb ?? 0) * 1024 }
    }

    /// Personal data left in place; it is not measured.
    public struct KeptRow: Decodable, Sendable, Equatable, Identifiable {
        public let path: String

        public var id: String { path }
    }

    public struct PersonalData: Decodable, Sendable, Equatable {
        public let remove: [Row]
        public let keep: [KeptRow]
    }

    public struct App: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let path: String
        public let bundleId: String
        public let homebrewCask: String?
        /// The uninstall quits it first.
        public let running: Bool
        /// A Homebrew cask, or an app in a folder only an administrator can
        /// change: the run opens an administrator session first.
        public let needsAdmin: Bool
        public let steamManaged: Bool
        /// The app bundle alone.
        public let sizeKb: Int64?
        public let notes: [String]
        public let leftovers: [Row]
        public let system: [Row]
        public let reviewOnly: [Row]
        public let personalData: PersonalData

        public var id: String { path }

        /// Everything this app's uninstall removes: the bundle, its leftovers
        /// and the personal data chosen to go.
        public var removedRows: [Row] { leftovers + system + personalData.remove }

        public var bytes: Int64 {
            (sizeKb ?? 0) * 1024 + removedRows.reduce(0) { $0 + $1.bytes }
        }
    }

    public struct Blocked: Decodable, Sendable, Equatable, Identifiable {
        public let name: String
        public let vendor: String

        public var id: String { name }
    }

    public struct Manual: Decodable, Sendable, Equatable, Identifiable {
        public let name: String

        public var id: String { name }
    }

    public var totalBytes: Int64 { apps.reduce(0) { $0 + $1.bytes } }

    /// Apps the app can uninstall today; the others wait for an administrator
    /// session, which Supermole cannot open yet.
    public var appsWithoutAdmin: [App] { apps.filter { !$0.needsAdmin } }
    public var appsNeedingAdmin: [App] { apps.filter(\.needsAdmin) }
}
