import XCTest
@testable import MoPanelCore

final class CleanupPreviewTests: XCTestCase {
    func testOfficialPreviewPreservesPathsSizesAndNestedAccounting() throws {
        let text = "# Mole Cleanup Preview - fixture\n=== User essentials ===\n/Users/test/Library/Caches/My App  # 1.3MB, 3 items\n/Users/test/Library/Caches/My App/child  # 1KB, counted under parent\n/Users/test/Library/Caches/My App  # 1.3MB\n# Summary\n# Items: 3\n# Categories: 1\n"
        let items = try CleanupPreviewDocument.parse(text)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].path, "/Users/test/Library/Caches/My App")
        XCTAssertEqual(items[0].size, "1.3MB")
        XCTAssertTrue(items[1].includedInParent)
    }
    func testUnknownPreviewCannotBecomeAPlan() {
        XCTAssertThrowsError(try CleanupPreviewDocument.parse("/Users/test/file  # 1GB"))
        XCTAssertThrowsError(try CleanupPreviewDocument.parse("# Mole Cleanup Preview - fixture\n" + String(repeating: "x", count: 2_000_001)))
    }
    func testNativeSelectionNeverTargetsRootsSystemOrUserDocuments() {
        for path in ["/", "/System/file", "/Library/Caches/file", "/Applications", "/Users/test", "/Users/test/Documents/important", "/Users/test/Library/Caches", "/Users/test/Library/Containers", "/Users/test/Library/Application Scripts", "/Users/test/Library/Saved Application State", "/Users/test/Library/LaunchAgents/important.plist", "/Users/test/Library/Mail/inbox", "/Users/test/.cache", "/Applications/../Bad.app", "/Applications/Foo.app/child.app"] {
            XCTAssertFalse(ReviewPathPolicy.permits(path, home: "/Users/test"), path)
        }
    }
    func testNativeSelectionUsesNarrowUserAndAppScopes() {
        for path in ["/Users/test/Library/Caches/org.example.app", "/Users/test/Library/Preferences/org.example.app.plist", "/Applications/Example.app"] {
            XCTAssertTrue(ReviewPathPolicy.permits(path, home: "/Users/test"), path)
        }
    }
}
