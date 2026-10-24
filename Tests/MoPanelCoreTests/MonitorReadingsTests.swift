import XCTest
@testable import MoPanelCore

final class MonitorReadingsTests: XCTestCase {
    func testWebContentOnlyGroupsWhenSystemNameIdentifiesOneApp() {
        let apps = [(id: "1", name: "Safari"), (id: "2", name: "Other")]
        XCTAssertEqual(ApplicationUsageAttribution.webContentOwner("Safari網頁內容", applications: apps), "1")
        XCTAssertEqual(ApplicationUsageAttribution.webContentOwner("Safari Web Content", applications: apps), "1")
        XCTAssertNil(ApplicationUsageAttribution.webContentOwner("Unrelated Web Content", applications: apps))
        XCTAssertNil(ApplicationUsageAttribution.webContentOwner("Safari Web Content", applications: apps + [(id: "3", name: "Safari")]))
    }
    func testPressureFlagsAndUnknownDoNotInventNormal() {
        XCTAssertEqual(MemoryPressureLevel(systemValue: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(systemValue: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(systemValue: 4), .critical)
        for value: Int32 in [0, 3, -1, 8] { XCTAssertNil(MemoryPressureLevel(systemValue: value)) }
    }
    func testReportedPressureOnlyRecognizesActualStates() {
        XCTAssertEqual(MemoryPressureLevel(reported: " WARN "), .warning)
        XCTAssertEqual(MemoryPressureLevel(reported: "critical"), .critical)
        for value in [nil, "", "unknown", "79%"] as [String?] { XCTAssertNil(MemoryPressureLevel(reported: value)) }
    }
    func testAutomaticNetworkPrefersPrimaryInsteadOfStaleIdlePort() {
        let ports = [NetworkStatus(name: "en5", rxRateMbs: 0, txRateMbs: 0, ip: ""), NetworkStatus(name: "en0", rxRateMbs: 0.01, txRateMbs: 0.1, ip: "192.0.2.1")]
        XCTAssertEqual(MonitorNetworkSelection.resolve(ports, manual: nil, primary: "en0"), "en0")
        XCTAssertEqual(MonitorNetworkSelection.resolve(ports, manual: nil, primary: nil), "en0")
        XCTAssertEqual(MonitorNetworkSelection.resolve(ports, manual: "en5", primary: "en0"), "en5")
        XCTAssertEqual(MonitorNetworkSelection.resolve(ports, manual: "missing", primary: "en0"), "en0")
    }
    func testNetworkDoesNotAddTunnelAndCarrierRates() {
        let ports = [NetworkStatus(name: "utun3", rxRateMbs: 2, txRateMbs: 1, ip: "198.51.100.1"), NetworkStatus(name: "en0", rxRateMbs: 4, txRateMbs: 2, ip: "192.0.2.1")]
        XCTAssertEqual(MonitorNetworkSelection.resolve(ports, manual: nil, primary: "utun3"), "utun3")
        XCTAssertEqual(MonitorNetworkSelection.resolve([], manual: nil, primary: nil), "")
    }
    func testSMCFormatsAndStoppedFanAreReadWithoutFabrication() {
        XCTAssertEqual(SMCReadValue.decode(type: "flt ", bytes: [0, 0, 112, 66]), 60)
        XCTAssertEqual(SMCReadValue.decode(type: "sp78", bytes: [60, 128]), 60.5)
        XCTAssertEqual(SMCReadValue.decode(type: "sp78", bytes: [255, 0]), -1)
        XCTAssertEqual(SMCReadValue.decode(type: "fpe2", bytes: [36, 96]), 2328)
        XCTAssertEqual(SMCReadValue.decode(type: "flt ", bytes: [0, 0, 0, 0]), 0)
        XCTAssertNil(SMCReadValue.decode(type: "flt ", bytes: [0, 0, 128, 127]))
        XCTAssertNil(SMCReadValue.decode(type: "flt ", bytes: [0, 0]))
        XCTAssertNil(SMCReadValue.decode(type: "unknown", bytes: [0, 0]))
    }
}
