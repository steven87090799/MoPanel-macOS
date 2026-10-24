// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import MoPanelCore

final class GitWorktreeParserTests: XCTestCase {
    let oid = String(repeating: "a", count: 40)
    func testNULInventoryPreservesNewlinesUnicodeAndLiteralShellCharacters() throws {
        let weird = "/Users/test/研究 ' $(never-run)\nsecond line"
        let bytes = Data(("worktree /Users/test/main\0HEAD " + oid + "\0branch refs/heads/main\0\0" +
                          "worktree " + weird + "\0HEAD " + oid + "\0detached\0locked intentional\nreason\0\0").utf8)
        let rows = try GitWorktreeParser.list(bytes)
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows[0].isMain)
        XCTAssertEqual(rows[1].path, weird); XCTAssertTrue(rows[1].detached)
        XCTAssertEqual(rows[1].lockReason, "intentional\nreason")
    }
    func testMalformedOrFutureInventoryNeverBecomesAnActionableList() {
        let valid = "worktree /tmp/repo\0HEAD " + oid + "\0branch refs/heads/main\0\0"
        let bad = [String(valid.dropLast()), valid.replacingOccurrences(of: "HEAD ", with: "future "),
                   valid.replacingOccurrences(of: "branch refs/heads/main", with: "detached\0branch refs/heads/main"),
                   valid + valid, "worktree /tmp/bare\0bare yes\0\0", "\0", ""]
        for text in bad { XCTAssertThrowsError(try GitWorktreeParser.list(Data(text.utf8)), text.debugDescription) }
        XCTAssertThrowsError(try GitWorktreeParser.list(Data([0xff, 0])))
    }
    func testStatusSeparatesIgnoredUntrackedAndDirtyAndRejectsTruncation() throws {
        let data = Data("? new\nname\0! ignored directory/\01 M. N... 100644 100644 100644 a b tracked\0".utf8)
        let guards = try GitWorktreeParser.statusProtection(data)
        XCTAssertTrue(guards.contains(.ignored)); XCTAssertTrue(guards.contains(.untracked)); XCTAssertTrue(guards.contains(.dirty))
        XCTAssertEqual(try GitWorktreeParser.statusProtection(Data()), [])
        XCTAssertThrowsError(try GitWorktreeParser.statusProtection(Data("? truncated".utf8)))
        XCTAssertThrowsError(try GitWorktreeParser.statusProtection(Data("x new-format\0".utf8)))
        XCTAssertThrowsError(try GitWorktreeParser.statusProtection(Data("2 rename record\0".utf8)))
    }
    func testIndexHiddenFlagsAndSubmoduleModesAreExplicit() throws {
        XCTAssertFalse(try GitWorktreeParser.indexHasHiddenChanges(Data("H normal\0".utf8)))
        XCTAssertTrue(try GitWorktreeParser.indexHasHiddenChanges(Data("h assume\0S sparse\0".utf8)))
        XCTAssertThrowsError(try GitWorktreeParser.indexHasHiddenChanges(Data("X unknown\0".utf8)))
        let index = try GitWorktreeParser.trackedEntries(Data(("160000 " + oid + " 0\tmodules/name\0").utf8))
        XCTAssertEqual(index.first?.mode, "160000")
        XCTAssertThrowsError(try GitWorktreeParser.trackedEntries(Data(("100644 " + oid + " 2\tconflicted\0").utf8)))
        XCTAssertThrowsError(try GitWorktreeParser.trackedEntries(Data(("100644 " + oid + " 0\t../escape\0").utf8)))
    }
    func testRecoveryRefsRequireDedicatedUUIDNamespaceAndRealHashShape() {
        XCTAssertTrue(GitWorktreeParser.validRecoveryReference("refs/heads/mopanel-recovery/" + UUID().uuidString.lowercased()))
        for ref in ["refs/heads/main", "refs/heads/mopanel-recovery/../main", "refs/heads/mopanel-recovery/unknown", "--force"] {
            XCTAssertFalse(GitWorktreeParser.validRecoveryReference(ref))
        }
        XCTAssertTrue(GitWorktreeParser.validObject(oid)); XCTAssertTrue(GitWorktreeParser.validObject(String(repeating: "b", count: 64)))
        XCTAssertFalse(GitWorktreeParser.validObject("HEAD")); XCTAssertFalse(GitWorktreeParser.validObject(String(repeating: "g", count: 40)))
    }
    func testProtectivePrefixUsesOfficialFlagsAndNeverForce() {
        let prefix = GitWorktreeService.commandPrefix
        for flag in ["--no-lazy-fetch", "--no-optional-locks", "--no-replace-objects", "core.hooksPath=/dev/null", "core.fsmonitor=false", "protocol.allow=never"] {
            XCTAssertTrue(prefix.contains(flag), flag)
        }
        XCTAssertFalse(prefix.contains("--force"))
        XCTAssertEqual(GitWorktreeService.protectiveEnvironment["GIT_TERMINAL_PROMPT"], "0")
    }
    func testBoundsAndFutureStatusRecordsFailClosed() {
        XCTAssertThrowsError(try GitWorktreeParser.list(Data(repeating: 0, count: GitWorktreeParser.maximumOutput + 1)))
        let record = "worktree /tmp/r\0HEAD " + oid + "\0branch refs/heads/main\0\0"
        let oversized = (0...GitWorktreeParser.maximumWorktrees).map { record.replacingOccurrences(of: "/tmp/r", with: "/tmp/r\($0)") }.joined()
        XCTAssertThrowsError(try GitWorktreeParser.list(Data(oversized.utf8)))
        XCTAssertThrowsError(try GitWorktreeParser.statusProtection(Data("# unexpected header\0".utf8)))
    }
}
