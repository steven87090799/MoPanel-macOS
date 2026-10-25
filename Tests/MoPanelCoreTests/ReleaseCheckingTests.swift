import XCTest
@testable import MoPanelCore

final class ReleaseCheckingTests: XCTestCase {
    private func release(_ tag: String = "v1.62.0", url: String? = nil, prerelease: Bool = false, draft: Bool = false) throws -> ReleaseInfo {
        let json: [String: Any] = ["tag_name": tag, "html_url": url ?? "https://github.com/tw93/Mole/releases/tag/\(tag)", "prerelease": prerelease, "draft": draft]
        return try XCTUnwrap(OfficialReleaseClient.decode(JSONSerialization.data(withJSONObject: json), statusCode: 200).first)
    }

    func testEqualVersionCompletesAndEveryCheckUpdatesTime() throws {
        var state = ReleaseCheckState()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin(), "Repeated clicks must not start another request")
        XCTAssertNil(state.outcome(installed: "1.62.0"))
        let first = Date(timeIntervalSince1970: 1)
        state.complete(try release(), at: first)
        XCTAssertFalse(state.isChecking)
        XCTAssertEqual(state.outcome(installed: "1.62.0"), .upToDate)
        XCTAssertEqual(state.checkedAt, first)
        XCTAssertTrue(state.begin())
        state.complete(try release(), at: first.addingTimeInterval(5))
        XCTAssertEqual(state.checkedAt, first.addingTimeInterval(5))
    }

    func testAllVersionOutcomes() throws {
        var state = ReleaseCheckState()
        state.begin(); state.complete(try release())
        XCTAssertEqual(state.outcome(installed: "1.61.9"), .updateAvailable)
        XCTAssertEqual(state.outcome(installed: "v1.63.0"), .localNewer)
        XCTAssertEqual(state.outcome(installed: "1.62.0-nightly"), .differentChannel)
        XCTAssertEqual(state.outcome(installed: "unknown"), .differentChannel)
        XCTAssertEqual(state.outcome(installed: nil), .notInstalled)
    }

    func testFailedRetryDoesNotPresentCachedVersionAsFreshSuccess() throws {
        var state = ReleaseCheckState()
        state.begin(); state.complete(try release(), at: Date(timeIntervalSince1970: 1))
        state.begin(); state.fail(.offline)
        XCTAssertFalse(state.isChecking)
        XCTAssertEqual(state.failure, .offline)
        XCTAssertNotNil(state.release, "Keep previous version and its old successful timestamp")
        XCTAssertNil(state.outcome(installed: "1.62.0"))
        state.begin(); state.complete(try release())
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.outcome(installed: "1.62.0"), .upToDate)
    }

    func testWindowsDraftPrereleaseAndForeignLinksAreRejected() throws {
        let invalid = [try release("v1.63.0-windows"), try release(prerelease: true), try release(draft: true),
                       try release(url: "https://github.com/other/Mole/releases/tag/v1.62.0"),
                       try release(url: "https://github.com/tw93/Mole/releases/tag/v1.61.0"),
                       try release(url: "https://github.com/tw93/Mole/releases/tag/v1.62.0?redirect=elsewhere")]
        for item in invalid {
            XCTAssertFalse(item.isMacStable)
            var state = ReleaseCheckState(); state.begin(); state.complete(item)
            XCTAssertEqual(state.failure, .invalidResponse)
            XCTAssertFalse(state.isChecking)
            XCTAssertNil(state.checkedAt)
        }
    }

    func testHTTPFailuresAndMalformedOrOversizedResponses() throws {
        for status in [403, 429] {
            XCTAssertThrowsError(try OfficialReleaseClient.decode(Data(), statusCode: status)) { XCTAssertEqual($0 as? ReleaseCheckFailure, .rateLimited) }
        }
        XCTAssertThrowsError(try OfficialReleaseClient.decode(Data(), statusCode: 503)) { XCTAssertEqual($0 as? ReleaseCheckFailure, .server(503)) }
        XCTAssertThrowsError(try OfficialReleaseClient.decode(Data("not JSON".utf8), statusCode: 200))
        XCTAssertThrowsError(try OfficialReleaseClient.decode(Data(repeating: 32, count: 2 * 1024 * 1024), statusCode: 200))
        XCTAssertEqual(try OfficialReleaseClient.decode(Data(" \n []".utf8), statusCode: 200), [])
    }

    func testCancellationAndNetworkFailuresSetUsefulStates() {
        XCTAssertEqual(ReleaseCheckFailure(error: URLError(.timedOut)), .timedOut)
        XCTAssertEqual(ReleaseCheckFailure(error: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ReleaseCheckFailure(error: CancellationError()), .cancelled)
        var state = ReleaseCheckState(); state.begin(); state.fail(.cancelled)
        XCTAssertFalse(state.isChecking)
        XCTAssertTrue(state.begin(), "Cancellation must allow retry")
    }
}
