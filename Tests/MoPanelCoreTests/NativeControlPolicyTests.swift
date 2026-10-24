import Foundation
import XCTest
@testable import MoPanelCore

final class NativeControlPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func identity(pid: Int32 = 234, id: String = "org.example.Test", path: String = "/Applications/Test.app",
                          start: Date? = nil, regular: Bool = true) -> RunningApplicationIdentity {
        RunningApplicationIdentity(pid: pid, bundleIdentifier: id, appPath: path,
                                   executablePath: path + "/Contents/MacOS/Test",
                                   launchedAt: start ?? now.addingTimeInterval(-60), isRegularApplication: regular)
    }
    private func validate(_ target: RunningApplicationIdentity, current: RunningApplicationIdentity? = nil,
                          sample: Date? = nil, command: String? = nil, test: Bool = false) throws {
        try QuitAppPolicy.validate(expected: target, current: current ?? target, selfPID: 345,
                                   sampleCommand: command ?? target.executablePath,
                                   sampledAt: sample ?? now.addingTimeInterval(-2), now: now, testMode: test)
    }
    func testSingleCollectorDemandAllCombinations() {
        for dashboard in [false, true] { for active in [false, true] { for menu in [false, true] {
            let demand = (dashboard && active) || menu
            XCTAssertEqual(MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: active, menuBarEnabled: menu, paused: false, shuttingDown: false), demand)
            XCTAssertFalse(MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: active, menuBarEnabled: menu, paused: true, shuttingDown: false))
            XCTAssertFalse(MonitoringDemand.isNeeded(dashboardSelected: dashboard, windowActive: active, menuBarEnabled: menu, paused: false, shuttingDown: true))
        } } }
    }
    func testCurrentRegularAppCanReceiveQuitRequest() throws { try validate(identity()) }
    func testReusedPIDOrDifferentPathCannotReceiveOldConfirmation() {
        let original = identity()
        XCTAssertThrowsError(try validate(original, current: identity(start: now.addingTimeInterval(-1))))
        XCTAssertThrowsError(try validate(original, current: identity(path: "/Applications/Other.app")))
        XCTAssertThrowsError(try validate(original, current: identity(pid: 235)))
    }
    func testSelfAppleHelpersAndOtherCleanerAreProtected() {
        for target in [identity(pid: 1), identity(pid: 345), identity(id: "com.apple.Finder"),
                       identity(id: "org.mopanel.app"), identity(id: "com.drbuho.BuhoCleaner"),
                       identity(path: "/System/Applications/Test.app"), identity(regular: false)] {
            XCTAssertThrowsError(try validate(target))
        }
    }
    func testStaleOrFutureSampleAndProcessNewerThanSampleAreRejected() {
        XCTAssertThrowsError(try validate(identity(), sample: now.addingTimeInterval(-16)))
        XCTAssertThrowsError(try validate(identity(), sample: now.addingTimeInterval(1)))
        XCTAssertThrowsError(try validate(identity(start: now.addingTimeInterval(-1))))
    }
    func testAmbiguousCommandAndTestingNeverPermitQuit() {
        XCTAssertThrowsError(try validate(identity(), command: "Test --option"))
        XCTAssertThrowsError(try validate(identity(), command: "/Applications/Test.app/Contents/MacOS/Test --secret"))
        XCTAssertThrowsError(try validate(identity(), test: true))
    }
    func testSpecialNamesRemainLiteralAndMustMatchExactly() throws {
        let target = identity(path: "/Applications/測試 $(touch nope); ' App.app")
        try validate(target)
        XCTAssertThrowsError(try validate(target, command: "Test"))
    }
}
