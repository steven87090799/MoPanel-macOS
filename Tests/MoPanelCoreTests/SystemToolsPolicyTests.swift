// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MoPanelCore

final class SystemToolsPolicyTests: XCTestCase {
    func testFiniteSessionExpiresWithoutExtendingAfterPowerPause() {
        var session = KeepAwakeSession(mode: .displayAndSystem, duration: .oneHour, now: 100)
        XCTAssertEqual(session.evaluate(at: 101, power: .init(source: .external, batteryPercent: 80)), .active)
        XCTAssertEqual(session.evaluate(at: 200, power: .init(source: .battery, batteryPercent: 20)), .pausedLowBattery)
        XCTAssertEqual(session.remaining(at: 300), 3_400)
        XCTAssertEqual(session.evaluate(at: 3_700, power: .init(source: .external, batteryPercent: 21)), .expired)
        XCTAssertEqual(session.evaluate(at: 3_701, power: .init(source: .external, batteryPercent: 50)), .stopped)
    }

    func testLowBatteryLatchOnlyResumesOnExternalPower() {
        var session = KeepAwakeSession(mode: .system, duration: .untilStopped, now: 0)
        XCTAssertEqual(session.evaluate(at: 1, power: .init(source: .battery, batteryPercent: 19)), .pausedLowBattery)
        XCTAssertEqual(session.evaluate(at: 2, power: .init(source: .battery, batteryPercent: 21)), .pausedLowBattery)
        XCTAssertEqual(session.evaluate(at: 3, power: .init(source: .external, batteryPercent: 19)), .active)
        XCTAssertEqual(session.evaluate(at: 4, power: .init(source: .battery, batteryPercent: 50)), .active)
        XCTAssertNil(session.remaining(at: 4))
    }

    func testUnknownAndInvalidPowerNeverPretendBatteryIsSafe() {
        var session = KeepAwakeSession(mode: .system, duration: .twoHours, now: 0)
        for value in [Double.nan, Double.infinity, -1, 101] {
            XCTAssertEqual(session.evaluate(at: 1, power: .init(source: .battery, batteryPercent: value)), .pausedUnknownPower)
        }
        XCTAssertEqual(session.evaluate(at: 2, power: .init(source: .unknown, batteryPercent: 90)), .pausedUnknownPower)
        XCTAssertEqual(session.evaluate(at: .nan, power: .init(source: .external, batteryPercent: nil)), .pausedUnknownPower)
        XCTAssertEqual(session.evaluate(at: 3, power: .init(source: .external, batteryPercent: nil)), .active)
    }

    func testStopIsFinalEvenIfExternalPowerArrives() {
        var session = KeepAwakeSession(mode: .displayAndSystem, duration: .untilStopped, now: 0)
        session.stop()
        XCTAssertEqual(session.evaluate(at: 1, power: .init(source: .external, batteryPercent: nil)), .stopped)
    }

    func testUPSAlsoHonorsBatteryCutoff() {
        var session = KeepAwakeSession(mode: .system, duration: .fourHours, now: 0)
        XCTAssertEqual(session.evaluate(at: 1, power: .init(source: .ups, batteryPercent: 50)), .active)
        XCTAssertEqual(session.evaluate(at: 2, power: .init(source: .ups, batteryPercent: 20)), .pausedLowBattery)
    }

    func testEjectRequiresAffirmativeMetadata() {
        func allows(_ root: Bool?, _ internalBus: Bool?, _ local: Bool?, _ ejectable: Bool?, _ removable: Bool?) -> Bool {
            EjectEligibility.allows(isRoot: root, isInternal: internalBus, isLocal: local,
                                   isEjectable: ejectable, isRemovable: removable,
                                   mountPath: "/Volumes/測試 USB", protectedPaths: ["/Applications/MoPanel.app", "/Users/test"])
        }
        XCTAssertTrue(allows(false, false, true, true, false))
        XCTAssertTrue(allows(false, false, true, false, true))
        XCTAssertFalse(allows(nil, false, true, true, true))
        XCTAssertFalse(allows(false, nil, true, true, true))
        XCTAssertFalse(allows(false, false, nil, true, true))
        XCTAssertFalse(allows(false, false, true, nil, nil))
        XCTAssertFalse(allows(true, false, true, true, true))
        XCTAssertFalse(allows(false, true, true, true, true))
        XCTAssertFalse(allows(false, false, false, true, true))
    }

    func testEjectProtectsHomeAppAndPathBoundaries() {
        func allows(_ mount: String, _ protected: [String]) -> Bool {
            EjectEligibility.allows(isRoot: false, isInternal: false, isLocal: true,
                                   isEjectable: true, isRemovable: true, mountPath: mount, protectedPaths: protected)
        }
        XCTAssertFalse(allows("/", []))
        XCTAssertFalse(allows("/Volumes/USB/../USB", []))
        XCTAssertFalse(allows("relative", []))
        XCTAssertFalse(allows("/Volumes/USB\0suffix", []))
        XCTAssertFalse(allows("/Volumes/USB", ["/Volumes/USB/Users/test"]))
        XCTAssertFalse(allows("/Volumes/USB", ["/Volumes/USB/MoPanel.app"]))
        XCTAssertTrue(allows("/Volumes/USB", ["/Volumes/USB Backup/MoPanel.app"]))
        XCTAssertTrue(allows("/Volumes/單引號' $()", ["/Applications/MoPanel.app"]))
    }
}
