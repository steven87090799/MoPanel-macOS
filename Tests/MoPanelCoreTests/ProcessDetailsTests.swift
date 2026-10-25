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
    func testLaunchLabelRequiresUniqueExactPIDAndSafeJobName() {
        let listing = "PID\tStatus\tLabel\n1221\t0\tapplication.com.apple.Safari.example\n1222\t0\torg.example.other\n"
        XCTAssertEqual(ProcessLaunchEvidence.serviceLabel(in: listing, pid: 1221), "application.com.apple.Safari.example")
        XCTAssertNil(ProcessLaunchEvidence.serviceLabel(in: listing, pid: 12))
        XCTAssertNil(ProcessLaunchEvidence.serviceLabel(in: listing + "1221 0 duplicate.job\n", pid: 1221))
        XCTAssertNil(ProcessLaunchEvidence.serviceLabel(in: "1221 0 bad/job", pid: 1221))
    }
}
#endif
