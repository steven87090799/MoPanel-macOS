import XCTest
@testable import MoPanelCore

final class MachCPUTimeTests: XCTestCase {
    func testAppleSiliconMachTicksProduceOneFullyUsedCore() throws {
        XCTAssertEqual(try XCTUnwrap(MachCPUTime.percentage(deltaTicks: 24_000_000, elapsedSeconds: 1, numerator: 125, denominator: 3)), 100, accuracy: 0.000001)
    }
    func testIntelTimebaseAndMultipleCores() throws {
        XCTAssertEqual(try XCTUnwrap(MachCPUTime.percentage(deltaTicks: 4_000_000_000, elapsedSeconds: 2, numerator: 1, denominator: 1)), 200, accuracy: 0.000001)
    }
    func testUnknownOrInvalidTimebaseIsNotAZeroReading() {
        for elapsed in [0.0, -1, .nan, .infinity] { XCTAssertNil(MachCPUTime.percentage(deltaTicks: 10, elapsedSeconds: elapsed, numerator: 125, denominator: 3)) }
        XCTAssertNil(MachCPUTime.percentage(deltaTicks: 10, elapsedSeconds: 1, numerator: 1, denominator: 0))
    }
}
