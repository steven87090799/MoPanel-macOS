// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum KeepAwakeMode: String, CaseIterable, Codable, Sendable {
    case displayAndSystem, system
}

public enum KeepAwakeDuration: Int, CaseIterable, Codable, Sendable {
    case untilStopped = 0, oneHour = 1, twoHours = 2, fourHours = 4, eightHours = 8, twelveHours = 12
    public var seconds: TimeInterval? { rawValue == 0 ? nil : Double(rawValue) * 3_600 }
}

public struct SystemPowerReading: Equatable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case external, battery, ups, unknown }
    public let source: Source
    public let batteryPercent: Double?
    public init(source: Source, batteryPercent: Double?) {
        self.source = source
        self.batteryPercent = batteryPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
    }
}

public enum KeepAwakeDecision: String, Codable, Sendable {
    case active, pausedLowBattery, pausedUnknownPower, expired, stopped
}

/// Pure policy; timestamps are monotonic seconds supplied by the controller.
/// The original deadline continues while paused. A low-battery pause is latched
/// until external power is observed, avoiding repeated on/off at the threshold.
public struct KeepAwakeSession: Equatable, Sendable {
    public let mode: KeepAwakeMode
    public let deadline: TimeInterval?
    public private(set) var lowBatteryPauseLatched = false
    public private(set) var stopped = false

    public init(mode: KeepAwakeMode, duration: KeepAwakeDuration, now: TimeInterval) {
        self.mode = mode
        self.deadline = duration.seconds.map { now + $0 }
    }

    public mutating func stop() { stopped = true }

    public func remaining(at now: TimeInterval) -> TimeInterval? {
        deadline.map { max(0, $0 - now) }
    }

    public mutating func evaluate(at now: TimeInterval, power: SystemPowerReading) -> KeepAwakeDecision {
        guard !stopped else { return .stopped }
        guard now.isFinite else { return .pausedUnknownPower }
        if let deadline, now >= deadline { stopped = true; return .expired }
        if power.source == .external { lowBatteryPauseLatched = false; return .active }
        if power.source == .unknown { return .pausedUnknownPower }
        guard let percent = power.batteryPercent else { return .pausedUnknownPower }
        if percent <= 20 { lowBatteryPauseLatched = true }
        if lowBatteryPauseLatched { return .pausedLowBattery }
        return .active
    }
}

public enum EjectEligibility {
    /// Metadata must positively identify a local, external, removable/ejectable
    /// non-root volume. Unknown values are never treated as permission to eject.
    public static func allows(isRoot: Bool?, isInternal: Bool?, isLocal: Bool?,
                              isEjectable: Bool?, isRemovable: Bool?,
                              mountPath: String, protectedPaths: [String]) -> Bool {
        guard isRoot == false, isInternal == false, isLocal == true,
              isEjectable == true || isRemovable == true,
              mountPath.hasPrefix("/"), !mountPath.contains("\0") else { return false }
        let mount = URL(fileURLWithPath: mountPath).standardizedFileURL.path
        guard mount != "/", mount == mountPath else { return false }
        return !protectedPaths.contains { raw in
            let protected = URL(fileURLWithPath: raw).standardizedFileURL.path
            return protected == mount || protected.hasPrefix(mount + "/")
        }
    }
}
