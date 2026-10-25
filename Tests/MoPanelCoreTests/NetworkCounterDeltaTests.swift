import XCTest
@testable import MoPanelCore

final class NetworkCounterDeltaTests: XCTestCase {
    func testUsesObservedTimeAndDecimalRateUnits() throws {
        let value = try XCTUnwrap(NetworkCounterDelta.rates(previousRX: 100, previousTX: 200, currentRX: 5_000_100, currentTX: 1_000_200, elapsed: 5))
        XCTAssertEqual(value.down, 1)
        XCTAssertEqual(value.up, 0.2, accuracy: 0.000001)
    }
    func testResetOrInvalidTimeNeverCreatesHugeTrafficSpikes() {
        for elapsed in [0.0, -1, .infinity, .nan] {
            XCTAssertNil(NetworkCounterDelta.rates(previousRX: 1, previousTX: 1, currentRX: 100, currentTX: 100, elapsed: elapsed))
        }
        XCTAssertNil(NetworkCounterDelta.rates(previousRX: 100, previousTX: 100, currentRX: 1, currentTX: 101, elapsed: 5))
    }
    func testQuietInterfaceCanReallyReportZeroWithoutOverflow() throws {
        let value = try XCTUnwrap(NetworkCounterDelta.rates(previousRX: .max, previousTX: .max, currentRX: .max, currentTX: .max, elapsed: 5))
        XCTAssertEqual(value.down, 0)
        XCTAssertEqual(value.up, 0)
    }
}
