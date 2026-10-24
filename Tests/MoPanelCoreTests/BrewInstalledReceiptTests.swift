// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MoPanelCore

final class BrewInstalledReceiptTests: XCTestCase {
    private func item() throws -> BrewUpdateItem {
        func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
        }
        return try XCTUnwrap(BrewUpdateSnapshot.decode(info: fixture("brew-info-v2"), outdated: fixture("brew-outdated-v2")).items.first { $0.state == .available })
    }
    private func encoded(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private var app: [String: Any] { ["app": ["Example Editor.app"]] }
    private var tab: [String: Any] {
        ["source": ["tap": "homebrew/cask", "version": "2.3.0", "path": "/opt/homebrew/Library/Taps/homebrew/homebrew-cask/Casks/e/example-editor.rb"],
         "uninstall_flight_blocks": false, "uninstall_artifacts": [app], "time": 1234]
    }
    private var config: [String: Any] {
        ["default": ["appdir": "/Applications"], "env": [:], "explicit": ["appdir": "/Volumes/工作 Apps"]]
    }
    private func validate(_ definition: [String: Any] = [:], tab override: [String: Any]? = nil, config configuration: [String: Any]? = nil) throws {
        try BrewInstalledReceipt.validate(definition: encoded(definition), receipt: encoded(override ?? tab), configuration: encoded(configuration ?? config), item: item())
    }
    private func makeTree() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mopanel-receipt-" + UUID().uuidString, isDirectory: true)
        let base = temp.appendingPathComponent("example-editor", isDirectory: true)
        let casks = base.appendingPathComponent(".metadata/2.3.0/20261024070000.001/Casks", isDirectory: true)
        try FileManager.default.createDirectory(at: casks, withIntermediateDirectories: true)
        try encoded([:]).write(to: casks.appendingPathComponent("example-editor.json"))
        try encoded(tab).write(to: base.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
        try encoded(config).write(to: base.appendingPathComponent(".metadata/config.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        return base
    }

    func testSupportedCompactReceiptAndCustomAppDirectory() throws {
        XCTAssertNoThrow(try validate())
        XCTAssertNoThrow(try validate(["version": "2.3.0", "artifacts": [app]]))
        let base = try makeTree()
        let proof = try BrewInstalledReceipt.inspect(caskDirectory: base, item: item())
        XCTAssertEqual(proof.caskDirectory, base.resolvingSymlinksInPath())
        XCTAssertEqual(proof.definitionURL.lastPathComponent, "example-editor.json")
        XCTAssertEqual(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()), proof)
    }

    func testOldUninstallHooksCannotHideBehindSafeNewRecipe() throws {
        for hook in ["uninstall", "uninstall_preflight", "uninstall_postflight", "preflight", "postflight", "installer", "pkg", "future_executor"] {
            var old = tab; old["uninstall_artifacts"] = [app, [hook: ["script": "/tmp/must-not-run"]]]
            XCTAssertThrowsError(try validate(tab: old), hook)
            XCTAssertThrowsError(try validate(["artifacts": [app, [hook: NSNull()]]]), hook)
        }
        var old = tab; old["uninstall_flight_blocks"] = true
        XCTAssertThrowsError(try validate(tab: old))
    }

    func testChangedSourceVersionAndAppRenameAreRejected() throws {
        for changed in ["tap": "someone/casks", "version": "2.2.0", "path": "/tmp/different-cask.rb"] {
            var old = tab, source = old["source"] as! [String: Any]
            source[changed.key] = changed.value; old["source"] = source
            XCTAssertThrowsError(try validate(tab: old))
        }
        var old = tab; old["uninstall_artifacts"] = [["app": ["Different.app"]]]
        XCTAssertThrowsError(try validate(tab: old))
        XCTAssertThrowsError(try validate(["version": "2.2.0"]))
        XCTAssertThrowsError(try validate(["artifacts": [["app": ["Example Editor.app", ["target": "Changed.app"]]]]]))
    }

    func testMissingOrUnknownReceiptFormatsAndUnsafeAppdirFailClosed() throws {
        for key in ["source", "uninstall_flight_blocks", "uninstall_artifacts"] {
            var old = tab; old.removeValue(forKey: key)
            XCTAssertThrowsError(try validate(tab: old))
        }
        for definition: [String: Any] in [["artifacts": []], ["artifacts": NSNull()], ["ruby_source": "exec"], ["variations": [:]], ["url_specs": ["only_path": "../../outside"]]] {
            XCTAssertThrowsError(try validate(definition))
        }
        for path in ["~/Applications", "/Applications", "/tmp/Other Apps", "\n/Volumes/工作 Apps"] {
            var changed = config; changed["explicit"] = ["appdir": path]
            XCTAssertThrowsError(try validate(config: changed))
        }
    }

    func testRubyMissingAndAmbiguousInstalledDefinitionsAreNeverEvaluated() throws {
        let base = try makeTree()
        let directory = base.appendingPathComponent(".metadata/2.3.0/20261024070000.001/Casks")
        let file = directory.appendingPathComponent("example-editor.json")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
        let marker = base.appendingPathComponent("must-not-exist")
        try Data("File.write('\(marker.path)', 'unsafe')".utf8).write(to: directory.appendingPathComponent("example-editor.rb"))
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try encoded([:]).write(to: file)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
    }

    func testMultipleVersionsOrTimestampsAreNotGuessed() throws {
        let base = try makeTree()
        let extraVersion = base.appendingPathComponent(".metadata/2.2.0")
        try FileManager.default.createDirectory(at: extraVersion, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
        try FileManager.default.removeItem(at: extraVersion)
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".metadata/2.3.0/20261024080000.001"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
    }

    func testSymlinkAndWorldWritableReceiptsAreRejected() throws {
        let base = try makeTree()
        let receipt = base.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        let outside = base.deletingLastPathComponent().appendingPathComponent("outside.json")
        try encoded(tab).write(to: outside)
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: outside)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
        try FileManager.default.removeItem(at: receipt)
        try encoded(tab).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: receipt.path)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
    }

    func testChangedReceiptOrConfigurationInvalidatesConfirmationProof() throws {
        let base = try makeTree()
        let original = try BrewInstalledReceipt.inspect(caskDirectory: base, item: item())
        var changed = tab; changed["time"] = 5678
        try encoded(changed).write(to: base.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
        XCTAssertNotEqual(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()), original)
        var changedConfig = config; changedConfig["env"] = ["languages": ["en"]]
        try encoded(changedConfig).write(to: base.appendingPathComponent(".metadata/config.json"))
        XCTAssertNotEqual(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()), original)
    }

    func testLinkedMetadataDirectoryAndCaskDirectoryAreRejected() throws {
        let base = try makeTree()
        let parent = base.deletingLastPathComponent()
        let linkParent = parent.appendingPathComponent("link-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: linkParent, withIntermediateDirectories: true)
        let linkedCask = linkParent.appendingPathComponent("example-editor")
        try FileManager.default.createSymbolicLink(at: linkedCask, withDestinationURL: base)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: linkedCask, item: item()))
        let metadata = base.appendingPathComponent(".metadata")
        let moved = parent.appendingPathComponent("moved-metadata")
        try FileManager.default.moveItem(at: metadata, to: moved)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: moved)
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
    }

    func testOversizedReceiptIsRejectedBeforeDecoding() throws {
        let base = try makeTree()
        try Data(repeating: 32, count: 1_048_577).write(to: base.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
        XCTAssertThrowsError(try BrewInstalledReceipt.inspect(caskDirectory: base, item: item()))
    }

    func testCaskroomOutputMustBeOneExactIdentityAndCommandIsReadOnly() throws {
        let identity = try BrewCaskIdentity(token: "example-editor", tap: "homebrew/cask")
        XCTAssertEqual(try BrewInstalledReceipt.caskDirectory(output: "/opt/homebrew/Caskroom/example-editor\n", identity: identity).path, "/opt/homebrew/Caskroom/example-editor")
        for path in ["relative/example-editor", "/opt/homebrew/Caskroom/different", "/one/example-editor\n/two/example-editor", "/one/example-editor\0", ""] {
            XCTAssertThrowsError(try BrewInstalledReceipt.caskDirectory(output: path, identity: identity))
        }
        XCTAssertEqual(BrewUpdateCommand.caskroom(identity).arguments, ["--caskroom", "homebrew/cask/example-editor"])
        XCTAssertFalse(BrewUpdateCommand.caskroom(identity).requiresConfirmation)
    }
}
