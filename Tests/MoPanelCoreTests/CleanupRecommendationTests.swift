import XCTest
@testable import MoPanelCore

final class CleanupRecommendationTests: XCTestCase {
    func testOnlyKnownUpdaterAndGeneratedCachePathsAreRecommended() {
        let home = "/Users/test"
        for suffix in ["Google/GoogleUpdater/crx_cache/abc", "LogiOptionsPlus/Code Cache/js", "com.ugreen.desktop/Cache/Cache_Data", "UGREEN_Video_Player/GPUCache/index"] {
            let kind = CleanupItemKind.classify(home + "/Library/Application Support/" + suffix, home: home)
            XCTAssertTrue(kind.recommended, suffix)
            XCTAssertTrue(kind.needsIdleApplication, suffix)
        }
        for suffix in ["Google/GoogleUpdater/settings.json", "Google/Chrome/Default/Cookies", "LogiOptionsPlus/settings.json", "com.ugreen.desktop/Local Storage/state", "UnknownApp/Code Cache/js"] {
            XCTAssertEqual(CleanupItemKind.classify(home + "/Library/Application Support/" + suffix, home: home), .unknown, suffix)
        }
        XCTAssertEqual(CleanupItemKind.classify(home + "/Library/Application Support/Google/GoogleUpdater/updater.log.old", home: home), .logs)
    }
    func testRunningOwnersPreventTheirCacheFromBecomingAnIdleRecommendation() {
        XCTAssertTrue(CleanupItemKind.activeCacheOwner(path: "/Users/test/Library/Application Support/Google/GoogleUpdater/crx_cache/a", executablePaths: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]))
        XCTAssertTrue(CleanupItemKind.activeCacheOwner(path: "/Users/test/Library/Application Support/LogiOptionsPlus/GPUCache/index", executablePaths: ["/Library/LogiOptionsPlus/logioptionsplus_agent"]))
        XCTAssertTrue(CleanupItemKind.activeCacheOwner(path: "/Users/test/Library/Application Support/com.ugreen.desktop/Cache/Cache_Data", executablePaths: ["/Applications/UGREEN NAS.app/Contents/MacOS/client"]))
        XCTAssertFalse(CleanupItemKind.activeCacheOwner(path: "/Users/test/Library/Application Support/LogiOptionsPlus/GPUCache/index", executablePaths: ["/Applications/Finder.app/Contents/MacOS/Finder"]))
    }
    private func fixture() throws -> (URL, URL, URL) {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("mopanel-python-" + UUID().uuidString)
        let source = home.appendingPathComponent("Desktop/project/module.py")
        let cache = home.appendingPathComponent("Desktop/project/__pycache__")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("fixture only".utf8).write(to: source)
        try Data([0, 1, 2]).write(to: cache.appendingPathComponent("module.cpython-312.opt-1.pyc"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, cache, source)
    }
    func testVerifiedPythonCacheCanBeSelectedAndSourceRemainsUntouched() throws {
        let (home, cache, source) = try fixture()
        XCTAssertTrue(PythonCacheProof.isRebuildable(cache.path, home: home.path))
        XCTAssertTrue(ReviewPathPolicy.permits(cache.path, home: home.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("fixture only".utf8))
        XCTAssertFalse(ReviewPathPolicy.permits(source.path, home: home.path))
        XCTAssertFalse(ReviewPathPolicy.permits(cache.deletingLastPathComponent().path, home: home.path))
    }
    func testMissingSourceInvalidatesPythonCacheApproval() throws {
        let (home, cache, source) = try fixture()
        let identity = try ReviewFileIdentity.capture(cache, home: home.path)
        try FileManager.default.removeItem(at: source)
        XCTAssertFalse(PythonCacheProof.isRebuildable(cache.path, home: home.path))
        XCTAssertFalse(identity.stillMatches(cache, home: home.path))
    }
    func testExtraPersonalFileOrNestedDirectoryBlocksWholePythonCache() throws {
        let (home, cache, _) = try fixture()
        let note = cache.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: note)
        XCTAssertFalse(PythonCacheProof.isRebuildable(cache.path, home: home.path))
        try FileManager.default.removeItem(at: note)
        try FileManager.default.createDirectory(at: note, withIntermediateDirectories: false)
        XCTAssertFalse(PythonCacheProof.isRebuildable(cache.path, home: home.path))
    }
    func testSourceOrCacheSymlinksAreNeverAccepted() throws {
        let (home, cache, source) = try fixture()
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "/etc/hosts")
        XCTAssertFalse(PythonCacheProof.isRebuildable(cache.path, home: home.path))
        XCTAssertFalse(PythonCacheProof.isCandidate(home.path + "/.codex/project/__pycache__", home: home.path))
        XCTAssertFalse(PythonCacheProof.isCandidate(home.path + "/Desktop/App.app/project/__pycache__", home: home.path))
    }
}
