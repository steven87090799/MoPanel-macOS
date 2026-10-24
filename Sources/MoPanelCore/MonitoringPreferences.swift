// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Shared preferences for the one collector consumed by Dashboard and Menu Bar.
public struct MonitoringPreferences: Equatable, Sendable {
    public static let foregroundIntervals = [1, 2, 5, 10]
    public static let menuBarIntervals = [2, 5, 10, 30]
    public static let alertWindows = [60, 120, 300, 600]
    public let interval: Int
    public let menuBarInterval: Int
    public let processAlerts: Bool
    public let processCPUThreshold: Double
    public let processCPUWindow: Int

    public init(interval: Int = 2, menuBarInterval: Int = 5, processAlerts: Bool = true,
                processCPUThreshold: Double = 100, processCPUWindow: Int = 300) {
        self.interval = Self.foregroundIntervals.contains(interval) ? interval : 2
        self.menuBarInterval = Self.menuBarIntervals.contains(menuBarInterval) ? menuBarInterval : 5
        self.processAlerts = processAlerts
        self.processCPUThreshold = processCPUThreshold.isFinite && (0...3200).contains(processCPUThreshold) ? processCPUThreshold : 100
        self.processCPUWindow = Self.alertWindows.contains(processCPUWindow) ? processCPUWindow : 300
    }

    public init(defaults: UserDefaults) {
        self.init(interval: defaults.integer(forKey: "monitoringInterval"),
                  menuBarInterval: defaults.integer(forKey: "menuBarMonitoringInterval"),
                  processAlerts: defaults.object(forKey: "processAlertsEnabled") == nil ? true : defaults.bool(forKey: "processAlertsEnabled"),
                  processCPUThreshold: defaults.object(forKey: "processCPUThreshold") == nil ? 100 : defaults.double(forKey: "processCPUThreshold"),
                  processCPUWindow: defaults.integer(forKey: "processCPUWindow"))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(interval, forKey: "monitoringInterval")
        defaults.set(menuBarInterval, forKey: "menuBarMonitoringInterval")
        defaults.set(processAlerts, forKey: "processAlertsEnabled")
        defaults.set(processCPUThreshold, forKey: "processCPUThreshold")
        defaults.set(processCPUWindow, forKey: "processCPUWindow")
    }

    public func watchOptions(dashboardVisible: Bool, lowPowerMode: Bool) -> MonitoringWatchOptions {
        let requested = dashboardVisible ? interval : max(interval, menuBarInterval)
        return MonitoringWatchOptions(interval: max(requested, lowPowerMode ? 5 : 1),
                                      processAlerts: processAlerts, processCPUThreshold: processCPUThreshold,
                                      processCPUWindow: processCPUWindow)
    }
}

public struct MonitoringWatchOptions: Equatable, Sendable {
    public let interval: Int
    public let processAlerts: Bool
    public let processCPUThreshold: Double
    public let processCPUWindow: Int
}
