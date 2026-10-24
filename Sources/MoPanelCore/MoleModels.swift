import Foundation

/// Decoders model Mole V1.62.0's public JSON. Unknown added keys are ignored,
/// but missing required keys and new scan-state values fail closed.
public enum MoleJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func decodeStatus(_ data: Data) throws -> StatusSnapshot {
        let value = try decoder().decode(StatusSnapshot.self, from: data)
        guard !value.collectedAt.isEmpty,
              value.cpu.usage.isFinite, value.cpu.usage >= 0,
              value.memory.usedPercent.isFinite,
              value.cpu.logicalCpu > 0 || value.memory.total > 0 ||
                value.disks.contains(where: { $0.total > 0 }) || value.processCollectedAt != nil
        else { throw MoleError.invalidOutput("Status contains no usable core metrics.") }
        return value
    }

    public static func decodeAnalyze(_ data: Data) throws -> AnalyzeSnapshot {
        let value = try decoder().decode(AnalyzeSnapshot.self, from: data)
        try SafePath.validateAbsolute(value.path)
        guard value.totalSize >= 0, value.totalFiles.map({ $0 >= 0 }) ?? true else {
            throw MoleError.invalidOutput("Analyze returned a negative total.")
        }
        for entry in value.entries {
            try SafePath.validateAbsolute(entry.path)
            guard entry.size >= 0 || entry.scanStatus == .unavailable else {
                throw MoleError.invalidOutput("Only unavailable entries may have unknown negative size.")
            }
        }
        for entry in value.largeFiles {
            try SafePath.validateAbsolute(entry.path)
            guard entry.size >= 0 else { throw MoleError.invalidOutput("Negative file size.") }
        }
        return value
    }

    public static func decodeHistory(_ data: Data) throws -> HistorySnapshot {
        let value = try decoder().decode(HistorySnapshot.self, from: data)
        guard (1...200).contains(value.limit) else {
            throw MoleError.invalidOutput("History limit is outside the supported contract.")
        }
        return value
    }

    public static func decodeApps(_ data: Data) throws -> [InstalledApp] {
        let apps = try decoder().decode([InstalledApp].self, from: data)
        var paths = Set<String>()
        for app in apps {
            try SafePath.validateAbsolute(app.path)
            guard app.path.lowercased().hasSuffix(".app"), paths.insert(app.path).inserted else {
                throw MoleError.invalidOutput("App inventory includes a duplicate or non-app path.")
            }
        }
        return apps
    }
}

public enum MoleError: Error, LocalizedError, Equatable, Sendable {
    case invalidOutput(String)
    case invalidArgument(String)
    case incompatible(String)
    public var errorDescription: String? {
        switch self {
        case .invalidOutput(let text): return "Mole JSON: \(text)"
        case .invalidArgument(let text): return "Mole argument: \(text)"
        case .incompatible(let text): return "Mole compatibility: \(text)"
        }
    }
}

public struct StatusSnapshot: Decodable, Sendable {
    public let collectedAt: String
    public let host: String?
    public let platform: String?
    public let uptime: String?
    public let uptimeSeconds: UInt64?
    public let procs: UInt64?
    public let hardware: HardwareInfo?
    public let healthScore: Int?
    public let healthScoreMsg: String?
    public let cpu: CPUStatus
    public let memory: MemoryStatus
    public let diskIo: DiskIOStatus?
    public var diskIO: DiskIOStatus? { diskIo }
    public let thermal: ThermalStatus?
    public let networkHistory: NetworkHistory?
    public let proxy: ProxyStatus?
    public let trashSize: UInt64?
    public let trashApprox: Bool?
    public let processCollectedAt: String?
    public let processStale: Bool?
    public let zombieCount: Int?
    public let zombieParentsComplete: Bool?
    public let processWatch: ProcessWatchConfig?
    private let diskReadings: [DiskStatus]?
    private let networkReadings: [NetworkStatus]?
    private let batteryReadings: [BatteryStatus]?
    private let gpuReadings: [GPUStatus]?
    private let sensorReadings: [SensorReading]?
    private let bluetoothReadings: [BluetoothDevice]?
    private let processReadings: [MoleProcessInfo]?
    private let zombieParentReadings: [ZombieParent]?
    private let alertReadings: [ProcessAlert]?
    public var disks: [DiskStatus] { diskReadings ?? [] }
    public var network: [NetworkStatus] { networkReadings ?? [] }
    public var batteries: [BatteryStatus] { batteryReadings ?? [] }
    public var gpu: [GPUStatus] { gpuReadings ?? [] }
    public var sensors: [SensorReading] { sensorReadings ?? [] }
    public var bluetooth: [BluetoothDevice] { bluetoothReadings ?? [] }
    public var topProcesses: [MoleProcessInfo] { processReadings ?? [] }
    public var zombieParents: [ZombieParent] { zombieParentReadings ?? [] }
    public var processAlerts: [ProcessAlert] { alertReadings ?? [] }
    enum CodingKeys: String, CodingKey {
        case collectedAt, host, platform, uptime, uptimeSeconds, procs, hardware,
             healthScore, healthScoreMsg, cpu, memory, diskIo, thermal, networkHistory,
             proxy, trashSize, trashApprox, processCollectedAt, processStale,
             zombieCount, zombieParentsComplete, processWatch
        case diskReadings = "disks", networkReadings = "network", batteryReadings = "batteries"
        case gpuReadings = "gpu", sensorReadings = "sensors", bluetoothReadings = "bluetooth"
        case processReadings = "topProcesses", zombieParentReadings = "zombieParents"
        case alertReadings = "processAlerts"
    }
}

public struct HardwareInfo: Decodable, Sendable {
    public let model: String?
    public let cpuModel: String?
    public let totalRam: String?
    public let diskSize: String?
    public let osVersion: String?
    public let refreshRate: String?
}

public struct CPUStatus: Decodable, Sendable {
    public let usage: Double
    public let perCore: [Double]?
    public let perCoreEstimated: Bool?
    public let load1: Double?
    public let load5: Double?
    public let load15: Double?
    public let coreCount: Int?
    public let logicalCpu: Int
    public var logicalCPU: Int { logicalCpu }
    public let pCoreCount: Int?
    public let eCoreCount: Int?
}

public struct MemoryStatus: Decodable, Sendable {
    public let used: UInt64
    public let total: UInt64
    public let available: UInt64
    public let usedPercent: Double
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let cached: UInt64?
    public let pressure: String?
}

public struct DiskStatus: Decodable, Identifiable, Sendable {
    public let mount: String
    public let device: String?
    public let used: UInt64
    public let total: UInt64
    public let usedPercent: Double
    public let fstype: String?
    public let external: Bool?
    public let smartStatus: String?
    /// Mole omits unknown purgeable space. It must not be displayed as zero.
    public let purgeable: UInt64?
    public var id: String { mount }
}

public struct DiskIOStatus: Decodable, Sendable {
    /// Official units are MB/s, not bytes/s.
    public let readRate: Double
    public let writeRate: Double
}

public struct NetworkStatus: Decodable, Identifiable, Sendable {
    public let name: String
    public let rxRateMbs: Double
    public let txRateMbs: Double
    public let ip: String?
    public var id: String { name }
}

public struct NetworkHistory: Decodable, Sendable {
    public let rxHistory: [Double]?
    public let txHistory: [Double]?
}

public struct BatteryStatus: Decodable, Sendable {
    public let percent: Double?
    public let status: String?
    public let timeLeft: String?
    public let health: String?
    public let cycleCount: Int?
    public let capacity: Int?
}

public struct ThermalStatus: Decodable, Sendable {
    public let cpuTemp: Double?
    public let gpuTemp: Double?
    public let batteryTemp: Double?
    public let fanSpeed: Int?
    public let fanCount: Int?
    public let systemPower: Double?
    public let adapterPower: Double?
    public let batteryPower: Double?
    /// Mole's own presentation treats nonpositive temperature/power as unavailable.
    public static func availablePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

public struct GPUStatus: Decodable, Sendable {
    public let name: String?
    public let usage: Double?
    public let memoryUsed: Double?
    public let memoryTotal: Double?
    public let coreCount: Int?
    public let note: String?
}

public struct SensorReading: Decodable, Sendable {
    public let label: String
    public let value: Double
    public let unit: String
    public let note: String?
}

public struct BluetoothDevice: Decodable, Sendable {
    public let name: String
    public let connected: Bool
    public let battery: String?
}

public struct ProxyStatus: Decodable, Sendable {
    public let enabled: Bool
    public let type: String?
    public let host: String?
}

public struct MoleProcessInfo: Decodable, Identifiable, Sendable {
    public let pid: Int
    public let ppid: Int?
    public let name: String
    public let command: String?
    public let cpu: Double
    public let memory: Double
    public let memoryBytes: UInt64?
    public var id: Int { pid }
}

public struct ZombieParent: Decodable, Identifiable, Sendable {
    public let pid: Int
    public let name: String
    public let count: Int
    public var id: Int { pid }
}

public struct ProcessWatchConfig: Decodable, Sendable {
    public let enabled: Bool
    public let cpuThreshold: Double
    public let window: String
}

public struct ProcessAlert: Decodable, Identifiable, Sendable {
    public let pid: Int
    public let name: String
    public let command: String?
    public let cpu: Double
    public let threshold: Double
    public let window: String
    public let triggeredAt: String
    public let status: String
    public var id: String { "\(pid):\(triggeredAt)" }
}

public enum ScanState: String, Decodable, Sendable {
    case complete, partial, unavailable
    public var isMeasured: Bool { self != .unavailable }
}

public struct AnalyzeSnapshot: Decodable, Sendable {
    public let scanStatus: ScanState
    public let path: String
    public let overview: Bool
    public let entries: [AnalyzeEntry]
    public let totalSize: Int64
    public let totalFiles: Int64?
    private let largeFileReadings: [AnalyzeFile]?
    public var largeFiles: [AnalyzeFile] { largeFileReadings ?? [] }
    public var measuredTotalBytes: Int64? { scanStatus.isMeasured ? totalSize : nil }
    enum CodingKeys: String, CodingKey {
        case scanStatus, path, overview, entries, totalSize, totalFiles
        case largeFileReadings = "largeFiles"
    }
}

public struct AnalyzeEntry: Decodable, Identifiable, Sendable {
    public let scanStatus: ScanState
    public let name: String
    public let path: String
    public let size: Int64
    public let isDir: Bool
    public let insight: Bool?
    public let cleanable: Bool?
    public let lastAccess: String?
    public var id: String { path }
    /// A partial size is a lower bound. Unavailable is nil, never zero.
    public var measuredBytes: Int64? { scanStatus.isMeasured && size >= 0 ? size : nil }
}

public struct AnalyzeFile: Decodable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let size: Int64
    public var id: String { path }
}

public struct InstalledApp: Decodable, Identifiable, Sendable {
    public let name: String
    public let bundleId: String
    public var bundleID: String { bundleId }
    public let source: String
    public let uninstallName: String
    public let path: String
    /// Human-readable official size. Do not pretend it is an exact byte count.
    public let size: String
    public var id: String { path }
}

public struct HistorySnapshot: Decodable, Sendable {
    public let logs: HistoryLogs
    public let limit: Int
    public let sessions: [HistorySession]
    public let deletions: [HistoryDeletion]
}

public struct HistoryLogs: Decodable, Sendable {
    public let operations: String
    public let deletions: String
}

public struct HistorySession: Decodable, Identifiable, Sendable {
    public let command: String
    public let runId: String
    public let attribution: String
    public let startedAt: String
    public let endedAt: String
    public let items: Int?
    public let size: String
    public let operationCount: Int
    public let failedTasks: Int
    public let actions: HistoryActions
    public var id: String { "\(runId):\(command):\(startedAt):\(endedAt)" }
    public var isComplete: Bool { !endedAt.isEmpty }
    public var isUnambiguous: Bool { attribution == "run" && !runId.isEmpty }
}

public struct HistoryActions: Decodable, Sendable {
    public let removed: Int
    public let trashed: Int
    public let skipped: Int
    public let failed: Int
    public let rebuilt: Int
    public let other: Int
}

public struct HistoryDeletion: Decodable, Identifiable, Sendable {
    public let timestamp: String
    public let mode: String
    public let status: String
    public let sizeKb: Int64?
    public let path: String
    public var id: String { "\(timestamp):\(mode):\(status):\(path)" }
}

/// Incremental bounded NDJSON framing; callers must end the watch process if
/// a line is malformed instead of retaining stale data as a healthy live view.
public struct NDJSONFramer: Sendable {
    private var buffer = Data()
    public let maximumLineBytes: Int
    public init(maximumLineBytes: Int = 4 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let count = buffer.distance(from: buffer.startIndex, to: newline)
            guard count <= maximumLineBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw MoleError.invalidOutput("NDJSON line exceeded safety limit.")
            }
            let line = Data(buffer.prefix(count))
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= maximumLineBytes else {
            buffer.removeAll(keepingCapacity: false)
            throw MoleError.invalidOutput("NDJSON line exceeded safety limit.")
        }
        return lines
    }
    public mutating func finish() throws {
        defer { buffer.removeAll(keepingCapacity: false) }
        guard buffer.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) else {
            throw MoleError.invalidOutput("Watch stream ended with a truncated JSON line.")
        }
    }
}
