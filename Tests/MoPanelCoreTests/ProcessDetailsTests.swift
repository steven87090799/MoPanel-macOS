#if canImport(Darwin)
import Darwin
import XCTest
@testable import MoPanelCore

final class ProcessDetailsTests: XCTestCase {
    func testOwnProcessMetadataIsRealAndCollectedOnDemand() throws {
        let details = try XCTUnwrap(ProcessDetailsReader.read(pid: getpid()))
        XCTAssertEqual(details.pid, getpid())
        XCTAssertGreaterThan(details.threads, 0)
        XCTAssertTrue(details.executable.hasPrefix("/"))
        XCTAssertLessThan(details.startedAt, details.collectedAt)
        XCTAssertLessThan(abs(details.collectedAt.timeIntervalSinceNow), 5)
    }
    func testInvalidPIDOrChangedAppIdentityHasNoDetails() {
        XCTAssertNil(ProcessDetailsReader.read(pid: -1))
        XCTAssertNil(ProcessDetailsReader.read(pid: 0))
        XCTAssertNil(ProcessDetailsReader.read(pid: getpid(), expectedAppPath: "/Applications/Not-This-Process.app"))
    }
}
#endif
