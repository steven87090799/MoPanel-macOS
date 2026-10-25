import Foundation

public enum MemoryPressureLevel: String, Sendable {
    case normal, warning, critical

    /// The sysctl exposes notification flags (1/2/4), not VM's internal enum.
    public init?(systemValue: Int32) {
        switch systemValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }
    public init?(reported: String?) {
        switch reported?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "normal", "nominal": self = .normal
        case "warn", "warning": self = .warning
        case "critical": self = .critical
        default: return nil
        }
    }
}

public enum MonitorNetworkSelection {
    public static func resolve(_ interfaces: [NetworkStatus], manual: String?, primary: String?) -> String {
        if let manual, interfaces.contains(where: { $0.name == manual }) { return manual }
        if let primary, interfaces.contains(where: { $0.name == primary }) { return primary }
        let addressed = interfaces.filter { !($0.ip?.isEmpty ?? true) }
        let candidates = addressed.isEmpty ? interfaces : addressed
        return candidates.max { lhs, rhs in
            let left = max(0, lhs.rxRateMbs) + max(0, lhs.txRateMbs)
            let right = max(0, rhs.rxRateMbs) + max(0, rhs.txRateMbs)
            return left == right ? lhs.name > rhs.name : left < right
        }?.name ?? ""
    }
}

/// Values returned by the read-only AppleSMC protocol; unsupported formats stay nil.
public enum SMCReadValue {
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ":
            guard let first = bytes.first else { return nil }; value = Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }; value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default: return nil
        }
        return value.isFinite ? value : nil
    }
}

public enum ApplicationUsageAttribution {
    /// Called only for a WebKit service. Ambiguous or unknown names stay separate.
    public static func webContentOwner(_ displayName: String, applications: [(id: String, name: String)]) -> String? {
        let suffixes: Set<String> = ["Web Content", "網頁內容", "网页内容", "Networking", "網路", "网络", "GPU"]
        let matches = applications.filter { candidate in
            guard !candidate.name.isEmpty, displayName.hasPrefix(candidate.name) else { return false }
            return suffixes.contains(String(displayName.dropFirst(candidate.name.count)).trimmingCharacters(in: .whitespaces))
        }
        return matches.count == 1 ? matches.first?.id : nil
    }
}
