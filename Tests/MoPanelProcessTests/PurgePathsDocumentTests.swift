// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
@testable import MoPanelProcess

final class PurgePathsDocumentTests: XCTestCase {
    private func withFixture(_ action: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mopanel-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("purge_paths")
        try Data("# fixture\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try action(root, file)
    }
    func testAtomicSavePreservesMode() throws {
        try withFixture { root, file in
            let document = try PurgePathsDocument(url: file, expectedURL: file, home: root)
            try document.save(root.path + "\n")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), root.path + "\n")
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        }
    }
    func testConcurrentChangeIsNotOverwritten() throws {
        try withFixture { root, file in
            let document = try PurgePathsDocument(url: file, expectedURL: file, home: root)
            try Data("# changed elsewhere\n".utf8).write(to: file)
            XCTAssertThrowsError(try document.save(""))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# changed elsewhere\n")
        }
    }
    func testSymlinkRejected() throws {
        try withFixture { root, file in
            let link = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertThrowsError(try PurgePathsDocument(url: link, expectedURL: link, home: root))
        }
    }
    func testReplacedFileRejected() throws {
        try withFixture { root, file in
            let document = try PurgePathsDocument(url: file, expectedURL: file, home: root)
            try Data("# fixture\n".utf8).write(to: file, options: .atomic)
            XCTAssertThrowsError(try document.save(""))
        }
    }
    func testWrongFileRejected() throws {
        try withFixture { root, file in
            XCTAssertThrowsError(try PurgePathsDocument(url: file, expectedURL: root.appendingPathComponent("different"), home: root))
        }
    }
    func testPathsAndCommentsValidatedWithoutShellEvaluation() throws {
        try withFixture { root, _ in
            try PurgePathsDocument.validate("# notes\n~/\n\(root.path)\n", home: root)
            XCTAssertThrowsError(try PurgePathsDocument.validate("$(touch should-not-exist)\n", home: root))
            XCTAssertThrowsError(try PurgePathsDocument.validate("relative/directory\n", home: root))
            XCTAssertThrowsError(try PurgePathsDocument.validate("/unavailable-mopanel-fixture\n", home: root))
            XCTAssertThrowsError(try PurgePathsDocument.validate("bad\0path", home: root))
            XCTAssertThrowsError(try PurgePathsDocument.validate(String(repeating: "x", count: 262145), home: root))
        }
    }
}
