import XCTest
@testable import MoPanelCore

final class ReviewFileIdentityTests: XCTestCase {
    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }
    func testReplacementAtTheSamePathInvalidatesApproval() throws {
        let home = try fixture(), file = home.appendingPathComponent("Library/Caches/item")
        try Data("first".utf8).write(to: file)
        let identity = try ReviewFileIdentity.capture(file, home: home.path)
        XCTAssertTrue(identity.stillMatches(file, home: home.path))
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("old"))
        try Data("second".utf8).write(to: file)
        XCTAssertFalse(identity.stillMatches(file, home: home.path))
    }
    func testSymlinkAndPersonalDataNeverBecomeApprovedTargets() throws {
        let home = try fixture(), file = home.appendingPathComponent("Library/Caches/item")
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try ReviewFileIdentity.capture(file, home: home.path))
        XCTAssertFalse(ReviewPathPolicy.permits(home.path + "/Library/Keychains/login.keychain-db", home: home.path))
        XCTAssertFalse(ReviewPathPolicy.permits(home.path + "/Library/Messages/chat.db", home: home.path))
    }
    func testDirectoryApprovalStillRequiresItsOriginalIdentity() throws {
        let home = try fixture(), folder = home.appendingPathComponent("Library/Caches/app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let identity = try ReviewFileIdentity.capture(folder, home: home.path)
        try Data("cache".utf8).write(to: folder.appendingPathComponent("new"))
        XCTAssertTrue(identity.stillMatches(folder, home: home.path))
        try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(identity.stillMatches(folder, home: home.path))
    }
}
