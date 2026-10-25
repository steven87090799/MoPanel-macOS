import XCTest
@testable import MoPanelCore

final class ReviewSizeEstimateTests: XCTestCase {
    func testMoleAndNativeReadableSizes() {
        XCTAssertEqual(ReviewSizeEstimate.parse("1.5GB")?.bytes, 1_610_612_736)
        XCTAssertEqual(ReviewSizeEstimate.parse("280 MB")?.bytes, 293_601_280)
        XCTAssertEqual(ReviewSizeEstimate.parse("12 KiB")?.bytes, 12_288)
        XCTAssertEqual(ReviewSizeEstimate.parse("0 byte")?.bytes, 0)
        XCTAssertEqual(ReviewSizeEstimate.parse("至少 24 MB")?.lowerBound, true)
    }
    func testUnknownMalformedAndOverflowAreNotZero() {
        for text in ["未讀取大小", "大小未知", "-3 MB", "1 MB extra", "NaN GB", "999999999999999999999 TB", "至少"] {
            XCTAssertNil(ReviewSizeEstimate.parse(text), text)
        }
    }
}
