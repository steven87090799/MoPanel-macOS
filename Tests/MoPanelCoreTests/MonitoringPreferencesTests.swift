import Foundation
import XCTest
@testable import MoPanelCore

final class MonitoringPreferencesTests: XCTestCase {
    func testSettingsRoundTripAndMissingDefaults() throws {
        let name = "MoPanel.MonitoringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MonitoringPreferences(defaults: defaults), MonitoringPreferences())
        let changed = MonitoringPreferences(interval: 1, menuBarInterval: 30, processAlerts: false,
                                            processCPUThreshold: 0, processCPUWindow: 60)
        changed.save(to: defaults)
        XCTAssertEqual(MonitoringPreferences(defaults: defaults), changed)
    }

    func testInvalidSavedValuesCannotBecomeCollectorArguments() {
        for threshold in [Double.nan, .infinity, -1, 3201] {
            let value = MonitoringPreferences(interval: 0, menuBarInterval: -2, processCPUThreshold: threshold, processCPUWindow: 1)
            XCTAssertEqual(value, MonitoringPreferences())
        }
    }

    func testMenuBarAndLowPowerNeverIncreaseRequestedFrequency() {
        let settings = MonitoringPreferences(interval: 1, menuBarInterval: 10)
        XCTAssertEqual(settings.watchOptions(dashboardVisible: true, lowPowerMode: false).interval, 1)
        XCTAssertEqual(settings.watchOptions(dashboardVisible: false, lowPowerMode: false).interval, 10)
        XCTAssertEqual(settings.watchOptions(dashboardVisible: true, lowPowerMode: true).interval, 5)
        XCTAssertEqual(settings.watchOptions(dashboardVisible: false, lowPowerMode: true).interval, 10)
        XCTAssertEqual(MonitoringPreferences(interval: 10, menuBarInterval: 2).watchOptions(dashboardVisible: false, lowPowerMode: false).interval, 10)
    }

    func testSleepSuspendsEveryConsumerAndWakePreservesPause() {
        for dashboard in [true, false] { for menu in [true, false] {
            XCTAssertFalse(MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: true, menuBarEnabled: menu,
                                                     paused: false, shuttingDown: false, systemSleeping: true))
            XCTAssertFalse(MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: true, menuBarEnabled: menu,
                                                     paused: true, shuttingDown: false, systemSleeping: false))
            XCTAssertEqual(MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: true, menuBarEnabled: menu,
                                                    paused: false, shuttingDown: false, systemSleeping: false), dashboard || menu)
        } }
    }

    @MainActor func testTimestampOffsetsProduceTheSameReadableInstant() {
        for language in ["zh-Hant", "en"] {
            let offset = StatusTimestampDisplay.string(from: "2026-10-24T18:23:53.772457+08:00", language: language)
            let utc = StatusTimestampDisplay.string(from: "2026-10-24T10:23:53.772457Z", language: language)
            XCTAssertEqual(offset, utc)
            XCTAssertTrue(offset.contains("2026"))
            XCTAssertFalse(offset.contains(".772457"))
            XCTAssertFalse(offset.contains("+08:00"))
        }
    }

    @MainActor func testTimestampWholeSecondsFallbackAndInvalidInput() {
        XCTAssertNotEqual(StatusTimestampDisplay.string(from: "2026-10-24T10:23:53Z", language: "en"), "—")
        XCTAssertEqual(StatusTimestampDisplay.string(from: "2026-10-24T18:23:53.nonstandard", language: "zh-Hant"), "2026/10/24 18:23:53")
        for invalid in ["", "not-a-date", "2026-99-24T25:99:99.invalid"] {
            XCTAssertEqual(StatusTimestampDisplay.string(from: invalid, language: "zh-Hant"), "—")
        }
    }
}
