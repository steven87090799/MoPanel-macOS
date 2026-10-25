import XCTest
@testable import MoPanelCore

final class OperationProgressSummaryTests: XCTestCase {
    func testSplitANSIAndUTF8ProduceOneReadableEvent() {
        var summary = OperationProgressSummary()
        let bytes = Data("\u{1b}[32m✓ 快取 12 MB\u{1b}[0m\n".utf8)
        for byte in bytes { summary.append(Data([byte])) }
        XCTAssertEqual(summary.entries.count, 1)
        XCTAssertEqual(summary.entries.first?.text, "✓ 快取 12 MB")
        XCTAssertEqual(summary.entries.first?.state, .completed)
    }
    func testProgressPreservesFailureAndSkipRatherThanClaimingSuccess() {
        var summary = OperationProgressSummary()
        summary.append(Data("Skipped protected data\nerror: permission denied\nscanning cache\n0 failed\n".utf8))
        XCTAssertEqual(summary.entries.map(\.state), [.skipped, .failed, .working])
    }
    func testSummaryHasFixedBoundsAndDoesNotStoreUnrecognizedOutput() {
        var summary = OperationProgressSummary()
        summary.append(Data(String(repeating: "x", count: 200_000).utf8))
        XCTAssertLessThanOrEqual(summary.pendingText.utf8.count, 8192)
        summary.finish()
        XCTAssertTrue(summary.entries.isEmpty)
        for index in 0..<200 { summary.append(Data("✓ item \(index)\n".utf8)) }
        XCTAssertEqual(summary.entries.count, 100)
    }
}
