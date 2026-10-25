import XCTest
@testable import MoPanelCore

final class MoleSelectionScreenTests: XCTestCase {
    private let menu = ["Select apps to slim  1/2 selected", "", "➤ ● Editor · 120 MB", "  ○ Browser · 80 MB", "", "↑↓ | Space Select | Enter Save | Q Cancel"]
    func testOnlyReviewedVersionAndInteractiveSelectorCommandsAreEnabled() {
        for command in [MoleCommand.installer, .slim, .purge] {
            XCTAssertTrue(MoleSelectionScreen.supports(command: command, version: "1.62.0"))
            XCTAssertTrue(MoleSelectionScreen.supports(command: command, version: "V1.62.0"))
            XCTAssertFalse(MoleSelectionScreen.supports(command: command, version: "1.63.0"))
        }
        XCTAssertFalse(MoleSelectionScreen.supports(command: .clean, version: "1.62.0"))
        XCTAssertFalse(MoleSelectionScreen.supports(command: .uninstall, version: "1.62.0"))
    }
    func testProjectsActualSelectionAndCursorWithoutProducingPaths() throws {
        let screen = try XCTUnwrap(MoleSelectionScreen.parse(menu, command: .slim))
        XCTAssertEqual(screen.rows.count, 2)
        XCTAssertEqual(screen.focused?.text, "Editor · 120 MB")
        XCTAssertTrue(screen.rows[0].selected)
        XCTAssertFalse(screen.rows[1].selected)
    }
    func testWrongCommandMissingFooterAndPartialRedrawAreRejected() {
        XCTAssertNil(MoleSelectionScreen.parse(menu, command: .clean))
        XCTAssertNil(MoleSelectionScreen.parse(menu, command: .installer))
        XCTAssertNil(MoleSelectionScreen.parse(Array(menu.dropLast()), command: .slim))
        XCTAssertNil(MoleSelectionScreen.parse(menu.map { $0.replacingOccurrences(of: "➤", with: " ") }, command: .slim))
    }
    func testDuplicateLabelsOrTwoCursorsCannotReceiveNativeActions() {
        var duplicate = menu; duplicate[3] = "  ○ Editor · 120 MB"
        XCTAssertNil(MoleSelectionScreen.parse(duplicate, command: .slim))
        var cursors = menu; cursors[3] = "➤ ○ Browser · 80 MB"
        XCTAssertNil(MoleSelectionScreen.parse(cursors, command: .slim))
    }
    func testBoundedAndControlFreeDisplay() {
        XCTAssertNil(MoleSelectionScreen.parse(menu + Array(repeating: "", count: 81), command: .slim))
        var unsafe = menu; unsafe[2] += "\u{07}"
        XCTAssertNil(MoleSelectionScreen.parse(unsafe, command: .slim))
    }
}
