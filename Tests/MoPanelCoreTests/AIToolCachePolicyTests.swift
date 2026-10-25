import XCTest
@testable import MoPanelCore

final class AIToolCachePolicyTests: XCTestCase {
    private let home = "/Users/test"
    func testOnlyKnownRebuildableLeavesAreAccepted() {
        for location in AIToolCachePolicy.locations {
            let path = home + "/" + location.relativePath
            XCTAssertEqual(AIToolCachePolicy.location(for: path, home: home), location)
            XCTAssertTrue(ReviewPathPolicy.permits(path, home: home))
            XCTAssertEqual(CleanupItemKind.classify(path, home: home), .aiCache)
        }
    }
    func testSessionsCredentialsModelsAndLookalikePathsStayOutsideScope() {
        for suffix in [".codex", ".codex/sessions", ".codex/auth.json", ".claude/projects", ".claude/skills", ".ollama/models", "Library/Application Support/Claude", "Library/Application Support/Claude/IndexedDB", "Library/Application Support/Claude/CacheBackup", "Library/Caches/Codex/Default/Local Storage", ".local/share/opencode/opencode.db", ".cache/opencode-secrets"] {
            XCTAssertNil(AIToolCachePolicy.location(for: home + "/" + suffix, home: home), suffix)
        }
        XCTAssertNil(AIToolCachePolicy.location(for: home + "/Library/Application Support/Claude/Cache/../IndexedDB", home: home))
    }
    func testRunningOwnerBlocksItsCacheButNotOtherTools() {
        let codex = home + "/Library/Caches/Codex/Default/Cache"
        XCTAssertTrue(AIToolCachePolicy.ownerIsActive(path: codex, home: home, executables: ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"]))
        XCTAssertTrue(AIToolCachePolicy.ownerIsActive(path: codex, home: home, executables: ["/opt/homebrew/bin/codex"]))
        XCTAssertFalse(AIToolCachePolicy.ownerIsActive(path: codex, home: home, executables: ["/Applications/Cursor.app/Contents/MacOS/Cursor"]))
        XCTAssertTrue(AIToolCachePolicy.ownerIsActive(path: home + "/Library/Application Support/Claude/Cache", home: home, executables: ["/Applications/Claude.app/Contents/MacOS/Claude"]))
    }
}
