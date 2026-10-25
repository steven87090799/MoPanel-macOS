import XCTest
@testable import MoPanelCore

final class ReviewAccessTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mopanel-access-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("denied").path)
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
    func testOrdinaryFileAndDirectoryCanBeReviewedWithoutMutation() throws {
        let root = try fixture(), file = root.appendingPathComponent("cache")
        try Data("unchanged".utf8).write(to: file)
        XCTAssertNil(ReviewAccessIssue.inspect(file))
        XCTAssertNil(ReviewAccessIssue.inspect(root))
        XCTAssertEqual(try Data(contentsOf: file), Data("unchanged".utf8))
    }
    func testUnreadableDirectoryIsBlockedInsteadOfBecomingAZeroByteRecommendation() throws {
        let folder = try fixture().appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0])
        XCTAssertEqual(ReviewAccessIssue.inspect(folder), .unreadable)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0)
    }
    func testMissingFileIsNotReportedAsAnAccessGrant() throws {
        XCTAssertEqual(ReviewAccessIssue.inspect(try fixture().appendingPathComponent("missing")), .unavailable)
    }
    func testPermissionErrorIncludesUnderlyingPOSIXErrorOnly() {
        XCTAssertTrue(ReviewAccessIssue.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertTrue(ReviewAccessIssue.isPermissionError(NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        XCTAssertFalse(ReviewAccessIssue.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }
    func testMixedSelectionIgnoresBlockedAndForeignIDs() {
        let eligible: Set<String> = ["a", "b"]
        XCTAssertEqual(ReviewSelectionState.resolve(eligible: eligible, selected: ["blocked"]), .none)
        XCTAssertEqual(ReviewSelectionState.resolve(eligible: eligible, selected: ["a", "blocked"]), .mixed)
        XCTAssertEqual(ReviewSelectionState.resolve(eligible: eligible, selected: ["a", "b", "blocked"]), .all)
        XCTAssertEqual(ReviewSelectionState.resolve(eligible: [], selected: ["a"]), .none)
    }
    func testPartialAndCancelledRunsCannotBePresentedAsCompleteSuccess() {
        let partial = ReviewRunOutcome(requested: 74, moved: 73, failed: 1, cancelled: false)
        XCTAssertTrue(partial.hasUnresolvedItems)
        XCTAssertEqual(partial.unprocessed, 0)
        let stopped = ReviewRunOutcome(requested: 10, moved: 2, failed: 1, cancelled: true)
        XCTAssertEqual(stopped.unprocessed, 7)
        XCTAssertTrue(stopped.hasUnresolvedItems)
        XCTAssertFalse(ReviewRunOutcome(requested: 2, moved: 2, failed: 0, cancelled: false).hasUnresolvedItems)
    }
}
