import XCTest
@testable import MoPanelCore

final class ResourceTrendPlotTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func sample(_ seconds: Double, _ value: Double?, interval: Double = 2, restart: Bool = false) -> ResourceTrendObservation {
        .init(date: start.addingTimeInterval(seconds), value: value, interval: interval, startsNewSegment: restart)
    }
    func testLongUnmonitoredPeriodDoesNotBecomeADiagonal() {
        let readings = [sample(0, 15), sample(2, 35), sample(4, 67), sample(6, 50), sample(420, 17), sample(422, 39), sample(424, 31)]
        let plot = ResourceTrendPlot.make(readings)
        XCTAssertEqual(plot.points.map(\.value), [15, 35, 67, 50, 17, 39, 31])
        XCTAssertEqual(plot.points.map(\.segment), [0, 0, 0, 0, 1, 1, 1])
        XCTAssertEqual(plot.gaps.count, 1)
        XCTAssertEqual(plot.gaps[0].duration, 414)
        XCTAssertEqual(plot.dateDomain, start...start.addingTimeInterval(424))
    }
    func testMissingAndInvalidValuesBreakOnlyThatMetricsLine() {
        let plot = ResourceTrendPlot.make([sample(0, 0), sample(2, nil), sample(4, .nan), sample(6, .infinity), sample(8, -1), sample(10, 25)])
        XCTAssertEqual(plot.points.map(\.value), [0, 25])
        XCTAssertEqual(plot.points.map(\.segment), [0, 1])
        XCTAssertTrue(plot.points.allSatisfy(\.isolated))
        XCTAssertEqual(plot.gaps.count, 1)
    }
    func testExpectedSlowCadenceAndCadenceChangesRemainContinuous() {
        let plot = ResourceTrendPlot.make([sample(0, 10), sample(30, 20, interval: 30), sample(60, 25, interval: 30), sample(62, 15)])
        XCTAssertEqual(Set(plot.points.map(\.segment)).count, 1)
        XCTAssertTrue(plot.gaps.isEmpty)
    }
    func testExplicitWatchRestartBreaksEvenAShortPause() {
        let plot = ResourceTrendPlot.make([sample(0, 10), sample(2, 20), sample(4, 30, restart: true), sample(6, 25)])
        XCTAssertEqual(plot.points.map(\.segment), [0, 0, 1, 1])
    }
    func testClockReversalAndDuplicateTimesDoNotJoinAcrossTheReset() {
        let plot = ResourceTrendPlot.make([sample(10, 10), sample(8, 20), sample(8, 30), sample(10, 25)])
        XCTAssertEqual(plot.points.map(\.segment), [0, 1, 2, 2])
        XCTAssertTrue(plot.gaps.isEmpty)
    }
    func testMissingTailAndPrefixRetainTheActualTimeDomain() {
        let plot = ResourceTrendPlot.make([sample(0, nil), sample(2, 25), sample(4, 30), sample(6, nil)])
        XCTAssertEqual(plot.points.map(\.value), [25, 30])
        XCTAssertEqual(plot.gaps.count, 2)
        XCTAssertEqual(plot.dateDomain, start...start.addingTimeInterval(6))
    }
    func testSinglePointIsVisibleAsAnIsolatedReadingAndEmptyStaysEmpty() {
        let plot = ResourceTrendPlot.make([sample(0, 42)])
        XCTAssertTrue(plot.points[0].isolated)
        XCTAssertNotNil(plot.dateDomain)
        XCTAssertTrue(ResourceTrendPlot.make([]).points.isEmpty)
        XCTAssertNil(ResourceTrendPlot.make([]).dateDomain)
        XCTAssertTrue(ResourceTrendPlot.make([sample(0, nil)]).points.isEmpty)
    }
    func testInvalidCadenceCannotHideGapsOrCreateInvalidDates() {
        let plot = ResourceTrendPlot.make([sample(0, 1, interval: .nan), sample(10, 2, interval: .infinity), .init(date: Date(timeIntervalSince1970: .nan), value: 3)])
        XCTAssertEqual(plot.points.map(\.segment), [0, 1])
        XCTAssertTrue(plot.points.allSatisfy { $0.date.timeIntervalSince1970.isFinite })
    }
}
