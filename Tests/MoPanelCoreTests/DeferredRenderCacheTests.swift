import XCTest
@testable import MoPanelCore

final class DeferredRenderCacheTests: XCTestCase {
    func testRepeatedLayoutAndUnrelatedUpdatesDoNotPrepareAnotherPlot() {
        let cache = DeferredRenderCache<Int, [Int]>()
        for _ in 0..<100 {
            XCTAssertEqual(cache.value(for: 1, canUpdate: true) { [10, 20] }, [10, 20])
        }
        XCTAssertEqual(cache.buildCount, 1)
    }
    func testScrollingDefersNewPlotsAndIdleBuildsOnlyLatestReading() {
        let cache = DeferredRenderCache<Int, Int>()
        XCTAssertEqual(cache.value(for: 0, canUpdate: true) { 0 }, 0)
        for reading in 1...120 {
            XCTAssertEqual(cache.value(for: reading, canUpdate: false) { XCTFail("Must not build while scrolling"); return reading }, 0)
        }
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(cache.value(for: 120, canUpdate: true) { 120 }, 120)
        XCTAssertEqual(cache.buildCount, 2)
    }
    func testFirstAppearanceStillHasARealPlotDuringAnInteraction() {
        let cache = DeferredRenderCache<Int, String>()
        XCTAssertEqual(cache.value(for: 4, canUpdate: false) { "actual reading" }, "actual reading")
        XCTAssertEqual(cache.value(for: 5, canUpdate: false) { "new reading" }, "actual reading")
        XCTAssertEqual(cache.value(for: 5, canUpdate: true) { "new reading" }, "new reading")
    }
    func testNetworkAndLanguageChangesInvalidateThePreparedValue() {
        let cache = DeferredRenderCache<String, String>()
        XCTAssertEqual(cache.value(for: "en0:zh:1", canUpdate: true) { "Wi-Fi" }, "Wi-Fi")
        XCTAssertEqual(cache.value(for: "en4:zh:1", canUpdate: true) { "Ethernet" }, "Ethernet")
        XCTAssertEqual(cache.value(for: "en4:en:1", canUpdate: true) { "Upload" }, "Upload")
        XCTAssertEqual(cache.buildCount, 3)
    }
    func testLazyDetailNavigationTargetsDirectSections() {
        for section in ["cpu", "memory", "disk", "network", "thermal", "system"] {
            XCTAssertEqual(DashboardLayout.section(forDetailTarget: section + "-details"), section)
        }
        XCTAssertEqual(DashboardLayout.section(forDetailTarget: "gpu-details"), "hardware")
        XCTAssertEqual(DashboardLayout.section(forDetailTarget: "unknown"), "summary")
    }
}
