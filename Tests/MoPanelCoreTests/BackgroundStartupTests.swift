import XCTest
@testable import MoPanelCore

final class BackgroundStartupTests: XCTestCase {
    // Sanitized shape of Apple's actual report: absolute paths, shared parent
    // registrations and embedded helpers; no invented 'visible' flag required.
    private let fixture = """
    Records for UID -2 : system
      #1:
        Name: Example
        Developer Name: Example Developer
        Type: app (0x2)
        Disposition: [disabled, allowed, notified] (0xa)
        Identifier: 2.org.example.app
        URL: /Applications/Example.app
        Bundle Identifier: org.example.app
        Embedded Item Identifiers:
          #1: 16.org.example.worker
      #2:
        Name: Shared Agent
        Type: legacy agent (0x10008)
        Disposition: [enabled, allowed, notified] (0xb)
        Identifier: 8.org.example.shared
        URL: /Library/LaunchAgents/org.example.shared.plist
      #3:
        Name: Worker
        Type: daemon (0x10)
        Disposition: [enabled, allowed] (0x3)
        Identifier: 16.org.example.worker
        URL: Contents/Library/LaunchDaemons/org.example.worker.plist
        Executable Path: Contents/Library/LaunchServices/worker
        Parent Identifier: 2.org.example.app
    Records for UID 501 : current user
      #1:
        Name: Example Menu
        Type: app (0x2)
        Disposition: [enabled, allowed, notified] (0xb)
        Identifier: 2.org.example.menu
        URL: file:///Applications/Example.app/Contents/Library/LoginItems/Menu.app/
      #2:
        Name: Example
        Developer Name: (null)
        Type: app (0x2)
        Disposition: [disabled, allowed, notified] (0xa)
        Identifier: 2.org.example.app
        URL: /Applications/Example.app
        Bundle Identifier: org.example.app
      #3:
        Name: Example Login Helper
        Type: login item (0x4)
        Disposition: [enabled, disallowed, notified] (0x9)
        Identifier: 4.org.example.app.login
        URL: Contents/Library/LoginItems/Helper.app
        Parent Identifier: 2.org.example.app
      #4:
        Name: Shared Agent
        Type: legacy agent (0x10008)
        Disposition: [enabled, allowed, notified] (0xb)
        Identifier: 8.org.example.shared
        URL: /Library/LaunchAgents/org.example.shared.plist
      #5:
        Name: Worker
        Type: agent (0x8)
        Disposition: [disabled, allowed] (0x2)
        Identifier: 8.org.example.worker
        URL: Contents/Library/LaunchAgents/org.example.worker.plist
        Executable Path: /Applications/Example.app/Contents/MacOS/worker
        Parent Identifier: 2.org.example.app
      #6:
        Name: Standalone Menu
        Type: login item (0x4)
        Disposition: [disabled, allowed] (0x2)
        Identifier: 4.org.standalone.menu
        URL: /Applications/Standalone.app
      #7:
        Name: Developer Group
        Type: developer (0x20)
        Identifier: Developer Group
    Records for UID 502 : another user
      #1:
        Name: Other User App
        Type: app (0x2)
        Identifier: 2.org.other.app
    Records for UID 0 : root
      #1:
        Name: Root App
        Type: app (0x2)
        Identifier: 2.org.root.app
    """
    func testCategoriesMatchRealDispositionFlagsAndDoNotDuplicateParentsOrHelpers() throws {
        let items = try BackgroundStartupParser.parse(fixture, userID: 501)
        XCTAssertEqual(items.filter { $0.kind == .login }.map(\.name), ["Example Menu", "Standalone Menu"])
        XCTAssertEqual(items.filter { $0.kind == .backgroundApp }.map(\.name), ["Example"])
        XCTAssertEqual(items.filter { $0.kind == .service }.count, 3)
        XCTAssertEqual(items.count, Set(items.map(\.id)).count)
        XCTAssertFalse(items.contains { $0.name == "Root App" || $0.name == "Other User App" })
        XCTAssertEqual(items.first { $0.kind == .backgroundApp }?.enabled, true, "Disabled login launch still allows background features")
        XCTAssertEqual(items.first { $0.name == "Standalone Menu" }?.enabled, false)
    }
    func testEmbeddedLoginHelpersRemainAvailableUnderParentDetails() throws {
        let item = try XCTUnwrap(BackgroundStartupParser.parse(fixture, userID: 501).first { $0.kind == .backgroundApp })
        XCTAssertEqual(item.loginHelpers.count, 1)
        XCTAssertEqual(item.loginHelpers[0].name, "Example Login Helper")
        XCTAssertEqual(item.loginHelpers[0].url?.path, "/Applications/Example.app/Contents/Library/LoginItems/Helper.app")
        XCTAssertEqual(item.loginHelpers[0].enabled, false)
        XCTAssertNil(item.developer, "Null developer text must not appear in the interface")
    }
    func testPathsAndParentApplicationMetadataAreResolved() throws {
        let items = try BackgroundStartupParser.parse(fixture, userID: 501)
        let daemon = try XCTUnwrap(items.first { $0.isDaemon })
        XCTAssertEqual(daemon.url?.path, "/Applications/Example.app/Contents/Library/LaunchDaemons/org.example.worker.plist")
        XCTAssertEqual(daemon.executable, "/Applications/Example.app/Contents/Library/LaunchServices/worker")
        XCTAssertEqual(daemon.associatedAppURL?.path, "/Applications/Example.app")
        XCTAssertEqual(daemon.bundleIdentifier, "org.example.app")
        XCTAssertEqual(daemon.developer, "Example Developer")
        XCTAssertEqual(items.first { $0.name == "Example Menu" }?.url?.path, "/Applications/Example.app/Contents/Library/LoginItems/Menu.app")
    }
    func testSharedAgentIsDeduplicatedButAgentAndDaemonStaySeparate() throws {
        let items = try BackgroundStartupParser.parse(fixture, userID: 501)
        let shared = items.filter { $0.launchLabel == "org.example.shared" }
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared[0].userID, 501)
        XCTAssertEqual(items.filter { $0.launchLabel == "org.example.worker" }.count, 2)
        XCTAssertFalse(items.first { $0.isDaemon }!.matchesPlist(url: URL(fileURLWithPath: "/Library/LaunchAgents/org.example.worker.plist"), label: "org.example.worker", scope: .sharedAgent))
    }
    func testHomeAndSharedAgentWithSameLabelDoNotMerge() throws {
        let item = try XCTUnwrap(BackgroundStartupParser.parse(fixture, userID: 501).first { $0.launchLabel == "org.example.shared" })
        XCTAssertTrue(item.matchesPlist(url: URL(fileURLWithPath: "/Library/LaunchAgents/org.example.shared.plist"), label: "org.example.shared", scope: .sharedAgent))
        XCTAssertFalse(item.matchesPlist(url: URL(fileURLWithPath: "/Users/example/Library/LaunchAgents/org.example.shared.plist"), label: "org.example.shared", scope: .userAgent))
    }
    func testUnknownStateAndDisallowedBackgroundPermission() throws {
        var text = fixture.replacingOccurrences(of: "[enabled, allowed, notified]", with: "[unknown]")
        var items = try BackgroundStartupParser.parse(text, userID: 501)
        XCTAssertNil(items.first { $0.name == "Shared Agent" }?.enabled)
        text = fixture.replacingOccurrences(of: "[disabled, allowed, notified]", with: "[disabled, disallowed]")
        items = try BackgroundStartupParser.parse(text, userID: 501)
        XCTAssertEqual(items.first { $0.kind == .backgroundApp }?.enabled, false)
    }
    func testMalformedReportsAndDuplicateFieldsFailClearly() {
        XCTAssertThrowsError(try BackgroundStartupParser.parse("random output", userID: 501))
        XCTAssertThrowsError(try BackgroundStartupParser.parse("Records for UID 501\n", userID: 501))
        XCTAssertThrowsError(try BackgroundStartupParser.parse(fixture.replacingOccurrences(of: "Records for UID 501", with: "Records for UID 999"), userID: 501))
        XCTAssertThrowsError(try BackgroundStartupParser.parse(fixture.replacingOccurrences(of: "Name: Example Menu", with: "Name: Example Menu\nName: duplicate"), userID: 501))
        XCTAssertThrowsError(try BackgroundStartupParser.parse("Records for UID 501\n" + String(repeating: "#1:\n", count: 10_001), userID: 501))
        XCTAssertThrowsError(try BackgroundStartupParser.parse("Records for UID 501\n" + String(repeating: "a", count: 2 * 1024 * 1024), userID: 501))
    }
    func testForeignAndTraversingURLsAreNeverAccepted() throws {
        for url in ["https://example.invalid/Example.app", "file://remote/Applications/Example.app", "file:///Applications/../Example.app", "Contents/../Example.app", "file:///Applications/Example.app?query", "file:///Applications/%2e%2e/Example.app"] {
            let text = fixture.replacingOccurrences(of: "URL: /Applications/Example.app\n", with: "URL: \(url)\n")
            let items = try BackgroundStartupParser.parse(text, userID: 501)
            XCTAssertNil(items.first { $0.kind == .backgroundApp }?.url, url)
        }
    }
}
