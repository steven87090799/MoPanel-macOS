import XCTest
@testable import MoPanelCore

final class BackgroundStartupTests: XCTestCase {
    private let fixture = """
    Records for UID 501 : fixture
      #1:
        Name: Example Menu
        Type: app (0x2)
        Disposition: [enabled, allowed, notified] (0xb)
        Identifier: 2.org.example.menu
        URL: file:///Applications/Example.app/Contents/Library/LoginItems/Menu.app/
      #2:
        Name: Example
        Type: app (0x2)
        Disposition: [enabled, allowed, visible, notified] (0xf)
        Identifier: 2.org.example.app
        URL: file:///Applications/Example.app/
      #3:
        Name: Example Agent
        Type: legacy agent (0x10008)
        Disposition: [enabled, disallowed, visible, notified] (0xd)
        Identifier: 8.org.example.agent
        URL: file:///Library/LaunchAgents/org.example.agent.plist
        Executable Path: /Applications/Example.app/Contents/MacOS/agent
      #4:
        Name: Example Company
        Type: developer (0x20)
        Identifier: Example Company
    Records for UID 502 : another-user
      #1:
        Name: Other User App
        Type: app (0x2)
        Identifier: 2.org.other.app
    Records for UID -2 : system
      #1:
        Name: Example Helper
        Type: daemon (0x10)
        Disposition: [disabled, allowed, visible] (0x6)
        Identifier: 16.org.example.helper
    """
    func testCategoriesIncludeOnlyThisUserAndSystemServices() throws {
        let items = try BackgroundStartupParser.parse(fixture, userID: 501)
        XCTAssertEqual(items.map(\.kind), [.login, .backgroundApp, .service, .service])
        XCTAssertEqual(items.map(\.enabled), [true, true, false, false])
        XCTAssertEqual(items[0].url?.path, "/Applications/Example.app/Contents/Library/LoginItems/Menu.app")
        XCTAssertEqual(items[2].launchLabel, "org.example.agent")
    }
    func testUnknownStateIsNotPresentedAsDisabled() throws {
        let items = try BackgroundStartupParser.parse(fixture.replacingOccurrences(of: "[enabled, allowed, notified]", with: "[unknown]"), userID: 501)
        XCTAssertNil(items[0].enabled)
    }
    func testMalformedReportsAndDuplicateFieldsFailClearly() {
        XCTAssertThrowsError(try BackgroundStartupParser.parse("random output", userID: 501))
        XCTAssertThrowsError(try BackgroundStartupParser.parse("Records for UID 501\n", userID: 501))
        XCTAssertThrowsError(try BackgroundStartupParser.parse(fixture.replacingOccurrences(of: "Name: Example Menu", with: "Name: Example Menu\nName: duplicate"), userID: 501))
    }
    func testForeignURLsAreNeverActionable() throws {
        let items = try BackgroundStartupParser.parse(fixture.replacingOccurrences(of: "file:///Applications/Example.app/", with: "https://example.invalid/Example.app/"), userID: 501)
        XCTAssertNil(items[1].url)
    }
}
