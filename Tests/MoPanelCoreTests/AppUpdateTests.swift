// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MoPanelCore

final class AppUpdateTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func dictionary(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }
    private func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func snapshot() throws -> BrewUpdateSnapshot {
        try .decode(info: fixture("brew-info-v2"), outdated: fixture("brew-outdated-v2"))
    }
    private func changedInfo(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try dictionary("brew-info-v2")
        var records = try XCTUnwrap(object["casks"] as? [[String: Any]])
        mutate(&records[0]); object["casks"] = records
        return try encode(object)
    }

    func testOfficialJSONFixturePreservesSourceVersionAndExplicitCustomAppPath() throws {
        let snapshot = try snapshot()
        let item = try XCTUnwrap(snapshot.items.first { $0.id == "example-editor" })
        XCTAssertEqual(item.state, .available)
        XCTAssertEqual(item.installed.identity?.qualifiedToken, "homebrew/cask/example-editor")
        XCTAssertEqual(item.installed.applicationPaths, ["/Volumes/工作 Apps/Example Editor.app"])
        XCTAssertEqual(item.outdated?.installedVersions, ["2.3.0"])
        XCTAssertEqual(item.outdated?.currentVersion, "2.4.1")
        XCTAssertEqual(snapshot.items.first { $0.id == "current-app" }?.state, .current)
        XCTAssertEqual(snapshot.items.first { $0.id == "self-updater" }?.state, .selfManaged)
        XCTAssertEqual(snapshot.items.first { $0.id == "unversioned" }?.state, .unversioned)
    }

    func testCommandUsesOneFullyQualifiedTokenAndNoShell() throws {
        let identity = try BrewCaskIdentity(token: "visual-studio-code", tap: "homebrew/cask")
        XCTAssertEqual(BrewUpdateCommand.upgrade(identity).arguments, ["upgrade", "--cask", "--no-quit", "--require-sha", "homebrew/cask/visual-studio-code"])
        XCTAssertEqual(BrewUpdateCommand.preview(identity).arguments, ["upgrade", "--cask", "--no-quit", "--require-sha", "--dry-run", "homebrew/cask/visual-studio-code"])
        XCTAssertTrue(BrewUpdateCommand.upgrade(identity).requiresConfirmation)
        XCTAssertTrue(BrewUpdateCommand.refreshMetadata.requiresConfirmation)
        XCTAssertFalse(BrewUpdateCommand.preview(identity).requiresConfirmation)
        XCTAssertFalse(BrewUpdateCommand.installedInfo.requiresConfirmation)
        XCTAssertEqual(BrewUpdateCommand.outdated.arguments, ["outdated", "--cask", "--json=v2"])
    }

    func testIdentityRejectsFlagsTraversalURLsAndShellInjection() {
        for token in ["--all", "-f", "../app", "name/extra", "foo..bar", "App Name", "app;rm", "$(touch /tmp/no)", "`id`", "https://example.com", "app\n", "app\0", "$(whoami)", ""] {
            XCTAssertThrowsError(try BrewCaskIdentity(token: token, tap: "homebrew/cask"), token)
        }
        for tap in ["homebrew", "/homebrew/cask", "homebrew/cask/extra", "../cask", "homebrew/--cask", "homebrew/cask;id"] {
            XCTAssertThrowsError(try BrewCaskIdentity(token: "safe-app", tap: tap), tap)
        }
    }

    func testRequiredEnvelopeCannotBecomeEmptySuccess() throws {
        for invalid in ["{}", "[]", "{\"casks\":null}", "{\"casks\":{}}", "not JSON"] {
            XCTAssertThrowsError(try BrewUpdateSnapshot.decode(info: Data(invalid.utf8), outdated: fixture("brew-outdated-v2")))
            XCTAssertThrowsError(try BrewUpdateSnapshot.decode(info: fixture("brew-info-v2"), outdated: Data(invalid.utf8)))
        }
        XCTAssertEqual(try BrewUpdateSnapshot.decode(info: Data("{\"casks\":[]}".utf8), outdated: Data("{\"casks\":[]}".utf8)).items.count, 0)
    }

    func testAdditiveSchemaChangesRemainReadable() throws {
        let data = try changedInfo { $0["future_metadata"] = ["arbitrary": [1, 2, 3]] }
        let decoded = try BrewUpdateSnapshot.decode(info: data, outdated: fixture("brew-outdated-v2"))
        XCTAssertEqual(decoded.items.first { $0.id == "example-editor" }?.state, .available)
    }

    func testDisagreeingInstalledAndAvailableVersionsFailClosed() throws {
        for replacement in ["installed": "2.2.0", "version": "3.0"] {
            let data = try changedInfo { $0[replacement.key] = replacement.value }
            XCTAssertThrowsError(try BrewUpdateSnapshot.decode(info: data, outdated: fixture("brew-outdated-v2")))
        }
    }

    func testDuplicateTokensAcrossTapsCannotBindToFirstDisplayName() throws {
        var object = try dictionary("brew-info-v2")
        var casks = try XCTUnwrap(object["casks"] as? [[String: Any]])
        var duplicate = casks[0]; duplicate["tap"] = "someone/tools"; duplicate["full_token"] = "someone/tools/example-editor"
        casks.append(duplicate); object["casks"] = casks
        XCTAssertThrowsError(try BrewUpdateSnapshot.decode(info: encode(object), outdated: fixture("brew-outdated-v2")))
    }

    func testUnknownOrRepeatedOutdatedIdentityIsRejected() throws {
        var object = try dictionary("brew-outdated-v2")
        var updates = try XCTUnwrap(object["casks"] as? [[String: Any]])
        updates.append(updates[0]); object["casks"] = updates
        XCTAssertThrowsError(try BrewUpdateSnapshot.decode(info: fixture("brew-info-v2"), outdated: encode(object)))
        updates[0]["name"] = "uninstalled-app"; object["casks"] = [updates[0]]
        XCTAssertThrowsError(try BrewUpdateSnapshot.decode(info: fixture("brew-info-v2"), outdated: encode(object)))
    }

    func testMalformedFieldTypesDoNotReceiveGuessedDefaults() throws {
        for entry in [("installed", ["2.3.0"] as Any), ("version", 3 as Any), ("artifacts", "Example.app" as Any), ("auto_updates", "false" as Any)] {
            let data = try changedInfo { $0[entry.0] = entry.1 }
            XCTAssertThrowsError(try BrewUpdateSnapshot.decode(info: data, outdated: fixture("brew-outdated-v2")))
        }
    }

    func testPlanRevalidationRejectsPathSourceChecksumAndVersionChanges() throws {
        let original = try snapshot()
        let item = try XCTUnwrap(original.items.first { $0.state == .available })
        let plan = try BrewUpdatePlan(item: item)
        XCTAssertNoThrow(try plan.revalidate(in: original))
        let variants: [(inout [String: Any]) -> Void] = [
            { $0["artifacts"] = [["app": ["Example Editor.app"], "target": "/Applications/Other.app"]] },
            { $0["tap"] = "someone/tools" },
            { $0["sha256"] = String(repeating: "b", count: 64) },
            { $0["pinned"] = true },
            { $0["disabled"] = true }
        ]
        for change in variants {
            let modified = try BrewUpdateSnapshot.decode(info: changedInfo(change), outdated: fixture("brew-outdated-v2"))
            XCTAssertThrowsError(try plan.revalidate(in: modified))
        }
        var info = try dictionary("brew-info-v2"), updates = try dictionary("brew-outdated-v2")
        var entries = try XCTUnwrap(info["casks"] as? [[String: Any]])
        var updateEntries = try XCTUnwrap(updates["casks"] as? [[String: Any]])
        entries[0]["version"] = "3.0"; updateEntries[0]["current_version"] = "3.0"
        info["casks"] = entries; updates["casks"] = updateEntries
        XCTAssertThrowsError(try plan.revalidate(in: .decode(info: encode(info), outdated: encode(updates))))
    }

    func testCustomInstallersHooksAndDependenciesCannotUpgrade() throws {
        for kind in ["pkg", "installer", "preflight", "postflight", "uninstall", "uninstall_postflight", "future_executor"] {
            let data = try changedInfo { record in
                var artifacts = record["artifacts"] as! [[String: Any]]
                artifacts.append([kind: NSNull()]); record["artifacts"] = artifacts
            }
            let item = try XCTUnwrap(BrewUpdateSnapshot.decode(info: data, outdated: fixture("brew-outdated-v2")).items.first { $0.id == "example-editor" })
            XCTAssertEqual(item.state, .unsupported, kind)
            XCTAssertThrowsError(try BrewUpdatePlan(item: item))
        }
        for key in ["cask", "formula", "future_dependency"] {
            let data = try changedInfo { $0["depends_on"] = [key: ["dependency"]] }
            XCTAssertEqual(try BrewUpdateSnapshot.decode(info: data, outdated: fixture("brew-outdated-v2")).items.first { $0.id == "example-editor" }?.state, .unsupported)
        }
    }

    func testUnknownTargetAndMissingChecksumAreExplicitlyUnsupported() throws {
        let variants: [(inout [String: Any]) -> Void] = [
            { $0["sha256"] = "no_check" },
            { $0.removeValue(forKey: "sha256") },
            { $0["artifacts"] = [["app": ["Example Editor.app"]]] },
            { $0["artifacts"] = [["app": ["Example Editor.app"], "target": "../Example Editor.app"]] },
            { $0["artifacts"] = [["app": ["Example Editor.app"], "target": "/Applications/not-an-app"]] },
            { $0["full_token"] = "different/token/app" }
        ]
        for change in variants {
            XCTAssertEqual(try BrewUpdateSnapshot.decode(info: changedInfo(change), outdated: fixture("brew-outdated-v2")).items.first { $0.installed.token == "example-editor" }?.state, .unsupported)
        }
    }

    func testAbsentOutdatedEntryCannotFalselyClaimDifferentVersionIsCurrent() throws {
        let snapshot = try BrewUpdateSnapshot.decode(info: fixture("brew-info-v2"), outdated: Data("{\"casks\":[]}".utf8))
        XCTAssertEqual(snapshot.items.first { $0.id == "example-editor" }?.state, .unsupported)
        XCTAssertEqual(snapshot.items.first { $0.id == "self-updater" }?.state, .selfManaged)
    }

    func testHelpNegotiationRequiresRealFlagsAndSafetyOptions() {
        let info = "brew info --json=v2 --installed --cask"
        let outdated = "brew outdated --json=v2 --cask"
        let upgrade = "brew upgrade --dry-run --cask --no-quit --require-sha"
        XCTAssertTrue(BrewUpdateCapabilities(infoHelp: info, outdatedHelp: outdated, upgradeHelp: upgrade, updateHelp: "brew update Homebrew").canUpgrade)
        for removed in ["--dry-run", "--no-quit", "--require-sha"] {
            let result = BrewUpdateCapabilities(infoHelp: info, outdatedHelp: outdated, upgradeHelp: upgrade.replacingOccurrences(of: removed, with: removed + "-unsupported"), updateHelp: "brew update Homebrew")
            XCTAssertTrue(result.canRead); XCTAssertFalse(result.canUpgrade)
        }
        XCTAssertFalse(BrewUpdateCapabilities(infoHelp: info.replacingOccurrences(of: "v2", with: "v3"), outdatedHelp: outdated, upgradeHelp: upgrade, updateHelp: "unknown").canRead)
    }

    func testPublisherMetadataRequiresSignatureHTTPSAndNoCredentialsOrQueries() {
        XCTAssertEqual(PublisherFeedPolicy.displayableURL("https://updates.example.com/appcast.xml", signatureValid: true)?.host, "updates.example.com")
        XCTAssertNil(PublisherFeedPolicy.displayableURL("https://updates.example.com/appcast.xml", signatureValid: false))
        for value in ["http://example.com/feed", "file:///tmp/feed.xml", "javascript:alert(1)", "https://user:secret@example.com/feed", "https://example.com/feed?token=secret", "https://example.com/feed#secret", "https://127.0.0.1/feed", "https://10.0.0.1/feed", "https://[::1]/feed", "https://localhost/feed", "https://host.local/feed", "https://host.internal/feed", "https://example.com:8443/feed", "https://example.com/feed\n", "https://example.com./feed"] {
            XCTAssertNil(PublisherFeedPolicy.displayableURL(value, signatureValid: true), value)
        }
    }

    func testLayoutResolvesActualHomebrewSymlinkWithoutExecution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mopanel-brew-layout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let brewRoot = root.appendingPathComponent("Homebrew")
        let executable = brewRoot.appendingPathComponent("bin/brew")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        for path in ["Library/Homebrew/brew.sh", "Library/Homebrew/brew.rb", "Library/Homebrew/cmd/outdated.rb"] {
            let url = brewRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture, never executed".utf8).write(to: url)
        }
        try Data("#!/bin/bash\n# HOMEBREW_BREW_FILE brew.sh fixture, never executed\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let alias = root.appendingPathComponent("brew-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        let result = try BrewExecutableLayout.inspect(alias)
        XCTAssertEqual(result.executable, executable.resolvingSymlinksInPath())
        XCTAssertEqual(result.repository.path, brewRoot.resolvingSymlinksInPath().path)
        try Data("#!/bin/bash\necho fake\n".utf8).write(to: executable)
        XCTAssertThrowsError(try BrewExecutableLayout.inspect(alias))
    }

    func testDiscoveryIgnoresRelativeAndEmptyPathEntries() {
        let candidates = BrewExecutableLayout.candidates(pathEnvironment: ":.:relative:/custom/bin:/custom/bin:/opt/homebrew/bin:")
        XCTAssertEqual(candidates.map(\.path), ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/custom/bin/brew"])
    }

    func testLargeInventoryAndSpecialPathCharactersRemainData() throws {
        var root = try dictionary("brew-info-v2")
        let original = try XCTUnwrap((root["casks"] as? [[String: Any]])?.first)
        root["casks"] = (0..<5000).map { index -> [String: Any] in
            var entry = original
            entry["token"] = "test-\(index)"; entry["full_token"] = "test-\(index)"
            entry["installed"] = "2.4.1"; entry["name"] = ["測試 \(index) ' $()"]
            entry["artifacts"] = [["app": ["測試.app"], "target": "/Applications/測試 ' $(never)-\(index).app"]]
            return entry
        }
        let snapshot = try BrewUpdateSnapshot.decode(info: encode(root), outdated: Data("{\"casks\":[]}".utf8))
        XCTAssertEqual(snapshot.items.count, 5000)
        XCTAssertTrue(snapshot.items.allSatisfy { $0.state == .current })
        XCTAssertTrue(snapshot.items.allSatisfy { $0.installed.applicationPaths[0].contains("$(never)") })
    }
}
