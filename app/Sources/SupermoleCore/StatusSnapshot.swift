import Foundation

/// One `mo status --json` (or `--watch` line) snapshot, the fields the app shows.
///
/// Every field is optional: `mo status` leaves out what it could not collect,
/// and Go encodes an empty list as `null`.
public struct StatusSnapshot: Decodable, Sendable, Equatable {
    public let host: String?
    public let uptime: String?
    public let uptimeSeconds: UInt64?
    public let hardware: Hardware?
    public let healthScore: Int?
    public let healthScoreMsg: String?
    public let cpu: CPU?
    public let memory: Memory?
    public let disks: [Disk]?
    public let batteries: [Battery]?
    public let trashSize: UInt64?
    public let topProcesses: [TopProcess]?

    public struct Hardware: Decodable, Sendable, Equatable {
        public let model: String?
        public let cpuModel: String?
        public let totalRam: String?
        public let diskSize: String?
        public let osVersion: String?
    }

    public struct CPU: Decodable, Sendable, Equatable {
        public let usage: Double?
        public let coreCount: Int?
    }

    public struct Memory: Decodable, Sendable, Equatable {
        public let used: UInt64?
        public let total: UInt64?
        public let usedPercent: Double?
        public let swapUsed: UInt64?
    }

    public struct Disk: Decodable, Sendable, Equatable {
        public let mount: String?
        public let used: UInt64?
        public let total: UInt64?
        public let usedPercent: Double?
        public let external: Bool?
        public let purgeable: UInt64?
    }

    public struct Battery: Decodable, Sendable, Equatable {
        public let percent: Double?
        public let status: String?
        public let timeLeft: String?
        public let health: String?
        public let cycleCount: Int?
        public let capacity: Double?
    }

    public struct TopProcess: Decodable, Sendable, Equatable, Identifiable {
        public let pid: Int
        public let name: String?
        public let cpu: Double?
        public let memoryBytes: UInt64?

        public var id: Int { pid }
    }

    /// The startup volume, which `mo status` lists first among internal disks.
    public var startupDisk: Disk? {
        disks?.first { $0.mount == "/" } ?? disks?.first { $0.external != true }
    }
}
