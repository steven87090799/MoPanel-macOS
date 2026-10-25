import XCTest
@testable import MoPanelCore

final class DashboardLayoutTests: XCTestCase {
    func testDefaultFirstRowAndTrendsSecond() {
        let layout = DashboardLayout()
        XCTAssertEqual(layout.items(in: .summary), ["cpu", "gpu", "memory"])
        XCTAssertEqual(Array(layout.items(in: .sections).prefix(2)), ["summary", "trends"])
        XCTAssertFalse(layout.items(in: .sections).contains("health"))
    }
    func testInvalidAndDuplicateSavedItemsAreRemovedAndNewItemsAppended() {
        let layout = DashboardLayout(orders: [.sections: ["network", "network", "unknown", "cpu"], .summary: ["memory", "health", "memory"]])
        XCTAssertEqual(Array(layout.items(in: .sections).prefix(2)), ["network", "cpu"])
        XCTAssertEqual(Set(layout.items(in: .sections)), Set(DashboardLayout.defaults[.sections]!))
        XCTAssertEqual(layout.items(in: .summary), ["memory", "cpu", "gpu"])
    }
    func testMovesAreScopedAndRespectBoundaries() {
        var layout = DashboardLayout()
        layout.move("cpu", by: -1, in: .summary)
        XCTAssertEqual(layout, DashboardLayout())
        layout.move("memory", before: "cpu", in: .summary)
        XCTAssertEqual(layout.items(in: .summary), ["memory", "cpu", "gpu"])
        layout.move("memory", by: 2, in: .summary)
        XCTAssertEqual(layout.items(in: .summary), ["cpu", "gpu", "memory"])
        layout.move("system", before: "summary", in: .sections)
        XCTAssertEqual(layout.items(in: .sections).first, "system")
        layout.move("gpu", before: "disk", in: .trends)
        layout.move("missing", by: Int.max, in: .summary)
        XCTAssertEqual(layout.items(in: .trends), DashboardLayout.defaults[.trends])
    }
    func testSaveLoadAndResetWithoutAffectingOtherSettings() throws {
        let domain = "MoPanel.dashboard-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("en", forKey: "language")
        var layout = DashboardLayout()
        layout.move("network", before: "cpu", in: .trends)
        layout.move("gpu", by: -1, in: .summary)
        layout.save(to: defaults)
        XCTAssertEqual(DashboardLayout(defaults: defaults), layout)
        DashboardLayout().save(to: defaults)
        XCTAssertEqual(DashboardLayout(defaults: defaults), DashboardLayout())
        XCTAssertEqual(defaults.string(forKey: "language"), "en")
    }
}
